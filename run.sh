#!/bin/bash
set -euo pipefail

docker-compose down -v || true

rm -rf step-ca conf hydra-sqlite || true

mkdir -p conf

cat > conf/hydra.yaml <<EOF
serve:
  cookies:
    same_site_mode: Lax
  public:
    tls:
      enabled: true
      cert:
        path: /etc/ory/cert.crt
      key:
        path: /etc/ory/cert.key
  admin:
    tls:
      enabled: true
      cert:
        path: /etc/ory/cert.crt
      key:
        path: /etc/ory/cert.key

urls:
  self:
    issuer: https://127.0.0.1:4444
  consent: http://127.0.0.1:3000/consent
  login: http://127.0.0.1:3000/login
  logout: http://127.0.0.1:3000/logout

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

docker-compose run --rm --entrypoint step step-ca ca init \
      --name step-ca \
      --dns step-ca \
      --dns 127.0.0.1 \
      --dns localhost \
      --address :443 \
      --deployment-type standalone \
      --provisioner admin \
      --provisioner-password-file /home/step/secrets/provisioner-password \
      --password-file /home/step/secrets/password \
      #

cat step-ca/certs/root_ca.crt > conf/ca-certificates.crt

docker-compose up -d step-ca

touch conf/cert.{crt,key}

docker-compose run --rm hydra 'migrate' '-c' '/etc/ory/hydra.yaml' 'sql' '-e' '--yes'
docker-compose up -d hydra

docker-compose exec step-ca step ca certificate \
    --san hydra \
    --san consent \
    --san step-ca \
    --san 127.0.0.1 \
    --san localhost \
    --provisioner-password-file /home/step/secrets/provisioner-password step-ca '/tmp/cert.crt' '/tmp/cert.key' \
    #

docker-compose exec step-ca cat /tmp/cert.crt > conf/cert.crt
docker-compose exec step-ca cat /tmp/cert.key > conf/cert.key

docker-compose up -d hydra
docker-compose up -d consent
sleep 2

docker-compose exec hydra hydra clients \
    create \
    --grant-types client_credentials \
    --grant-types authorization_code \
    --name step-ca \
    --secret step-ca \
    --response-types=code \
    --token-endpoint-auth-method client_secret_post \
    --scope="openid" \
    --scope="email" \
    --callbacks http://127.0.0.1:10000 \
    --id step-ca \
    #

docker-compose exec step-ca step ca provisioner add hydra \
    --type oidc \
    --ca-config /home/step/config/ca.json \
    --client-id step-ca \
    --client-secret step-ca \
    --configuration-endpoint https://hydra:4444 \
    #

docker-compose restart step-ca

coproc (docker-compose exec -T step-ca step ca certificate \
    --root /etc/ssl/certs/ca-certificates.crt \
    --provisioner hydra \
    --ca-url https://localhost foo@bar.com /tmp/p.crt /tmp/p.key 2>&1)
while read -r o <&"${COPROC[0]}" 2>/dev/null; do
    if [ "${o:0:4}" == "http" ]; then
        ./auth.sh "$o"
    fi
done 2>/dev/null

docker-compose exec step-ca cat /tmp/p.crt /tmp/p.key

printf 'Subject of private key: %s\n' "$(openssl x509 -in p.crt -subject -noout)"


# step-ca will listen to 127.0.0.1 here, which obviously will not work
#docker-compose exec step-ca step oauth \
#    --oidc \
#    --client-id step-ca \
#    --client-secret step-ca \
#    --provider https://hydra:4444 \
#    --listen=:10000 \
#    --redirect-url=http://127.0.0.1:10000 \
#    #


# Token generated!
#    --oidc \
#docker run \
#    -v $PWD/conf/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt \
#    -it \
#    --rm \
#    --net host smallstep/step-ca step oauth \
#    --client-id user \
#    --client-secret password \
#    --provider https://127.0.0.1:4444 \
#    --listen=127.0.0.1:10000 \
#    --redirect-url=http://127.0.0.1:10000 \
#    --oidc \
#    #

# Fails with
# error parsing token: square/go-jose: missing payload in JWS message
# Token looks like
# {
#  "access_token": "pa3oS1spO9gt5bya6420aLZDfa68FIW7u_NCiYx6AY8.772hTkHs7AwTuD_deVrLl9IPU3KpYcLbiqIly_PSxyU",
#  "id_token": "",
#  "refresh_token": "",
#  "expires_in": 3600,
#  "token_type": "bearer"
#}
