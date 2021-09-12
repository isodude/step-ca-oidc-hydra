#!/bin/bash

set -euo pipefail

data="$(docker-compose run --rm curl -i --cacert /etc/ssl/certs/ca-certificates.crt "$1")"

oauth2_authentication_csrf="$(echo -e "$data" | grep -oP '(?<=: oauth2_authentication_csrf=)[^;]+' | tr -d '\r')"
location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"
challenge="$(echo $location | cut -d '=' -f 2)"
code="$(echo -e "$data" | grep -oP '(?<=HTTP/2 )[0-9]+' | tr -d '\r')"

if [ "$code" == "302" ]; then
	printf '[1] %s\n' \
		"Asked Hydra for a Oauth2 Authentication CSRF Cookie" \
	        "Was redirected to consent app" \
		""
else
	printf '[1] %s\n' \
		"Asked Hydra for a Oauth2 Authentication CSRF Cookie" \
		"Got $code instead of 302" \
		""
	exit 1
fi


data="$(docker-compose run --rm curl -i "$location")"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
h_csrf="$(echo -e "$data" | grep -oP '(?<=: _csrf=).+$' | tr -d '\r')"
f_csrf="$(echo -e "$data" | grep -oP '(?<=_csrf" value=")[^"]+')"

user='foo%40bar.com'
pass='foobar'
raw="_csrf=$f_csrf&challenge=$challenge&email=$user&password=$pass&submit=Log+in"

if [ "$code" == "200" ]; then
	printf '[2] %s\n' \
		"Getting the login form at the consent app" \
		"It worked, logging in" \
		""
else
	printf '[2] %s\n' \
		"Getting the login form at the consent app" \
		"he consent app" \
		"Got $code instead of 200" \
		""
	exit 1
fi

data="$(docker-compose run --rm curl \
    -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'Origin: http://consent:3000' \
    -H "Referer: http://consent:3000/login?login_challenge=$challenge" \
    -H "Cookie: _csrf=$h_csrf" \
    --data-raw "$raw" -i \
    "$location")"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"

if [ "$code" == "302" ]; then
	printf '[3] %s\n' \
		"Logging in at the consent app" \
		"It worked, redirected towards Hydra" \
		""
else
	printf '[3] %s\n' \
		"Logging in at the consent app" \
		"Got $code instead of 302" \
		""
	exit 1
fi


data="$(docker-compose run --rm curl \
	-H "Cookie: oauth2_authentication_csrf=$oauth2_authentication_csrf" \
	--cacert /etc/ssl/certs/ca-certificates.crt -i "$location")"

oauth2_authentication_session="$(echo -e "$data" | grep -oP '(?<=: oauth2_authentication_session=)[^;]+' | tr -d '\r')"
oauth2_consent_csrf="$(echo -e "$data" | grep -oP '(?<=: oauth2_consent_csrf=)[^;]+' | tr -d '\r')"
location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"
challenge="$(echo $location | cut -d '=' -f 2)"
code="$(echo -e "$data" | grep -oP '(?<=HTTP/2 )[0-9]+' | tr -d '\r')"

if [ "$code" == "302" ]; then
	printf '[4] %s\n' \
		"Telling Hydra we managed to login" \
		"Getting Oauth2 Authentication Session Cookie" \
		"Getting Oauth2 Consent CSRF Cookie" \
		"Was redirected to consent app" \
		""
else
	printf '[4] %s\n' \
		"Telling Hydra we managed to login" \
		"Got $code instead of 302" \
		""
	exit 1
fi

data="$(docker-compose run --rm curl \
	-H "Cookie: oauth2_authentication_session=$oauth2_authentication_session" \
	-H "Cookie: oauth2_consent_csrf:$oauth2_consent_csrf" \
	--cacert /etc/ssl/certs/ca-certificates.crt -i "$location")"


h_csrf="$(echo -e "$data" | grep -oP '(?<=: _csrf=).+$' | tr -d '\r')"
f_csrf="$(echo -e "$data" | grep -oP '(?<=_csrf" value=")[^"]+')"
challenge="$(echo -e "$data" | grep -oP '(?<=challenge" value=")[^"]+')"
raw="_csrf=$f_csrf&challenge=$challenge&openid=on&email=on&submit=Allow+access"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
if [ "$code" == "200" ]; then
	printf '[5] %s\n' \
		"Fetching the form for consent at the consent app" \
		"Successfully" \
		""
else
	printf '[5] %s\n' \
		"Fetching the form for consent at the consent app" \
		"Got $code instead of 200" \
		""
	exit 1
fi


data="$(docker-compose run --rm curl \
    -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -H 'Origin: https://hydra:4444' \
    -H "Referer: $location" \
    -H "Cookie: _csrf=$h_csrf" \
    --data-raw "$raw" -i \
    "$location" || true)"

location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
if [ "$code" == "302" ]; then
	printf '[6] %s\n' \
		"Allowing openid,email at the consent app" \
		"Was redirected to hydra" \
		""
else
	printf '[6] %s\n' \
		"Allowing openid,email at the consent app" \
		"Got $code instead of 302" \
		""
	exit 1
fi


data="$(docker-compose run --rm curl \
	-H "Cookie: oauth2_consent_csrf=$oauth2_consent_csrf" \
	-H "Cookie: oauth2_authentication_csrf=$oauth2_authentication_csrf" \
	--cacert /etc/ssl/certs/ca-certificates.crt -i "$location" || true)"

location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/2 )[0-9]+' | tr -d '\r')"
if [ "$code" == "302" ]; then
	printf '[7] %s\n' \
		"Telling Hydra we managed to consent" \
		"Using Oauth2 Authentication CSRF Cookie" \
		"Using Oauth2 Consent CSRF Cookie" \
		"Was redirected to callback app" \
		""
else
	printf '[7] %s\n' \
		"Telling Hydra we managed to consent" \
		"Got $code instead of 302" \
		""
	exit 1
fi


data="$(curl \
	--cacert /etc/ssl/certs/ca-certificates.crt -i "$location" || true)"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
if [ "$code" == "302" ]; then
	printf '[8] %s\n' \
		"Giving response to the callback url" \
	        "Successfully!" \
		""
else
	printf '[8] %s\n' \
		"Giving response to the callback url" \
	        "Something failed with code $code" \
		""
	echo -e "$data"
	exit 1
fi
