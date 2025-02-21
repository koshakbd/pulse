#!/usr/bin/env bash

ssh_key=${HOME}/.ssh/id_manta_ci
eval `ssh-agent`
ssh-add ${ssh_key}

declare -A endpoint_prefix=()
endpoint_prefix+=( [ops]=7p1eol9lz4 )
endpoint_prefix+=( [dev]=mab48pe004 )
endpoint_prefix+=( [service]=l7ff90u0lf )
endpoint_prefix+=( [prod]=hzhmt0krm0 )

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
temp_dir=$(mktemp -d)

_decode_property() {
  echo ${1} | base64 --decode | jq -r ${2}
}
_ipv4dec() {
  for i; do
    echo $i | {
      IFS=./
      read a b c d e
      test -z "$e" && e=32
      echo -n "$((a<<24|b<<16|c<<8|d)) $((-1<<(32-e))) "
    }
  done
}
_ipv4_network_includes() {
  _ipv4dec $2 $1 | {
    read addr1 mask1 addr2 mask2
    if (( (addr1&mask2) == (addr2&mask2) && mask1 >= mask2 )); then
      true
    else
      false
    fi
  }
}
function _join_by {
  local d=${1-} f=${2-}
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

upsert_cname() {
  local prefix=${1}
  local fqdn=${2}
  local tld=${3}
  local hosted_zone_id=$(basename $(aws route53 list-hosted-zones --profile pelagos-ops | jq --arg tld ${tld}. -r '.HostedZones[] | select(.Name == $tld) | .Id'))
  if [ -z "${hosted_zone_id}" ]; then
    echo "[upsert_cname(prefix: ${prefix}, fqdn: ${fqdn}, tld: ${tld})] failed to determine hosted zone id for tld: ${tld}"
  elif getent hosts ${prefix}.${fqdn} &>/dev/null; then
    echo "[upsert_cname(prefix: ${prefix}, fqdn: ${fqdn}, tld: ${tld})] detected existing dns resolution for ${prefix}.${fqdn}"
  else
    echo '{
      "Changes": [
        {
          "Action": "UPSERT",
          "ResourceRecordSet": {
            "Name": "",
            "Type": "CNAME",
            "TTL": 300,
            "ResourceRecords": [
              {
                "Value": ""
              }
            ]
          }
        }
      ]
    }' | jq --arg cname ${prefix}.${fqdn} --arg fqdn ${fqdn} '. | .Changes[0].ResourceRecordSet.Name = $cname | .Changes[0].ResourceRecordSet.ResourceRecords[0].Value = $fqdn' > ${temp_dir}/${prefix}.${fqdn}.json
    if aws route53 change-resource-record-sets \
      --profile pelagos-ops \
      --hosted-zone-id ${hosted_zone_id} \
      --change-batch=file://${temp_dir}/${prefix}.${fqdn}.json; then
      echo "[upsert_cname(prefix: ${prefix}, fqdn: ${fqdn}, tld: ${tld})] upserted cname record pointing ${prefix}.${fqdn} to ${fqdn}"
    else
      echo "[upsert_cname(prefix: ${prefix}, fqdn: ${fqdn}, tld: ${tld})] failed to upsert cname record pointing ${prefix}.${fqdn} to ${fqdn}"
    fi
  fi
}

# fetch list of existing health checks
aws route53 list-health-checks --profile pelagos-ops > ${temp_dir}/health-checks.json

# fetch ws-ssl (nginx) configuration
curl -sLo ${temp_dir}/ssl.conf https://raw.githubusercontent.com/Manta-Network/pulse/main/maintainer/ssl.conf

for endpoint_name in "${!endpoint_prefix[@]}"; do
  endpoint_url=https://${endpoint_prefix[${endpoint_name}]}.execute-api.us-east-1.amazonaws.com/prod/instances
  if [ -z "${1}" ]; then
    instances_as_base64=( $(curl -sL ${endpoint_url} | jq -r '.instances[] | @base64') )
  else
    instances_as_base64=( $(curl -sL ${endpoint_url} | jq -r --arg domain ${1} '.instances[] | select(.domain == $domain) | @base64') )
  fi
  required_ssh_ingress_subnets=( $(curl -sL https://raw.githubusercontent.com/Manta-Network/pulse/main/config/ingress.yml | yq -r --arg endpoint ${endpoint_name} '.[$endpoint].subnet.required[]') )
  optional_ssh_ingress_subnets=( $(curl -sL https://raw.githubusercontent.com/Manta-Network/pulse/main/config/ingress.yml | yq -r --arg endpoint ${endpoint_name} '.[$endpoint].subnet.optional[]') )
  allowed_ssh_ingress_subnets=( "${required_ssh_ingress_subnets[@]}" "${optional_ssh_ingress_subnets[@]}" )

  echo "[${endpoint_name}] observed ${#instances_as_base64[@]} running instances in aws ${endpoint_name} account"
  for x in ${instances_as_base64[@]}; do
    id=$(_decode_property ${x} .id)
    hostname=$(_decode_property ${x} .hostname)
    domain=$(_decode_property ${x} .domain)
    fqdn=$(_decode_property ${x} .fqdn)
    launch=$(_decode_property ${x} .launch)
    machine=$(_decode_property ${x} .machine)
    instance_status=$(_decode_property ${x} .state)
    region=$(_decode_property ${x} .region)
    instance_ip=$(_decode_property ${x} .ip)
    username=mobula
    case ${domain} in
      calamari.systems)
        target_unit=calamari
        ;;
      manta.systems)
        target_unit=manta
        ;;
      rococo.dolphin.engineering)
        target_unit=dolphin
        ;;
      *)
        unset target_unit
        ;;
    esac
    detected_ssh_ingress_subnets_path=${temp_dir}/ssh_ingress_subnets-${fqdn}.json
    detected_authorized_keys_path=${temp_dir}/authorized_keys-${fqdn}-${username}
    profile=pelagos-${endpoint_name}
    security_group_ids=$(aws ec2 describe-instances \
      --profile ${profile} \
      --region ${region} \
      --instance-id ${id} \
      --query 'Reservations[].Instances[].SecurityGroups[].GroupId[]' \
      --output text)
    aws ec2 describe-security-groups \
      --profile ${profile} \
      --region ${region} \
      --group-ids ${security_group_ids} \
      --query 'SecurityGroups[*].{ name: GroupName, id: GroupId, ingress: IpPermissions[?ToPort==`22`].IpRanges[*].CidrIp }' \
      --filters Name=ip-permission.from-port,Values=22 Name=ip-permission.to-port,Values=22 | jq --arg region ${region} '[.[] | { id, name, region: $region, ingress }]' > ${detected_ssh_ingress_subnets_path}
    security_groups_as_base64=( $(jq -r '.[] | @base64' ${detected_ssh_ingress_subnets_path}) )

    for y in ${security_groups_as_base64[@]}; do
      security_group_id=$(_decode_property ${y} .id)
      detected_ssh_ingress_subnets=( $(_decode_property ${y} .ingress[0] | jq -r '.[]') )

      # grant ingress access for required subnets
      for required_ssh_ingress_subnet in ${required_ssh_ingress_subnets[@]}; do
        required_ssh_ingress_subnet_is_included=false
        for detected_ssh_ingress_subnet in ${detected_ssh_ingress_subnets[@]}; do
          if _ipv4_network_includes ${detected_ssh_ingress_subnet} ${required_ssh_ingress_subnet}; then
            required_ssh_ingress_subnet_is_included=true
          fi
        done
        if [ "${required_ssh_ingress_subnet_is_included}" = true ]; then
          echo "[${endpoint_name}/${region}/${fqdn}] detected required ssh ingress subnet: ${required_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
        else
          auth_result_path=${temp_dir}/authorize-ssh-ingress-${security_group_id}-$(uuidgen).json
          if aws ec2 authorize-security-group-ingress \
            --profile ${profile} \
            --region ${region} \
            --group-id ${security_group_id} \
            --protocol tcp \
            --port 22 \
            --cidr ${required_ssh_ingress_subnet} > ${auth_result_path} && [ "$(jq -r '.Return' ${auth_result_path})" = "true" ]; then
            echo "[${endpoint_name}/${region}/${fqdn}] granted ssh access for required ingress subnet: ${required_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
          else
            echo "[${endpoint_name}/${region}/${fqdn}] failed to grant ssh access for required ingress subnet: ${required_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
          fi
        fi
      done

      ingress_cidr=0.0.0.0/0
      for ingress_port in 80 443; do
        observed_rule_security_group_id=$(aws ec2 describe-security-groups \
          --profile ${profile} \
          --region ${region} \
          --group-id ${security_group_id} \
          --query 'SecurityGroups[0].GroupId' \
          --filters \
            Name=ip-permission.from-port,Values=${ingress_port} \
            Name=ip-permission.to-port,Values=${ingress_port} \
            Name=ip-permission.cidr,Values=${ingress_cidr} \
          --output text)
        if [ "${observed_rule_security_group_id}" = "${security_group_id}" ]; then
          echo "[${endpoint_name}/${region}/${fqdn}] observed port: ${ingress_port} access for cidr: ${ingress_cidr}, on manta-${endpoint_name}/${region}/${security_group_id}"
        elif aws ec2 authorize-security-group-ingress \
            --profile ${profile} \
            --region ${region} \
            --group-id ${security_group_id} \
            --protocol tcp \
            --port ${ingress_port} \
            --cidr ${ingress_cidr}; then
          echo "[${endpoint_name}/${region}/${fqdn}] granted port: ${ingress_port} access for cidr: ${ingress_cidr}, on manta-${endpoint_name}/${region}/${security_group_id}"
        else
          echo "[${endpoint_name}/${region}/${fqdn}] failed to grant port: ${ingress_port} access for cidr: ${ingress_cidr}, on manta-${endpoint_name}/${region}/${security_group_id}"
        fi
      done

      # revoke (or alert for non-prod) ingress access for disallowed subnets
      for detected_ssh_ingress_subnet in ${detected_ssh_ingress_subnets[@]}; do
        is_allowed_ssh_ingress_subnet=false
        for allowed_ssh_ingress_subnet in ${allowed_ssh_ingress_subnets[@]}; do
          if _ipv4_network_includes ${allowed_ssh_ingress_subnet} ${detected_ssh_ingress_subnet}; then
            is_allowed_ssh_ingress_subnet=true
          fi
        done
        if [ "${is_allowed_ssh_ingress_subnet}" = true ] ; then
          echo "[${endpoint_name}/${region}/${fqdn}] detected allowed ssh ingress subnet: ${detected_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
        else
          case ${endpoint_name} in
            ops|prod)
              if aws ec2 revoke-security-group-ingress \
                --profile ${profile} \
                --region ${region} \
                --group-id ${security_group_id} \
                --protocol tcp \
                --port 22 \
                --cidr ${detected_ssh_ingress_subnet} &> /dev/null; then
                echo "[${endpoint_name}/${region}/${fqdn}] revoked ssh access for disallowed ingress subnet: ${detected_ssh_ingress_subnet} from manta-${endpoint_name}/${region}/${security_group_id}"
              else
                echo "[${endpoint_name}/${region}/${fqdn}] failed to revoke ssh access for disallowed ingress subnet: ${detected_ssh_ingress_subnet} from manta-${endpoint_name}/${region}/${security_group_id}"
              fi
              # todo: discord security alert
              ;;
            *)
              echo "[${endpoint_name}/${region}/${fqdn}] detected disallowed ssh ingress subnet: ${detected_ssh_ingress_subnet} in manta-${endpoint_name}/${region}/${security_group_id}"
              # todo: discord security alert
            ;;
          esac
        fi
      done
    done
    if ssh -i ${ssh_key} -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new ${username}@${fqdn} "cat /home/${username}/.ssh/authorized_keys" > ${detected_authorized_keys_path} && [ -s ${detected_authorized_keys_path} ]; then
      echo "[${endpoint_name}/${region}/${fqdn}] fetched ${detected_authorized_keys_path}"
    else
      rm ${detected_authorized_keys_path}
    fi
    if [[ ${domain} != *"telemetry"* ]] && [[ ${domain} != *"workstation"* ]]; then
      health_check_id=$(jq --arg fqdn rpc.${fqdn} '.HealthChecks[] | select(.HealthCheckConfig.FullyQualifiedDomainName == $fqdn) | .Id' ${temp_dir}/health-checks.json)
      if [ -n "${health_check_id}" ]; then
        echo "[${endpoint_name}/${region}/${fqdn}] detected existing health check: https://rpc.${fqdn}/health"
      else
        echo '{
          "Port": 443,
          "Type": "HTTPS",
          "ResourcePath": "/health",
          "RequestInterval": 30,
          "FailureThreshold": 3,
          "MeasureLatency": true,
          "EnableSNI": true
        }' | jq \
          --arg fqdn rpc.${fqdn} \
          '
            .
            | .FullyQualifiedDomainName = $fqdn
          ' > ${temp_dir}/health-check-${fqdn}.json
        if aws route53 create-health-check \
          --profile pelagos-ops \
          --caller-reference rpc.${fqdn} \
          --health-check-config file://${temp_dir}/health-check-${fqdn}.json; then
          echo "[${endpoint_name}/${region}/${fqdn}] created health check: https://rpc.${fqdn}/health"
        else
          echo "[${endpoint_name}/${region}/${fqdn}] failed to create health check: https://rpc.${fqdn}/health"
        fi
      fi

      # dns for unique rpc fqdn
      upsert_cname rpc ${fqdn} $(echo ${fqdn} | rev | cut -d "." -f1-2 | rev)

      manta_service_units=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'systemctl list-units --type service --full --all --plain --no-legend --no-pager' | grep -E 'calamari|dolphin|manta' | cut -d " " -f1) )
      # todo: request the specific unit of interest rather than any of calamari/dolphin/manta
      manta_service_unit_file_path=$(ssh -i ${ssh_key} ${username}@${fqdn} "systemctl status ${manta_service_units[0]}" | grep -Po "/[a-z/]*/${manta_service_units[0]}")
      manta_service_rpc_port=$(ssh -i ${ssh_key} ${username}@${fqdn} "cat ${manta_service_unit_file_path}" | grep " --rpc-port " | grep -Eo "[0-9]{4}")
      if [ -z "${manta_service_rpc_port}" ]; then
        manta_service_rpc_port=9933
      fi
      manta_service_ws_port=$(ssh -i ${ssh_key} ${username}@${fqdn} "cat ${manta_service_unit_file_path}" | grep " --ws-port " | grep -Eo "[0-9]{4}")
      if [ -z "${manta_service_ws_port}" ]; then
        manta_service_ws_port=9944
      fi

      # nginx config for unique ws cert/fqdn
      ssh -i ${ssh_key} ${username}@${fqdn} "[ -f /etc/nginx/sites-available/default-ssl ] && sudo sed -i 's/localhost:9944/localhost:${manta_service_ws_port}/g' /etc/nginx/sites-available/default-ssl"
      ssh -i ${ssh_key} ${username}@${fqdn} "[ -f /etc/nginx/sites-available/ws-proxy ] && sudo sed -i 's/localhost:9944/localhost:${manta_service_ws_port}/g' /etc/nginx/sites-available/ws-proxy"

      # nginx config for unique rpc cert/fqdn
      sed "s/PORT/${manta_service_rpc_port}/g" ${temp_dir}/ssl.conf > ${temp_dir}/rpc.${fqdn}.conf
      sed -i "s/SERVER_NAME/rpc.${fqdn}/g" ${temp_dir}/rpc.${fqdn}.conf
      sed -i "s/CERT_NAME/${fqdn}/g" ${temp_dir}/rpc.${fqdn}.conf
      ssh -i ${ssh_key} ${username}@${fqdn} 'sudo rm -f /etc/nginx/sites-available/rpc-proxy /etc/nginx/sites-enabled/rpc'

      #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -vz ${temp_dir}/rpc.${fqdn}.conf mobula@${fqdn}:/etc/nginx/sites-available/
      scp ${temp_dir}/rpc.${fqdn}.conf mobula@${fqdn}:/home/mobula/rpc.${fqdn}.conf
      ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/mobula/rpc.${fqdn}.conf /etc/nginx/sites-available/rpc.${fqdn}.conf"
      ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/rpc.${fqdn}.conf"
      ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/rpc.${fqdn}.conf /etc/nginx/sites-enabled/rpc.${fqdn}.conf"

      last_certbot_rate_limit=$(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo cat /var/log/letsencrypt/letsencrypt.log | egrep ":ERROR:certbot.log:There were too many requests of a given type" | cut -d"," -f1 | tail -1')
      if [ -n "${last_certbot_rate_limit}" ]; then
        days_since_rate_limit_hit=$(( ($(date +%s) - $(date --date="${last_certbot_rate_limit}" +%s) )/(60*60*24) ))
        if (( days_since_rate_limit_hit > 7 )); then
          its_ok_to_talk_to_lets_encrypt=true
        else
          its_ok_to_talk_to_lets_encrypt=false
        fi
      else
        its_ok_to_talk_to_lets_encrypt=true
      fi

      if [ "${its_ok_to_talk_to_lets_encrypt}" = true ]; then
        cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates 2>/dev/null | grep Domains:' | sed -r 's/Domains: //g') )
        if [ ${#cert_domains[@]} -eq 0 ]; then
          echo "[${endpoint_name}/${region}/${fqdn}] requesting base cert: ${fqdn}"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d ${fqdn}"
          cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates 2>/dev/null | grep Domains:' | sed -r 's/Domains: //g') )
          if [ "${cert_domains[0]}" = "${fqdn}" ]; then
            echo "[${endpoint_name}/${region}/${fqdn}] cert obtained: ${fqdn}"
          else
            echo "[${endpoint_name}/${region}/${fqdn}] failed to obtain cert: ${fqdn}"
          fi
        fi
        if [ "${cert_domains[0]}" != "${fqdn}" ]; then
          echo "[${endpoint_name}/${region}/${fqdn}] deleting base cert: ${cert_domains[0]}"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot delete --cert-name ${cert_domains[0]}"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo rm -rf /etc/letsencrypt/{archive,live,renewal}/*"
          echo "[${endpoint_name}/${region}/${fqdn}] requesting base cert: ${fqdn}"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d ${fqdn}"
          cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates 2>/dev/null | grep Domains:' | sed -r 's/Domains: //g') )
          if [ "${cert_domains[0]}" = "${fqdn}" ]; then
            echo "[${endpoint_name}/${region}/${fqdn}] cert obtained: ${fqdn}"
          else
            echo "[${endpoint_name}/${region}/${fqdn}] failed to obtain cert: ${fqdn}"
          fi
        fi
        if [[ " ${cert_domains[*]} " =~ " rpc.${fqdn} " ]]; then
          echo "[${endpoint_name}/${region}/${fqdn}] detected rpc.${fqdn} in cert domains (${cert_domains[@]})"
        else
          cert_domains+=( rpc.${fqdn} )
          echo "[${endpoint_name}/${region}/${fqdn}] adding rpc.${fqdn} to cert domains (${cert_domains[@]})"
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d $(_join_by ' -d ' ${cert_domains[@]})"
          ssh -i ${ssh_key} ${username}@${fqdn} '[ -f /etc/nginx/sites-available/default-ssl ] && sudo ln -frs /etc/nginx/sites-available/default-ssl /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} '[ -f /etc/nginx/sites-available/ws-proxy ] && sudo ln -frs /etc/nginx/sites-available/ws-proxy /etc/nginx/sites-enabled/default'
          ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
        fi

        # handle cases where certbot has changed the path to the keys (eg: adding -0001 suffixes)
        cert_path=$(ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certificates 2>/dev/null | grep 'Certificate Path:' | sed -r 's/    Certificate Path: //g'")
        priv_path=$(ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certificates 2>/dev/null | grep 'Private Key Path:' | sed -r 's/    Private Key Path: //g'")
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo sed -i 's#/etc/letsencrypt/live/${fqdn}/fullchain.pem#${cert_path}#g' /etc/nginx/sites-available/*"
        ssh -i ${ssh_key} ${username}@${fqdn} "sudo sed -i 's#/etc/letsencrypt/live/${fqdn}/privkey.pem#${priv_path}#g' /etc/nginx/sites-available/*"
        ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'

        # shared rpc/ws cert/fqdn
        sed "s/PORT/${manta_service_ws_port}/g" ${temp_dir}/ssl.conf > ${temp_dir}/ws-ssl.conf
        sed "s/PORT/${manta_service_rpc_port}/g" ${temp_dir}/ssl.conf > ${temp_dir}/rpc-ssl.conf
        for prefix in rpc ws; do
          if sudo test -L /etc/letsencrypt/live/${prefix}.${domain}/privkey.pem &>/dev/null; then
            #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -azP /etc/letsencrypt/archive/${prefix}.${domain}/ mobula@${fqdn}:/etc/letsencrypt/archive/${prefix}.${domain}
            local_hash=$(sudo sha256sum /etc/letsencrypt/live/${prefix}.${domain}/privkey.pem | cut -d" " -f1)
            remote_hash=$(ssh -i ${ssh_key} ${username}@${fqdn} "sudo sha256sum /etc/letsencrypt/live/${prefix}.${domain}/privkey.pem 2>/dev/null" | cut -d" " -f1)
            echo "[${endpoint_name}/${region}/${fqdn}] cert checksum local: ${local_hash}, remote: ${remote_hash}"
            if [ "${local_hash}" = "${remote_hash}" ]; then
              echo "[${endpoint_name}/${region}/${fqdn}] detected ${prefix}.${domain} certs on ${fqdn}"
            elif sudo cp -r /etc/letsencrypt/archive/${prefix}.${domain} /home/$(whoami)/ \
              && sudo chown -R $(whoami):$(whoami) /home/$(whoami)/${prefix}.${domain} \
              && scp -r /home/$(whoami)/${prefix}.${domain} mobula@${fqdn}:/home/mobula/ \
              && rm -rf /home/$(whoami)/${prefix}.${domain}; then
              echo "[${endpoint_name}/${region}/${fqdn}] copied ${prefix}.${domain} certs to ${fqdn}"
              ssh -i ${ssh_key} ${username}@${fqdn} "sudo mkdir -p /etc/letsencrypt/{archive,live}/${prefix}.${domain}"
              ssh -i ${ssh_key} ${username}@${fqdn} "sudo cp -r /home/mobula/${prefix}.${domain} /etc/letsencrypt/archive/"
              ssh -i ${ssh_key} ${username}@${fqdn} "rm -rf /home/mobula/${prefix}.${domain}"
              ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown -R root:root /etc/letsencrypt/{archive,live}/${prefix}.${domain}"
              for pem in cert chain fullchain privkey; do
                ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs $(sudo readlink -f /etc/letsencrypt/live/${prefix}.${domain}/${pem}.pem) /etc/letsencrypt/live/${prefix}.${domain}/${pem}.pem"
              done
              #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -azP /etc/letsencrypt/live/${prefix}.${domain}/ mobula@${fqdn}:/etc/letsencrypt/live/${prefix}.${domain}
              # create nginx shared fqdn config
              sed "s/SERVER_NAME/${prefix}.${domain}/g" ${temp_dir}/${prefix}-ssl.conf > ${temp_dir}/${prefix}.${domain}.conf
              sed -i "s/CERT_NAME/${prefix}.${domain}/g" ${temp_dir}/${prefix}.${domain}.conf
              #rsync -e "ssh -i ${ssh_key}" --rsync-path='sudo rsync' -vz ${temp_dir}/${prefix}.${domain}.conf mobula@${fqdn}:/etc/nginx/sites-available/
              scp ${temp_dir}/${prefix}.${domain}.conf mobula@${fqdn}:/home/mobula/${prefix}.${domain}.conf
              ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/mobula/${prefix}.${domain}.conf /etc/nginx/sites-available/${prefix}.${domain}.conf"
              ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/${prefix}.${domain}.conf"
              ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/${prefix}.${domain}.conf /etc/nginx/sites-enabled/${prefix}.${domain}.conf"
              ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
            else
              echo "[${endpoint_name}/${region}/${fqdn}] failed to copy ${prefix}.${domain} certs to ${fqdn}"
            fi
          fi
        done

        # metrics
        if ssh ${username}@${fqdn} 'curl --head http://localhost:9616/metrics &> /dev/null' && ssh ${username}@${fqdn} 'curl --head http://localhost:9615/metrics &> /dev/null'; then

          # relay dns for metrics
          upsert_cname relay.metrics ${fqdn} $(echo ${fqdn} | rev | cut -d "." -f1-2 | rev)

          # nginx config for relay.metrics cert/fqdn
          sed "s/PORT/9616/g" ${temp_dir}/ssl.conf > ${temp_dir}/relay.metrics.${fqdn}.conf
          sed -i "s/SERVER_NAME/relay.metrics.${fqdn}/g" ${temp_dir}/relay.metrics.${fqdn}.conf
          sed -i "s/CERT_NAME/${fqdn}/g" ${temp_dir}/relay.metrics.${fqdn}.conf

          scp ${temp_dir}/relay.metrics.${fqdn}.conf ${username}@${fqdn}:/home/${username}/relay.metrics.${fqdn}.conf
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/${username}/relay.metrics.${fqdn}.conf /etc/nginx/sites-available/relay.metrics.${fqdn}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/relay.metrics.${fqdn}.conf"

          cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates 2>/dev/null | grep Domains:' | sed -r 's/Domains: //g') )
          if [[ " ${cert_domains[*]} " =~ " relay.metrics.${fqdn} " ]]; then
            echo "[${endpoint_name}/${region}/${fqdn}] detected relay.metrics.${fqdn} in cert domains (${cert_domains[@]})"
          else
            cert_domains+=( relay.metrics.${fqdn} )
            echo "[${endpoint_name}/${region}/${fqdn}] adding relay.metrics.${fqdn} to cert domains (${cert_domains[@]})"
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d $(_join_by ' -d ' ${cert_domains[@]})"
            ssh -i ${ssh_key} ${username}@${fqdn} '[ -f /etc/nginx/sites-available/default-ssl ] && sudo ln -frs /etc/nginx/sites-available/default-ssl /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} '[ -f /etc/nginx/sites-available/ws-proxy ] && sudo ln -frs /etc/nginx/sites-available/ws-proxy /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/relay.metrics.${fqdn}.conf /etc/nginx/sites-enabled/relay.metrics.${fqdn}.conf"
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
          fi

          # para dns for metrics
          upsert_cname para.metrics ${fqdn} $(echo ${fqdn} | rev | cut -d "." -f1-2 | rev)

          # nginx config for para.metrics cert/fqdn
          sed "s/PORT/9615/g" ${temp_dir}/ssl.conf > ${temp_dir}/para.metrics.${fqdn}.conf
          sed -i "s/SERVER_NAME/para.metrics.${fqdn}/g" ${temp_dir}/para.metrics.${fqdn}.conf
          sed -i "s/CERT_NAME/${fqdn}/g" ${temp_dir}/para.metrics.${fqdn}.conf

          scp ${temp_dir}/para.metrics.${fqdn}.conf ${username}@${fqdn}:/home/${username}/para.metrics.${fqdn}.conf
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/${username}/para.metrics.${fqdn}.conf /etc/nginx/sites-available/para.metrics.${fqdn}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/para.metrics.${fqdn}.conf"

          cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates 2>/dev/null | grep Domains:' | sed -r 's/Domains: //g') )
          if [[ " ${cert_domains[*]} " =~ " para.metrics.${fqdn} " ]]; then
            echo "[${endpoint_name}/${region}/${fqdn}] detected para.metrics.${fqdn} in cert domains (${cert_domains[@]})"
          else
            cert_domains+=( para.metrics.${fqdn} )
            echo "[${endpoint_name}/${region}/${fqdn}] adding para.metrics.${fqdn} to cert domains (${cert_domains[@]})"
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d $(_join_by ' -d ' ${cert_domains[@]})"
            ssh -i ${ssh_key} ${username}@${fqdn} '[ -f /etc/nginx/sites-available/default-ssl ] && sudo ln -frs /etc/nginx/sites-available/default-ssl /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} '[ -f /etc/nginx/sites-available/ws-proxy ] && sudo ln -frs /etc/nginx/sites-available/ws-proxy /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/para.metrics.${fqdn}.conf /etc/nginx/sites-enabled/para.metrics.${fqdn}.conf"
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
          fi
        elif ssh ${username}@${fqdn} 'curl --head http://localhost:9615/metrics &> /dev/null'; then
          # relay only dns for metrics
          upsert_cname relay.metrics ${fqdn} $(echo ${fqdn} | rev | cut -d "." -f1-2 | rev)

          # nginx config for relay.metrics cert/fqdn
          sed "s/PORT/9615/g" ${temp_dir}/ssl.conf > ${temp_dir}/relay.metrics.${fqdn}.conf
          sed -i "s/SERVER_NAME/relay.metrics.${fqdn}/g" ${temp_dir}/relay.metrics.${fqdn}.conf
          sed -i "s/CERT_NAME/${fqdn}/g" ${temp_dir}/relay.metrics.${fqdn}.conf

          scp ${temp_dir}/relay.metrics.${fqdn}.conf ${username}@${fqdn}:/home/${username}/relay.metrics.${fqdn}.conf
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo mv /home/${username}/relay.metrics.${fqdn}.conf /etc/nginx/sites-available/relay.metrics.${fqdn}.conf"
          ssh -i ${ssh_key} ${username}@${fqdn} "sudo chown root:root /etc/nginx/sites-available/relay.metrics.${fqdn}.conf"

          cert_domains=( $(ssh -i ${ssh_key} ${username}@${fqdn} 'sudo certbot certificates 2>/dev/null | grep Domains:' | sed -r 's/Domains: //g') )
          if [[ " ${cert_domains[*]} " =~ " relay.metrics.${fqdn} " ]]; then
            echo "[${endpoint_name}/${region}/${fqdn}] detected relay.metrics.${fqdn} in cert domains (${cert_domains[@]})"
          else
            cert_domains+=( relay.metrics.${fqdn} )
            echo "[${endpoint_name}/${region}/${fqdn}] adding relay.metrics.${fqdn} to cert domains (${cert_domains[@]})"
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo ln -frs /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo certbot certonly --expand --agree-tos --no-eff-email --preferred-challenges http --webroot -w /var/www/html -m ops@manta.network -d $(_join_by ' -d ' ${cert_domains[@]})"
            ssh -i ${ssh_key} ${username}@${fqdn} '[ -f /etc/nginx/sites-available/default-ssl ] && sudo ln -frs /etc/nginx/sites-available/default-ssl /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} '[ -f /etc/nginx/sites-available/ws-proxy ] && sudo ln -frs /etc/nginx/sites-available/ws-proxy /etc/nginx/sites-enabled/default'
            ssh -i ${ssh_key} ${username}@${fqdn} "sudo ln -frs /etc/nginx/sites-available/relay.metrics.${fqdn}.conf /etc/nginx/sites-enabled/relay.metrics.${fqdn}.conf"
            ssh -i ${ssh_key} ${username}@${fqdn} 'sudo systemctl reload nginx.service'
          fi
        fi
      else
        echo "[${endpoint_name}/${region}/${fqdn}] cert checks skipped. lets encrypt rate limit was hit ${days_since_rate_limit_hit} days ago (${last_certbot_rate_limit})."
      fi

      target_manta_version=$(curl -sL https://raw.githubusercontent.com/Manta-Network/pulse/main/config/software-versions.yml | yq --arg fqdn ${fqdn} -r '.[$fqdn].manta')
      if [ "${target_manta_version}" != "null" ]; then
        observed_manta_version=$(ssh -i ${ssh_key} ${username}@${fqdn} 'dpkg -l manta &>/dev/null && /usr/bin/manta --version | cut -d" " -f2 | cut -d"-" -f1-2')
        if [ "${target_manta_version}" = "${observed_manta_version}" ]; then
          echo "[${endpoint_name}/${region}/${fqdn}] observed manta version: ${observed_manta_version} matches target manta version: ${target_manta_version}"
        elif [ -n "${target_unit}" ] && ssh -i ${ssh_key} ${username}@${fqdn} "
          curl -sLo /tmp/manta_${target_manta_version%%-*}_amd64.deb https://deb.manta.systems/pool/main/m/manta/manta_${target_manta_version%%-*}_amd64.deb;
          sudo dpkg -i /tmp/manta_${target_manta_version%%-*}_amd64.deb;
          rm /tmp/manta_${target_manta_version%%-*}_amd64.deb;
          sudo systemctl start ${target_unit}.service"; then
          echo "[${endpoint_name}/${region}/${fqdn}] updated observed manta version from: ${observed_manta_version} to target manta version: ${target_manta_version}"
        else
          echo "[${endpoint_name}/${region}/${fqdn}] failed to update observed manta version from: ${observed_manta_version} to target manta version: ${target_manta_version}"
        fi
      fi

      target_nvm_version=$(curl -sL https://raw.githubusercontent.com/Manta-Network/pulse/main/config/software-versions.yml | yq --arg fqdn ${fqdn} -r '.[$fqdn].manta')
      if [ "${target_nvm_version}" != "null" ]; then
        observed_nvm_version=$(ssh -i ${ssh_key} ${username}@${fqdn} 'nvm --version | cut -c1-')
        if [ "${target_nvm_version}" = "${observed_nvm_version}" ]; then
          echo "[${endpoint_name}/${region}/${fqdn}] observed nvm version: ${observed_nvm_version} matches target nvm version: ${target_nvm_version}"
        elif ssh -i ${ssh_key} ${username}@${fqdn} "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v${target_nvm_version}/install.sh | bash"; then
          echo "[${endpoint_name}/${region}/${fqdn}] updated observed nvm version from: ${observed_nvm_version} to target nvm version: ${target_nvm_version}"
        else
          echo "[${endpoint_name}/${region}/${fqdn}] failed to update observed nvm version from: ${observed_nvm_version} to target nvm version: ${target_nvm_version}"
        fi
      fi
    fi
  done
done
