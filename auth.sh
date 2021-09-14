#!/bin/bash

set -euo pipefail

declare -a cookies
cookies=()
old_location=
default=(-H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8' '--cacert' '/etc/ssl/certs/ca-certificates.crt' '-i' -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Site: cross-site' -H 'Sec-Fetch-User: ?1' -H 'TE: trailers' -H 'Upgrade-Insecure-Requests: 1' -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:91.0) Gecko/20100101 Firefox/91.0' -H 'Accept-Encoding: gzip, deflate, br' -H 'Accept-Language: en-US,en;q=0.5' -H 'Connection: Keep-alive' --compressed)
user='foo%40bar.com'
pass='foobar'
data=

function log()
{
    printf '%s\n' "$@"
}

function iinfo()
{
    i="$1"; shift
        info "[$i] $@"
}

function idie()
{
    i="$1"; shift
        die "$i" "[$i] $@"
}

function info()
{
    log "info: $@"
}

function die()
{
    code="$1"; shift
    log "die: $@"
    exit $code
}

function _curl()
{
  local ret_data origin cmd
  [ -n "$old_location" ] || old_location="$location"

  data=
  cmd=(
       "${default[@]}" 
       "${cookies[@]}"
       "$@"
       "$location")
  #info "Running: docker-compose run --rm curl ${cmd[*]}"
  old_location="$location"
  data="$(docker-compose run --rm curl "${cmd[@]}")"
  #info "Got $data"
}

####################
iinfo 1 "Asked Hydra for a Oauth2 Authentication CSRF Cookie"

location="$1"
_curl
cookies+=( -H "Cookie: oauth2_authentication_csrf=$(echo -e "$data" | grep -oP '(?<=: oauth2_authentication_csrf=)[^;]+' | tr -d '\r')")

location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"
challenge="$(echo $location | cut -d '=' -f 2)"


code="$(echo -e "$data" | grep -oP '(?<=HTTP/2 )[0-9]+' | tr -d '\r')"
[ "$code" == "302" ] || idie 1 "Got $code instead of 302"
iinfo 1 "Was redirected to consent app"

####################
iinfo 2 "Getting the login form at the consent app" \

_curl
cookies+=( -H "Cookie: _csrf=$(echo -e "$data" | grep -oP '(?<=: _csrf=)[^;]+' | tr -d '\r')")

location="$(echo $location | cut -d '?' -f 1)"
code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
f_csrf="$(echo -e "$data" | grep -oP '(?<=_csrf" value=")[^"]+')"
raw="_csrf=$f_csrf&challenge=$challenge&email=$user&password=$pass&submit=Log+in"

[ "$code" == "200" ] || idie 2 "Got $code instead of 200"
iinfo 2 "It worked, logging in"

###############
iinfo 3 "Logging in at the consent app"
_curl \
           -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-raw "$raw" \
    -H "Origin: $(echo "$location" | cut -d '/' -f 1,2,3)" \
    -H "Referer: $old_location" \
    #

referer="$(echo "$location" | cut -d '/' -f 1,2,3)/"
location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
[ "$code" == "302" ] || idie 3 "Got $code instead of 302"
iinfo 3 "It worked, redirected towards Hydra"

##############
iinfo 4 "Telling Hydra we managed to login"

_curl    -H "Referer: $referer"

location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"

#iinfo 4 "Getting Oauth2 Authentication Session Cookie"
#cookies+=(-H "Cookie: oauth2_authentication_session=$(echo -e "$data" | grep -oP '(?<=: oauth2_authentication_session=)[^;]+' | tr -d '\r')")

iinfo 4 "Getting Oauth2 Consent CSRF Cookie"
cookies+=(-H "Cookie: oauth2_consent_csrf=$(echo -e "$data" | grep -oP '(?<=: oauth2_consent_csrf=)[^;]+' | tr -d '\r')")

challenge="$(echo $location | cut -d '=' -f 2)"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/2 )[0-9]+' | tr -d '\r')"
[ "$code" == "302" ] || idie 4 "Got $code instead of 302"
iinfo 4 "Was redirected to consent app"

###############
iinfo 5 "Fetching the form for consent at the consent app"

_curl    -H "Referer: $referer"

referer="$location"
f_csrf="$(echo -e "$data" | grep -oP '(?<=_csrf" value=")[^"]+')"
challenge="$(echo -e "$data" | grep -oP '(?<=challenge" value=")[^"]+')"
raw="_csrf=$f_csrf&challenge=$challenge&grant_scope=openid&grant_scope=email&grant_scope=web-origins&grant_scope=role_list&grant_scope=profile&grant_scope=rules&grant_scope=address&grant_scope=phone&grant_scope=offline_access&grant_scope=microprofile-jwn&submit=Allow+access"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
[ "$code" == "200" ] || idie 5 "God $code instead of 200"
iinfo 5 "Successfully"

################
iinfo 6 "Allowing openid,email at the consent app"

_curl \
    -H "Referer: $referer" \
    -H "Origin: $(echo "$location" | cut -d '/' -f 1,2,3)" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-raw "$raw" \

referer="$(echo "$location" | cut -d '/' -f 1,2,3)/"
location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
[ "$code" == "302" ] || idie 6 "Got $code instead of 302"
iinfo 6 "Was redirected to hydra"
iinfo 6 "Allowing openid,email at the consent app"

###############
iinfo 7 "Telling Hydra we managed to consent"

_curl -H "Referer: $referer"
location="$(echo -e "$data" | grep -oP '(?<=: )http.+$' | tr -d '\r')"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/2 )[0-9]+' | tr -d '\r')"
[ "$code" == "302" ] || idie 7 "Got $code instead of 302"
iinfo 7 "Was redirected to callback app"

##############
iinfo 8 "Giving response to the callback url"

_curl -H "Referer: $referer"

code="$(echo -e "$data" | grep -oP '(?<=HTTP/1.1 )[0-9]+' | tr -d '\r')"
[ "$code" == "200" ] || idie 8 "Got $code instead of 200"
iinfo 8 "Successfully!"
