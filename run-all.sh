#!/usr/bin/env bash
# End-to-end build of the Concert 3.1.0 L3 demo on EKS, run from this Mac:
#   cluster -> install (in-cluster Job) -> post-install -> [pause: Concert API key] -> demo data
#
# Usage:
#   cp secrets.env.example secrets.env && chmod 600 secrets.env   # fill in once
#   ./run-all.sh              # resumes after the last completed stage
#   ./run-all.sh --from install   # re-run from a stage: cluster | install | post-install | demo-data
#   ./scripts/99-teardown.sh  # delete everything afterwards
#
# Each stage is idempotent and recorded in .run-state, so after a failure fix the cause and re-run.
# The Mac is kept awake with caffeinate. Output is also written to logs/run-all-<time>.log.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

if [[ -z ${CAFFEINATED:-} ]] && command -v caffeinate >/dev/null; then
  CAFFEINATED=1 exec caffeinate -dims "$0" "$@"
fi

STAGES="cluster install post-install demo-data"
STATE=$HERE/.run-state
mkdir -p "$HERE/logs"
touch "$STATE"
exec > >(tee -a "$HERE/logs/run-all-$(date +%Y%m%d-%H%M).log") 2>&1
log() { echo; echo "===== [$(date +%H:%M:%S)] $* ====="; }

if [[ ${1:-} == --from ]]; then
  case " $STAGES " in *" ${2:-} "*) ;; *) echo "--from needs one of: $STAGES"; exit 1;; esac
  # forget the given stage and every stage after it
  keep=""; for s in $STAGES; do [[ $s == "$2" ]] && break; grep -qx "$s" "$STATE" && keep="$keep $s"; done
  : > "$STATE"; for s in $keep; do echo "$s" >> "$STATE"; done
fi

[[ -f $HERE/secrets.env ]] && source "$HERE/secrets.env"
export CLUSTER=${CLUSTER:-concert-demo} REGION=${REGION:-us-east-1}

ask() {  # ask <VAR> <prompt>: prompt (hidden) only if the variable is empty
  local var=$1 val
  [[ -n ${!var:-} ]] && return
  [[ -t 0 ]] || { echo "$var is empty in secrets.env (no terminal to prompt)"; exit 1; }
  read -r -s -p "$2: " val; echo
  [[ -n $val ]] || { echo "$var is required"; exit 1; }
  export "$var=$val"
}

log "Pre-flight"
TOOLS="aws kubectl helm docker trivy python3 curl"; [[ $(uname) == Darwin ]] && TOOLS="$TOOLS colima"
for tool in $TOOLS; do
  command -v $tool >/dev/null || { echo "Missing tool: $tool (brew install $tool)"; exit 1; }
done
aws sts get-caller-identity --query Arn --output text
ask IBM_ENTITLEMENT_KEY "IBM entitlement key"
ask WATSONX_API_KEY "watsonx.ai API key"
ask WATSONX_API_PROJECT_ID "watsonx.ai project ID"
ask CONCERT_ADMIN_PASSWORD "Concert admin password"
export IBM_ENTITLEMENT_KEY WATSONX_API_KEY WATSONX_API_PROJECT_ID CONCERT_ADMIN_PASSWORD
echo "Completed stages: $(echo $(cat "$STATE"))"

START=$(date +%s)
done_stage() { grep -qx "$1" "$STATE"; }
run_stage() {
  local name=$1; shift
  if done_stage "$name"; then echo "skip $name (already done)"; return; fi
  log "STAGE $name"
  local t=$(date +%s)
  "$@"
  echo "$name" >> "$STATE"
  echo "stage $name finished in $(( ($(date +%s) - t) / 60 )) min"
}

concert_url() {
  echo "https://$(kubectl get svc -n concert-ingress-nginx concert-ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
}
wait_for_concert() {
  local url code=""; url=$(concert_url)
  echo "Waiting for $url to answer (ELB DNS takes a few minutes)"
  for _ in $(seq 1 40); do
    code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 "$url/" || true)
    [[ $code =~ ^(200|30[0-9]|401)$ ]] && { echo "Concert answered HTTP $code"; return; }
    sleep 15
  done
  echo "Concert did not answer within 10 min (last HTTP code: ${code:-none}). Check: kubectl get pods -n concert"
  return 1
}
post_install() {
  "$HERE/scripts/02-post-install.sh"
  wait_for_concert
}
demo_data() {
  if [[ -z ${CONCERT_API_KEY:-} ]]; then
    cat <<EOF

------------------------------------------------------------------
 Manual step: generate a Concert API key
   1. Open $(concert_url)  (user admin, password from CONCERT_ADMIN_PASSWORD;
      accept the self-signed certificate warning)
   2. Profile (top right) -> API key -> Generate, then copy it
------------------------------------------------------------------
EOF
    if [[ -t 0 ]]; then
      ask CONCERT_API_KEY "Paste the Concert API key"
    else
      # Running unattended (no terminal): wait for the key to be added to secrets.env
      echo "Waiting for CONCERT_API_KEY to be set in secrets.env (checking every 30s for up to 3 h)"
      for _ in $(seq 1 360); do
        CONCERT_API_KEY=$(source "$HERE/secrets.env" && echo "${CONCERT_API_KEY:-}")
        [[ -n $CONCERT_API_KEY ]] && break
        sleep 30
      done
      [[ -n $CONCERT_API_KEY ]] || { echo "CONCERT_API_KEY was never set"; exit 1; }
    fi
  fi
  export CONCERT_API_KEY
  [[ $(uname) == Darwin ]] && { colima status >/dev/null 2>&1 || colima start; }
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
  (cd "$HERE/demo-data" && ./load-demo-data.sh all)
}

run_stage cluster      "$HERE/scripts/00-create-cluster.sh"
run_stage install      "$HERE/scripts/01-install-in-cluster.sh"
run_stage post-install post_install
run_stage demo-data    demo_data

WF=$(kubectl get svc -A --field-selector metadata.name=solis-gw-ext -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
log "ALL DONE in $(( ($(date +%s) - START) / 60 )) min"
cat <<EOF
Concert   : $(concert_url)
Workflows : https://$WF

Remaining manual steps (README section 2), about 10 minutes:
  1. Workflows -> Authentications -> Create: name concert-self, service "IBM Hub - Self"
  2. Concert -> Administration -> Integrations -> Connections -> GitHub (api.github.com + PAT with repo scope);
     enable Issues on the juice-shop fork
  3. Check that "Ask watsonx" answers
  4. Wait about 15 min for ingestion (Integrations -> Ingestion jobs), then fill in "Values to capture"
     at the top of Concert_3.1_L3_Demo_Script.md
Optional: (cd demo-data && ./load-demo-data.sh compliance)   # EKS CIS benchmark
Teardown: ./scripts/99-teardown.sh
EOF
