#!/usr/bin/env bash
# Installs IBM Concert v3.1.0 (Hub + Concert + Workflows, AI enabled) on an existing EKS cluster.
# Runs on Linux only (the installer needs bash 4+). run-all.sh runs it inside the cluster as a Job
# (scripts/01-install-in-cluster.sh); it also still works from AWS CloudShell.
#
# Required env vars:
#   IBM_ENTITLEMENT_KEY      key from https://myibm.ibm.com/products-services/containerlibrary
#   WATSONX_API_KEY          IBM Cloud API key for watsonx.ai SaaS
#   WATSONX_API_PROJECT_ID   watsonx.ai project ID
#   CONCERT_ADMIN_PASSWORD   password for the Concert 'admin' user
# Optional:
#   CLUSTER (concert-demo)  REGION (us-east-1)  WATSONX_API_URL (https://eu-gb.ml.cloud.ibm.com)
#   CONCERT_VERSION (v3.1.0)  PARAMS_FILE (../params.ini)
#
# Usage (survives a brief CloudShell disconnect):
#   nohup ./01-install-concert.sh > ~/concert-install.log 2>&1 &
#   tail -f ~/concert-install.log
set -euo pipefail

for v in IBM_ENTITLEMENT_KEY WATSONX_API_KEY WATSONX_API_PROJECT_ID CONCERT_ADMIN_PASSWORD; do
  [[ -n ${!v:-} ]] || { echo "export $v first"; exit 1; }
done
CLUSTER=${CLUSTER:-concert-demo}
REGION=${REGION:-us-east-1}
WATSONX_API_URL=${WATSONX_API_URL:-https://eu-gb.ml.cloud.ibm.com}
CONCERT_VERSION=${CONCERT_VERSION:-v3.1.0}

HERE=$(cd "$(dirname "$0")" && pwd)
PARAMS_FILE=${PARAMS_FILE:-$HERE/../params.ini}
INSTALL_DIR=$HOME/ibm-concert
SUDO=""; [[ $EUID -ne 0 ]] && SUDO=sudo
log() { echo "[$(date +%H:%M:%S)] $*"; }

log "1/7 Tooling"
command -v envsubst >/dev/null || $SUDO yum install -y gettext
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
command -v kubectl >/dev/null || {
  curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl && $SUDO mv kubectl /usr/local/bin/
}

log "2/7 Cluster access"
# Inside a pod, kubectl and helm use the pod's service account instead of a kubeconfig
[[ -n ${KUBERNETES_SERVICE_HOST:-} ]] || aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl get nodes -o wide

log "3/7 Default storage class (Workflows PVCs have no storageClassName)"
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  SC=gp2
else
  SC=gp3
  kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
fi
for other in $(kubectl get storageclass -o name); do
  kubectl patch "$other" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null
done
kubectl patch storageclass "$SC" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get storageclass

log "4/7 Download Concert $CONCERT_VERSION"
if [[ ! -f $INSTALL_DIR/etc/build_version ]] || ! grep -q "^${CONCERT_VERSION}" "$INSTALL_DIR/etc/build_version"; then
  curl -fsSL -o "$HOME/ibm-concert-x86.tar.gz" \
    "https://github.com/IBM/Concert/releases/download/${CONCERT_VERSION}/ibm-concert-x86.tar.gz"
  tar xzf "$HOME/ibm-concert-x86.tar.gz" -C "$HOME"
fi
cat "$INSTALL_DIR/etc/build_version"; echo

log "5/7 Workflows external load balancer (3.1 installs Workflows into ibm-concert-workflows, not concert-workflows)"
kubectl create namespace ibm-concert-workflows --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n ibm-concert-workflows -f "$INSTALL_DIR/concert-workflows/bin/aws-eks/service-cw-ext.yaml"
WF_LB=""
for _ in $(seq 1 60); do
  WF_LB=$(kubectl get svc solis-gw-ext -n ibm-concert-workflows -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n $WF_LB ]] && break
  sleep 10
done
[[ -n $WF_LB ]] || { echo "Workflows load balancer hostname not assigned after 10 minutes"; exit 1; }
log "Workflows LB: $WF_LB"

log "6/7 params.ini"
sed -e "s|__STORAGE_CLASS__|$SC|g" \
    -e "s|__WORKFLOWS_LB__|$WF_LB|" \
    -e "s|__WATSONX_API_URL__|$WATSONX_API_URL|" \
    -e "s|__WATSONX_API_PROJECT_ID__|$WATSONX_API_PROJECT_ID|" \
    "$PARAMS_FILE" > "$INSTALL_DIR/etc/params.ini"
grep -v '^\s*#' "$INSTALL_DIR/etc/params.ini" | grep -v '^\s*$'

log "7/7 Running Concert setup (15-30 min)"
export WATSONX_API_KEY
"$INSTALL_DIR/bin/setup" --license_acceptance=y --username=admin \
  --password="$CONCERT_ADMIN_PASSWORD" --registry_password="$IBM_ENTITLEMENT_KEY"

log "Setup finished. Next: ./02-post-install.sh"
