#!/usr/bin/env bash
# Kubernetes identities that Concert and Concert Workflows use to talk to this EKS cluster.
# Run after the sample apps are deployed (namespace demo-apps). Safe to re-run.
#
#   kube-system/concert-discovery  read-only (get/list/watch on everything) for Concert's Kubernetes connection,
#                                  used by "Discover your data" (Resilience and Protect)
#   demo-apps/concert-workflows    scoped to namespace demo-apps: read/patch deployments, create/read Jobs
#                                  (the Kubernetes authentication in Concert Workflows)
#
# Writes the values to paste into the UI to discovery-connection/ (git-ignored):
#   api-server-url.txt  ca.crt  token.txt (discovery)  workflows-token.txt (workflows)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../discovery-connection
NS=${DEMO_NS:-demo-apps}
mkdir -p "$OUT" && chmod 700 "$OUT"
log() { echo "[$(date +%H:%M:%S)] $*"; }

kubectl get namespace "$NS" >/dev/null || { echo "Namespace $NS not found. Deploy the sample apps first (load-demo-data.sh deploy)."; exit 1; }

log "1/2 Read-only discovery account kube-system/concert-discovery"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: concert-discovery, namespace: kube-system}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: concert-discovery-readonly}
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: concert-discovery-readonly}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: concert-discovery-readonly}
subjects: [{kind: ServiceAccount, name: concert-discovery, namespace: kube-system}]
---
apiVersion: v1
kind: Secret
metadata:
  name: concert-discovery-token
  namespace: kube-system
  annotations: {kubernetes.io/service-account.name: concert-discovery}
type: kubernetes.io/service-account-token
EOF

log "2/2 Scoped Workflows account $NS/concert-workflows"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: concert-workflows, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: concert-workflows-deployments, namespace: $NS}
rules:
- apiGroups: [apps]
  resources: [deployments, deployments/status, deployments/scale]
  verbs: [get, list, watch, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: concert-workflows-deployments, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: concert-workflows-deployments}
subjects: [{kind: ServiceAccount, name: concert-workflows, namespace: $NS}]
---
apiVersion: v1
kind: Secret
metadata:
  name: concert-workflows-token
  namespace: $NS
  annotations: {kubernetes.io/service-account.name: concert-workflows}
type: kubernetes.io/service-account-token
EOF

token() {  # namespace secret -> token (waits for the token controller to fill it)
  local t=""
  for _ in $(seq 1 30); do
    t=$(kubectl get secret "$2" -n "$1" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [[ -n $t ]] && { printf '%s' "$t"; return; }
    sleep 2
  done
  echo "Token for $1/$2 was not created" >&2; exit 1
}
umask 077
token kube-system concert-discovery-token > "$OUT/token.txt"
token "$NS" concert-workflows-token > "$OUT/workflows-token.txt"
kubectl get secret concert-discovery-token -n kube-system -o jsonpath='{.data.ca\.crt}' | base64 -d > "$OUT/ca.crt"
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' > "$OUT/api-server-url.txt"

API=$(cat "$OUT/api-server-url.txt")
cat <<EOF

Done. Values for the Concert UI (files in discovery-connection/):
  Concert connection (Kubernetes):  endpoint $API
                                    token    discovery-connection/token.txt
  Workflows authentication:         protocol https://, host ${API#https://}
                                    apiKey   discovery-connection/workflows-token.txt  (raw token, NO "Bearer " prefix)
EOF
