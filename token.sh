#!/bin/bash
set -euo pipefail
token="$(echo "$1" | jq -c)"

echo "$token" | docker run --rm -v $PWD/token:/token -i --entrypoint step smallstep/step-ca crypto jws inspect --insecure
docker-compose exec step-ca step ca certificate \
	--root /etc/ssl/certs/ca-certificates.crt \
	--token "$token" \
	--ca-url https://step-ca \
	--provisioner hydra  \
	foo@bar.com /output/p.crt /output/p.key
