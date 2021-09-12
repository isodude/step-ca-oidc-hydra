#!/bin/bash
set -euo pipefail

docker-compose exec step-ca step ca certificate \
	--root /etc/ssl/certs/ca-certificates.crt \
	--token "$1" \
	--ca-url https://step-ca \
	--provisioner hydra  \
	foo@bar.com /output/p.crt /output/p.key
