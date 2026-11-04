#!/usr/bin/env bash
# Post-install for Concert v3.1.0 on EKS: NGINX ingress, Concert ingress route, health checks.
# Run from CloudShell after 01-install-concert.sh reports DEPLOYMENT SUCCESSFUL. Safe to re-run.
set -euo pipefail
CONCERT_NS=${CONCERT_NS:-concert}
HUB_NS=${HUB_NS:-concert-hub}
WF_NS=ibm-concert-workflows
log() { echo "[$(date +%H:%M:%S)] $*"; }

log "1/5 NGINX ingress controller (buffer settings required by Concert; note the space in '8 64k')"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
cat > /tmp/nginx-values.yaml <<'EOF'
controller:
  config:
    large-client-header-buffers: "8 64k"
    proxy-buffer-size: "64k"
    proxy-buffers-number: "8"
    proxy-busy-buffers-size: "128k"
EOF
helm upgrade --install concert-ingress-nginx ingress-nginx/ingress-nginx \
  --namespace concert-ingress-nginx --create-namespace -f /tmp/nginx-values.yaml --wait

log "2/5 Concert ingress"
GW_SVC=ibm-concert-solis-gw-svc   # the Concert UI gateway on 11443 (3.1 also has ibm-concert-external-gw-svc on 10443; that one returns 503 here)
kubectl get svc "$GW_SVC" -n "$CONCERT_NS" >/dev/null || { echo "No Concert gateway service found in $CONCERT_NS"; kubectl get svc -n "$CONCERT_NS"; exit 1; }
log "Concert gateway service: $GW_SVC"
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: concert
  namespace: $CONCERT_NS
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    # SAST/SBOM uploads exceed NGINX's 1 MB default (413 Request Entity Too Large)
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $GW_SVC
            port:
              number: 11443
EOF

log "3/5 Pods not Running/Completed (should be empty)"
kubectl get pods -A --no-headers | grep -Ev 'Running|Completed' || echo "none"
kubectl get pvc -A --no-headers | grep -v Bound || echo "all PVCs Bound"

log "4/5 Product registration with Hub (expect concert, dataapps and workflows)"
kubectl get configmap solis-account-instances-cm -n "$HUB_NS" -o json | python3 -c '
import sys, json
d = json.load(sys.stdin)["data"]
found = {i["product_id"]: i["instance_url"] for k, v in d.items() if k.endswith(".json") for i in json.loads(v)}
for p, url in found.items(): print(" ", p, url)
for p in ("concert", "dataapps", "workflows"):
    if p not in found: print("WARN:", p, "is not registered with Hub. Fix: Section 12 of the 3.0 guide.")
' || echo "WARN: could not read solis-account-instances-cm. If Workflows shows 403, see Section 12 of the 3.0 guide."
kubectl get pods -n dataapps --no-headers 2>/dev/null | grep -Ev 'Running|Completed' || echo "  dataapps pods OK"

log "5/5 AI agents (3.1.0 registers them via a job; check before running register-agents.sh)"
kubectl get pods -n "$HUB_NS" --no-headers | grep -E 'itom|agent' || echo "WARN: no ITOM pods. Was ENABLE_CROSS_PRODUCT_INTEGRATION=true?"
kubectl get configmap -n "$HUB_NS" | grep -i agent-card || true

log "Home + AI gateway menu (ITOM injects these with jq; re-applied here in case jq was missing during setup)"
# IBM's helper scripts come from the public release package (the same one the installer uses), cached locally
CONCERT_VERSION=${CONCERT_VERSION:-v3.1.0}
PKG=${CONCERT_PKG_DIR:-$HOME/.cache/ibm-concert-$CONCERT_VERSION}
if [[ ! -f $PKG/ibm-concert/concert-hub/bin/setup-keycloak.sh ]]; then
  mkdir -p "$PKG"
  curl -fsSL "https://github.com/IBM/Concert/releases/download/$CONCERT_VERSION/ibm-concert-x86.tar.gz" | tar xz -C "$PKG"
fi
HUB_BIN=$PKG/ibm-concert/concert-hub/bin
# add_home_menu_to_platform is taken verbatim from the package (itom/utils/bin/deploy-k8s.sh) and is idempotent
print_info() { echo "  $*"; }; print_success() { echo "  OK: $*"; }
print_warning() { echo "  WARN: $*"; }; print_error() { echo "  ERROR: $*"; }
eval "$(awk '/^add_home_menu_to_platform\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$PKG/ibm-concert/itom/utils/bin/deploy-k8s.sh")"
add_home_menu_to_platform "$HUB_NS" || echo "WARN: Home menu injection failed; the Home page may be missing"

CONCERT_LB=$(kubectl get svc -n concert-ingress-nginx concert-ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
WF_LB=$(kubectl get svc -n "$WF_NS" solis-gw-ext -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

log "Keycloak login (3.1 'Log in with SSO' uses Hub's embedded Keycloak; without this: 'OIDC client credentials could not be loaded')"
# Keycloak is only served by the Hub gateway, so route /sys/internal/kc to it
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: concert-hub-keycloak
  namespace: $HUB_NS
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /sys/internal/kc
        pathType: Prefix
        backend:
          service:
            name: ibm-solis-hub-gw-svc
            port:
              number: 11443
EOF
for _ in $(seq 1 40); do
  [[ $(curl -ks -o /dev/null -w '%{http_code}' "https://$CONCERT_LB/sys/internal/kc/realms/master") == 200 ]] && break
  sleep 15
done
# IBM's script (from the package's concert-hub/bin) needs bash 4+
BASH4=$(command -v /opt/homebrew/bin/bash || command -v /usr/local/bin/bash || command -v bash)
"$BASH4" "$HUB_BIN/setup-keycloak.sh" --kc-url="https://$CONCERT_LB/sys/internal/kc" --namespace="$HUB_NS" \
  --product-url="https://$CONCERT_LB" --username=admin --password="${CONCERT_ADMIN_PASSWORD:?}" \
  | sed "s/${CONCERT_ADMIN_PASSWORD}/<redacted>/g"

if [[ -n ${WATSONX_API_KEY:-} ]]; then
  log "watsonx.ai credentials (setup's ENABLE_AI did not write them in 3.1.0)"
  b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  # Concert 'Ask watsonx': IBM docs, 3.1.x 'Configuring watsonx.ai for Concert'
  kubectl patch secret/app-cfg-secret -n "$CONCERT_NS" --type=merge -p "{\"data\":{\
\"WATSONX_API_KEY\":\"$(b64 "$WATSONX_API_KEY")\",\
\"WATSONX_API_PROJECT_ID\":\"$(b64 "$WATSONX_API_PROJECT_ID")\",\
\"WATSONX_API_URL\":\"$(b64 "${WATSONX_API_URL:-https://us-south.ml.cloud.ibm.com}")\"}}"
  kubectl rollout restart -n "$CONCERT_NS" deployment/roja-py-utils
  # Hub AI agents: ibm-itom-llm-binding reads WATSONX_* from the optional itom-external-secrets secret
  kubectl create secret generic itom-external-secrets -n "$HUB_NS" \
    --from-literal=WATSONX_API_KEY="$WATSONX_API_KEY" \
    --from-literal=WATSONX_PROJECT_ID="$WATSONX_API_PROJECT_ID" \
    --from-literal=WATSONX_URL="${WATSONX_API_URL:-https://us-south.ml.cloud.ibm.com}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart -n "$HUB_NS" deployment/ibm-itom-llm-binding
  kubectl rollout status -n "$CONCERT_NS" deployment/roja-py-utils --timeout=5m
  kubectl rollout status -n "$HUB_NS" deployment/ibm-itom-llm-binding --timeout=5m
else
  echo "WARN: WATSONX_API_KEY not set; Concert AI features will say 'watsonx isn't connected'"
fi
echo
echo "Concert   : https://$CONCERT_LB   (admin / <CONCERT_ADMIN_PASSWORD>)"
echo "Workflows : https://$WF_LB"
echo "ELB DNS can take 2-5 minutes to resolve."
