#!/bin/bash
set -euo pipefail

printf 'Purge existing dockers..'
out="$(docker-compose down -v 2>&1)"
if [ $? -ne 0 ]; then
  printf 'failed! %s\n' "$out"
fi
printf 'OK!\n'

rm -rf step-ca conf hydra-sqlite || true

mkdir -p conf

cat > conf/Caddyfile <<EOF
https://caddy:10000 {
  tls /cert.crt /cert.key {
    ca_root /etc/ssl/certs/ca-certificates.crt
  }
  reverse_proxy http://step-ca-host:10000
}
https://caddy:443 {
  tls /cert.crt /cert.key {
    ca_root /etc/ssl/certs/ca-certificates.crt
  }
  reverse_proxy https://step-ca
}
https://caddy:4444 {
  tls /cert.crt /cert.key {
    ca_root /etc/ssl/certs/ca-certificates.crt
  }
  reverse_proxy https://hydra:4444
}
https://caddy:3000 {
  tls /cert.crt /cert.key {
    ca_root /etc/ssl/certs/ca-certificates.crt
  }
  reverse_proxy http://consent:3000
}
EOF

cat > conf/hydra.yaml <<EOF
serve:
  cookies:
    same_site_mode: Lax
  public:
    tls:
      enabled: true
      cert:
        path: /cert.crt
      key:
        path: /cert.key
  admin:
    tls:
      enabled: true
      cert:
        path: /cert.crt
      key:
        path: /cert.key

urls:
  self:
    issuer: https://caddy:4444
  consent: https://caddy:3000/consent
  login: https://caddy:3000/login
  logout: https://caddy:3000/logout

secrets:
  system: [ $(cat /proc/sys/kernel/random/uuid) ]

oidc:
  subject_identifiers:
    supported_types:
      - pairwise
      - public
    pairwise:
      salt: $(cat /proc/sys/kernel/random/uuid)
log:
  leak_sensitive_values: true
EOF

mkdir -p step-ca/secrets/
cat /proc/sys/kernel/random/uuid > step-ca/secrets/password
cat /proc/sys/kernel/random/uuid > step-ca/secrets/provisioner-password

touch conf/ca-certificates.crt

out="$(docker-compose run --rm --entrypoint step step-ca ca init \
      --name step-ca \
      --dns step-ca \
      --address :443 \
      --deployment-type standalone \
      --provisioner admin \
      --provisioner-password-file /home/step/secrets/provisioner-password \
      --password-file /home/step/secrets/password 2>&1 \
      #
)"
if [ $? -ne 0 ]; then
  printf 'Step-ca init failed: %s\n' "$out"
fi

cat step-ca/certs/root_ca.crt > conf/ca-certificates.crt

printf 'Starting step-ca..'
out="$(docker-compose up -d step-ca 2>&1)"
while [ "$(docker-compose exec step-ca step ca health 2>/dev/null | tr -d '\r\n')" != 'ok' ]; do
  printf '.'
  sleep 1
done
printf 'OK!\n'


out="$(docker-compose exec step-ca step ca certificate \
    --san hydra \
    --san consent \
    --san step-ca \
    --san localhost \
    --san caddy \
    --provisioner-password-file /home/step/secrets/provisioner-password step-ca '/conf/cert.crt' '/conf/cert.key' 2>&1 \
    #
)"
if [ $? -ne 0 ]; then
  printf 'Step-ca certificate failed: %s\n' "$out"
fi

chmod a+r ./conf/cert.crt ./conf/cert.key

printf 'Starting caddy..'
out="$(docker-compose up -d caddy 2>&1)"
i=0
while [ "$(docker-compose run --rm curl --cacert /etc/ssl/certs/ca-certificates.crt --write-out '%{http_code}' --output /dev/null  --silent https://caddy 2>/dev/null)" != '404' ]; do
  if [ $i -eq 10 ]; then
    printf 'NOT OK: %s\n %s\n' "$out" "$(docker-compose run --rm curl --cacert /etc/ssl/certs/ca-certificates.crt -i https://caddy 2>&1)"
    exit 1
  fi
  printf '.'
  i=$((i+1))
done
printf 'OK!\n'

out="$(docker-compose run --rm hydra 'migrate' '-c' '/etc/ory/hydra.yaml' 'sql' '-e' '--yes')"
if [ $? -ne 0 ]; then
  printf 'Hydra init failed: %s\n' "$out"
fi

printf 'Starting hydra..'
out="$(docker-compose up -d hydra 2>&1)"
i=0
while [ "$(docker-compose run --rm curl --cacert /etc/ssl/certs/ca-certificates.crt https://hydra:4444/health/ready 2>/dev/null | jq -c 2>/dev/null)" != '{"status":"ok"}' ]; do
  if [ $i -eq 10 ]; then
    printf 'NOT OK: %s\n %s\n' "$out" "$(docker-compose run --rm curl --cacert /etc/ssl/certs/ca-certificates.crt -i https://caddy 2>&1)"
    exit 1
  fi
  printf '.'
  i=$((i+1))
done
printf 'OK!\n'

printf 'Starting consent..'
out="$(docker-compose up -d consent 2>&1)"
i=0
while [ "$(docker-compose run --rm curl --cacert /etc/ssl/certs/ca-certificates.crt --write-out '%{http_code}' --output /dev/null  --silent http://consent:3000 2>/dev/null)" != '200' ]; do
  if [ $i -eq 10 ]; then
    printf 'NOT OK: %s\n %s\n' "$out" "$(docker-compose run --rm curl --cacert /etc/ssl/certs/ca-certificates.crt -i https://caddy 2>&1)"
    exit 1
  fi
  printf '.'
  i=$((i+1))
done
printf 'OK!\n'
sleep 2

printf 'Hydra: Adding step-ca client\n'
out="$(docker-compose exec hydra hydra clients \
    create \
    --grant-types client_credentials \
    --grant-types authorization_code \
    --name step-ca \
    --secret step-ca \
    --response-types=code \
    --token-endpoint-auth-method client_secret_post \
    --scope="openid" \
    --scope="email" \
    --callbacks http://127.0.0.1 \
    --id step-ca 2>&1 )"
if [ $? -ne 0 ]; then
  printf 'Hydra client add failed: %s\n' "$out"
fi

out="$(docker-compose exec step-ca step ca provisioner add hydra \
    --type oidc \
    --ca-config /home/step/config/ca.json \
    --client-id step-ca \
    --client-secret step-ca \
    --configuration-endpoint https://caddy:4444 2>&1 )"
if [ $? -ne 0 ]; then
  printf 'Hydra client add failed: %s\n' "$out"
fi
 
printf 'Step-ca: restarting\n'
out="$(docker-compose restart step-ca 2>&1)"
i=0
while [ "$(docker-compose exec step-ca step ca health 2>/dev/null | tr -d '\r\n')" != 'ok' ]; do
  if [ $i -eq 10 ]; then
    printf 'step-ca restart failed: %s\n %s\n' "$out" "$(docker-compose exec step-ca step ca health 2>&1)"
    exit 1
  fi
  printf '.'
  i=$((i+1))
done
printf 'OK!\n'

printf 'Starting to auth\n'
coproc ( docker-compose run --rm -T step-ca-host step ca certificate \
    --root /etc/ssl/certs/ca-certificates.crt \
    --provisioner hydra \
    --ca-url https://caddy foo@bar.com /conf/client.crt /conf/client.key 2>&1)

while read -r o <&"${COPROC[0]}"; do
    if [ "${o:0:4}" == "http" ]; then
      printf 'Authing to: %s\n' "$o"
      ./auth.sh "$o"
    fi
done 2>/dev/null

printf 'Subject of private key: %s\n' "$(openssl x509 -in ./conf/client.crt -subject -noout)"
