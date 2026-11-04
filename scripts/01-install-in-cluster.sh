#!/usr/bin/env bash
# Runs 01-install-concert.sh inside the EKS cluster as a Kubernetes Job (Amazon Linux 2023, x86_64), so
# CloudShell is not needed. The install keeps running if this Mac sleeps or disconnects; re-running this
# script while the Job is still running just re-attaches to its logs.
#
# Needs: kubectl pointing at the cluster, and the env vars required by 01-install-concert.sh.
set -euo pipefail
: "${IBM_ENTITLEMENT_KEY:?}" "${WATSONX_API_KEY:?}" "${WATSONX_API_PROJECT_ID:?}" "${CONCERT_ADMIN_PASSWORD:?}"
CLUSTER=${CLUSTER:-concert-demo}
REGION=${REGION:-us-east-1}
WATSONX_API_URL=${WATSONX_API_URL:-https://eu-gb.ml.cloud.ibm.com}
CONCERT_VERSION=${CONCERT_VERSION:-v3.1.0}
NS=concert-installer
JOB=concert-install
HERE=$(cd "$(dirname "$0")" && pwd)
LOG_DIR=$HERE/../logs
mkdir -p "$LOG_DIR"
log() { echo "[$(date +%H:%M:%S)] $*"; }
job_field() { kubectl get job "$JOB" -n "$NS" -o jsonpath="{.status.$1}" 2>/dev/null || true; }

if [[ $(job_field active) == 1 ]]; then
  log "Install Job is already running; re-attaching to its logs"
else
  log "Creating installer namespace, service account, secret and Job"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create serviceaccount installer -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
  # The Concert installer creates namespaces, CRDs and cluster roles, so it needs cluster-admin.
  # This binding is removed again once the install succeeds.
  kubectl create clusterrolebinding concert-installer --clusterrole=cluster-admin \
    --serviceaccount="$NS:installer" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic install-secrets -n "$NS" \
    --from-literal=IBM_ENTITLEMENT_KEY="$IBM_ENTITLEMENT_KEY" \
    --from-literal=WATSONX_API_KEY="$WATSONX_API_KEY" \
    --from-literal=CONCERT_ADMIN_PASSWORD="$CONCERT_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create configmap install-files -n "$NS" \
    --from-file="$HERE/01-install-concert.sh" --from-file="$HERE/../params.ini" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl delete job "$JOB" -n "$NS" --ignore-not-found --wait
  # A Spot rebalance drains nodes; without this the drain evicts the installer mid-setup.
  # EKS managed node groups honour a PDB for up to 15 minutes before forcing the drain.
  kubectl apply -f - <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: $JOB
  namespace: $NS
spec:
  minAvailable: 1
  selector:
    matchLabels:
      job-name: $JOB
EOF
  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 7200
  template:
    spec:
      serviceAccountName: installer
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/arch: amd64
      containers:
      - name: install
        image: public.ecr.aws/amazonlinux/amazonlinux:2023
        command: ["bash", "-c"]
        args:
        - |
          set -e
          echo "Installing tools..."
          dnf install -y -q tar gzip gettext iputils python3 findutils which procps-ng hostname openssl jq git >/dev/null
          bash /work/01-install-concert.sh
        env:
        - {name: PARAMS_FILE, value: /work/params.ini}
        - {name: CLUSTER, value: "$CLUSTER"}
        - {name: REGION, value: "$REGION"}
        - {name: WATSONX_API_URL, value: "$WATSONX_API_URL"}
        - {name: WATSONX_API_PROJECT_ID, value: "$WATSONX_API_PROJECT_ID"}
        - {name: CONCERT_VERSION, value: "$CONCERT_VERSION"}
        envFrom:
        - secretRef: {name: install-secrets}
        resources:
          requests: {cpu: 500m, memory: 1Gi}
        volumeMounts:
        - {name: files, mountPath: /work}
      volumes:
      - name: files
        configMap: {name: install-files}
EOF
fi

log "Waiting for the installer pod to start"
for _ in $(seq 1 60); do
  phase=$(kubectl get pods -n "$NS" -l job-name="$JOB" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  [[ -n $phase && $phase != Pending ]] && break
  sleep 5
done

log "Streaming installer logs (Ctrl-C only stops the stream, not the install)"
while :; do
  kubectl logs -f "job/$JOB" -n "$NS" || true
  [[ $(job_field succeeded) == 1 || $(job_field failed) == 1 ]] && break
  log "Log stream dropped; reconnecting (earlier lines will repeat)"
  sleep 10
done
kubectl logs "job/$JOB" -n "$NS" > "$LOG_DIR/concert-install.log" 2>&1 || true
log "Full log saved to logs/concert-install.log"

if [[ $(job_field succeeded) == 1 ]]; then
  kubectl delete clusterrolebinding concert-installer --ignore-not-found
  kubectl delete namespace "$NS" --ignore-not-found --wait=false
  log "Concert install succeeded; installer Job, secret and cluster-admin binding removed"
else
  log "Concert install FAILED. The Job is kept for debugging:"
  echo "  kubectl logs job/$JOB -n $NS | tail -100"
  echo "  kubectl get pods -A | grep -Ev 'Running|Completed'"
  echo "Fix the cause and re-run; the Job is recreated and setup picks up where it can."
  exit 1
fi
