#!/usr/bin/env bash
# Cluster-side setup for the Concert workflow Renew_EKS_TLS_Certificate (workflows/Renew_EKS_TLS_Certificate.yaml).
#
# Creates in namespace demo-apps:
#   - ConfigMap cert-renewer-script   (scripts/cert-renewal/renew.sh)
#   - ServiceAccount cert-renewer + Role/RoleBinding: secrets get/create/update (Job identity)
#   - Secret concert-api               (in-cluster Concert URL + API key, read by the Job)
#   - Role/RoleBinding concert-workflows-jobs: lets SA demo-apps/concert-workflows (the token behind the
#     eks-demo-apps authentication in Concert Workflows) create and read Jobs in demo-apps
#
# Usage: ./scripts/05-cert-renewal-setup.sh        (reads CONCERT_API_KEY from secrets.env)
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f ./secrets.env ]] && { set -a; . ./secrets.env; set +a; }   # CI passes the env vars instead
: "${CONCERT_API_KEY:?CONCERT_API_KEY missing (secrets.env or environment)}"
NS=demo-apps

kubectl -n "$NS" create configmap cert-renewer-script --from-file=renew.sh=scripts/cert-renewal/renew.sh \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic concert-api \
  --from-literal=CONCERT_URL=https://ibm-concert-solis-gw-svc.concert.svc:11443/concert \
  --from-literal=CONCERT_API_KEY="$CONCERT_API_KEY" \
  --from-literal=CONCERT_INSTANCE_ID=0000-0000-0000-0000 \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: cert-renewer, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: cert-renewer, namespace: $NS}
rules:
- apiGroups: [""]
  resources: [secrets]
  verbs: [get, create, update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: cert-renewer, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: cert-renewer}
subjects: [{kind: ServiceAccount, name: cert-renewer, namespace: $NS}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: concert-workflows-jobs, namespace: $NS}
rules:
- apiGroups: [batch]
  resources: [jobs, jobs/status]
  verbs: [get, list, create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: concert-workflows-jobs, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: concert-workflows-jobs}
subjects: [{kind: ServiceAccount, name: concert-workflows, namespace: $NS}]
EOF
echo "Cert renewal setup applied in $NS."
