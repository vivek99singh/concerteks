#!/bin/sh
# Renews one demo TLS certificate on EKS and reports it to Concert.
# Runs inside a Job created by the Concert workflow Renew_EKS_TLS_Certificate (see 05-cert-renewal-setup.sh).
#
#   1. Load the demo issuing CA from Secret demo-corp-ca (created on first use).
#   2. Issue a new 365-day certificate for $CN, signed by that CA.
#   3. Store it as Secret <APP>-tls (type kubernetes.io/tls) in this namespace.
#   4. Upload the new certificate record to Concert (data_type=certificate, metadata.source=$SOURCE).
#   5. Delete the old record ($OLD_SERIAL) from Concert, so it no longer shows as expired.
#
# Env: CN, APP, ACCESS_POINT, OLD_SERIAL, SOURCE, ENVIRONMENT, CONCERT_URL, CONCERT_API_KEY, CONCERT_INSTANCE_ID
set -eu
apk add --no-cache openssl curl jq bc >/dev/null

NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
SA=/var/run/secrets/kubernetes.io/serviceaccount
API=https://kubernetes.default.svc
k() { curl -sS --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" -H 'Content-Type: application/json' "$@"; }
c() { curl -sS -k -H "Authorization: C_API_KEY $CONCERT_API_KEY" -H "InstanceID: ${CONCERT_INSTANCE_ID:-0000-0000-0000-0000}" "$@"; }
tls_secret() {  # name crt key -> Secret JSON
  jq -n --arg n "$1" --arg a "$APP" --arg c "$(base64 -w0 "$2")" --arg k "$(base64 -w0 "$3")" \
    '{apiVersion:"v1",kind:"Secret",type:"kubernetes.io/tls",
      metadata:{name:$n,labels:{app:$a,"app.kubernetes.io/managed-by":"concert-workflows"}},
      data:{"tls.crt":$c,"tls.key":$k}}'
}
cd "$(mktemp -d)"

echo "[1/5] Demo issuing CA"
if [ "$(k -o ca.json -w '%{http_code}' "$API/api/v1/namespaces/$NS/secrets/demo-corp-ca")" = 200 ]; then
  jq -r '.data["tls.crt"]' ca.json | base64 -d > ca.crt
  jq -r '.data["tls.key"]' ca.json | base64 -d > ca.key
else
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/C=US/O=Demo Corp/CN=Demo Corp Issuing CA" \
    -keyout ca.key -out ca.crt 2>/dev/null
  APP=demo-corp-ca tls_secret demo-corp-ca ca.crt ca.key > ca-secret.json
  k -f -X POST -d @ca-secret.json "$API/api/v1/namespaces/$NS/secrets" >/dev/null
fi

echo "[2/5] Issue certificate for $CN"
openssl req -newkey rsa:2048 -nodes -subj "/CN=$CN" -keyout tls.key -out tls.csr 2>/dev/null
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$CN" > ext.cnf
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -extfile ext.cnf -out tls.crt 2>/dev/null

echo "[3/5] Store Secret $NS/$APP-tls"
tls_secret "$APP-tls" tls.crt tls.key > leaf-secret.json
if [ "$(k -o /dev/null -w '%{http_code}' "$API/api/v1/namespaces/$NS/secrets/$APP-tls")" = 200 ]; then
  k -f -X PUT -d @leaf-secret.json "$API/api/v1/namespaces/$NS/secrets/$APP-tls" >/dev/null
else
  k -f -X POST -d @leaf-secret.json "$API/api/v1/namespaces/$NS/secrets" >/dev/null
fi

echo "[4/5] Upload the new certificate record to Concert"
HEX=$(openssl x509 -in tls.crt -noout -serial | cut -d= -f2)
SERIAL=$(echo "ibase=16; $HEX" | BC_LINE_LENGTH=0 bc)
date_of() { openssl x509 -in tls.crt -noout "-$1" -dateopt iso_8601 | cut -d= -f2 | sed 's/Z$/ +0000 UTC/'; }
START=$(date_of startdate); END=$(date_of enddate)
ISSUER=$(openssl x509 -in tls.crt -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
META=$(jq -cn --arg s "$SOURCE" --arg sec "$NS/$APP-tls" '{source:$s,kubernetes_secret:$sec,renewed_by:"Concert Workflows"}')
jq -n --arg ser "$SERIAL" --arg cn "$CN" --arg iss "$ISSUER" --arg st "$START" --arg en "$END" --arg meta "$META" \
      --arg ap "$ACCESS_POINT" --arg env "$ENVIRONMENT" '
  {components:[{type:"certificate",ref:("certificate:"+$ser),serial_number:$ser,
     properties:[{name:"subject",value:("CN="+$cn)},{name:"issuer",value:$iss},
                  {name:"validity_start_date",value:$st},{name:"validity_end_date",value:$en},
                  {name:"certificate_type",value:"pem"},{name:"owner",value:"app-owner@example.com"},
                  {name:"metadata",value:$meta},{name:"dns_names",value:$cn}],
     access_points:[{name:$ap,is_public:"true",url:("https://"+$cn)}]}],
   dependencies:[{ref:("environment:"+$env),depends_on:[("certificate:"+$ser)]}]}' > certificates.json
c -f -H 'Accept: application/json' -F data_type=certificate \
  -F "filename=@certificates.json;type=application/octet-stream" "$CONCERT_URL/ingestion/api/v1/upload_files"
echo

echo "[5/5] Remove the old record from Concert"
if [ -n "${OLD_SERIAL:-}" ] && [ "$OLD_SERIAL" != "$SERIAL" ]; then
  c -f -X POST -H 'Content-Type: application/json' \
    -d "{\"certificates\":[\"$OLD_SERIAL\"],\"access_points\":[]}" "$CONCERT_URL/ingestion/api/v1/certificates/delete" \
    && echo "deleted $OLD_SERIAL" || echo "WARN: could not delete $OLD_SERIAL (check it in Concert)"
fi

echo "Renewed $CN: serial $SERIAL, valid $START -> $END, issuer $ISSUER, secret $NS/$APP-tls"
