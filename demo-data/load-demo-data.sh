#!/usr/bin/env bash
# Builds and uploads the Concert L3 demo data for juice-shop, WebGoat and wrongsecrets
# running on the EKS cluster. Runs on macOS (bash 3.2 OK) or Linux.
#
# Needs: docker (colima start), trivy, kubectl pointing at the EKS cluster, python3, aws cli.
# Optional: semgrep (SAST). Without it, the juice-shop SAST results from the OCP lab are reused.
#
# Env vars:
#   GITHUB_USER       owner of the forks (default vivek99singh)
#   CONCERT_API_KEY   Concert UI -> profile -> API key   (needed for 'upload' / 'upload-compliance')
#   CLUSTER / REGION  (concert-demo / us-east-1)
#   DEMO_ALLOWED_CIDR who may reach the demo app LBs (default: this machine's public IP /32)
#
# Usage: ./load-demo-data.sh <step>
#   deploy             deploy the 3 apps to namespace demo-apps (LBs restricted to your IP)
#   scan               Trivy image scans (+ Semgrep if installed)
#   sbom               generate ConcertDef application SBOMs (build + EKS runtime) with the toolkit
#   certs              generate the certificate inventory
#   compliance         Trivy EKS CIS benchmark of the cluster
#   upload             upload apps, scans and certificates to Concert
#   upload-sast        re-upload only the SAST results
#   upload-scans       re-upload only the Trivy image scans
#   upload-apps        re-upload only the application SBOMs
#   upload-deploy      ConcertDef 1.0.2 deploy SBOMs (environment, EKS runtime, access points)
#   upload-compliance  upload the CIS results as compliance-posture (format check on 3.1 pending)
#   all                deploy scan sbom certs upload
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$HERE/work
GITHUB_USER=${GITHUB_USER:-vivek99singh}
CLUSTER=${CLUSTER:-concert-demo}
REGION=${REGION:-us-east-1}
ENV_NAME=production-eks
TOOLKIT_IMAGE=${TOOLKIT_IMAGE:-icr.io/cpopen/ibm-concert-toolkit:v3.1.0}   # must match the Concert server: latest writes ConcertDef 2.0.0 that 3.1.0 rejects (CNCRTRCOVAL10187E)
APPS="juice-shop webgoat wrongsecrets"
OCP_SAST=$HERE/../../ocp/dataingestion/juice-shop-sast-scan.json
mkdir -p "$WORK"; chmod 777 "$WORK"
log() { echo "[$(date +%H:%M:%S)] $*"; }

# name|display name|image|repo|branch|criticality|data sensitivity|description
app_info() {
  case $1 in
    juice-shop)   echo "juice-shop|Juice Shop|bkimminich/juice-shop:latest|juice-shop|master|5|4|Customer-facing e-commerce storefront (OWASP Juice Shop)";;
    webgoat)      echo "webgoat|WebGoat|webgoat/webgoat:latest|WebGoat|main|3|3|Internal Java training portal (OWASP WebGoat)";;
    wrongsecrets) echo "wrongsecrets|WrongSecrets|jeroenwillemsen/wrongsecrets:latest-no-vault|wrongsecrets|master|4|5|Secrets-handling service (OWASP WrongSecrets)";;
  esac
}
field() { echo "$1" | cut -d'|' -f"$2"; }
toolkit() { docker run --rm -v "$WORK":/toolkit-data "$TOOLKIT_IMAGE" /bin/bash -c "$1"; }
lb_host() { kubectl get svc "$1" -n demo-apps -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; }
concert_host() { kubectl get svc -n concert-ingress-nginx concert-ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; }

step_deploy() {
  # DEMO_ALLOWED_CIDR overrides the caller's IP (needed in CI, where the runner's IP is not yours)
  local cidr=${DEMO_ALLOWED_CIDR:-}
  [[ -n $cidr ]] || cidr="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')/32"
  log "Deploying demo apps, reachable only from $cidr"
  sed "s|__MY_CIDR__|$cidr|g" "$HERE/demo-apps.yaml" | kubectl apply -f -
  kubectl rollout status -n demo-apps deploy/juice-shop deploy/webgoat deploy/wrongsecrets --timeout=10m
  for a in $APPS; do echo "  $a: http://$(lb_host "$a")"; done
}

step_scan() {
  for a in $APPS; do
    local info img; info=$(app_info "$a"); img=$(field "$info" 3)
    log "Trivy image scan: $img"
    trivy image --scanners vuln --format cyclonedx --output "$WORK/$a-image-scan.json" "$img"
    # Concert 3.0 accepted CycloneDX 1.4-1.6 only; newer Trivy emits 1.7.
    python3 -I - "$WORK/$a-image-scan.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
if float(d.get("specVersion", "1.6")) > 1.6:
    d["specVersion"] = "1.6"; json.dump(d, open(p, "w"))
print("  vulnerabilities:", len(d.get("vulnerabilities", [])))
EOF
    if command -v semgrep >/dev/null; then
      local repo; repo=$(field "$info" 4)
      [[ -d $WORK/src/$a ]] || git clone --depth 1 "https://github.com/$GITHUB_USER/$repo" "$WORK/src/$a"
      log "Semgrep SAST: $a"
      semgrep scan --config auto --sarif --quiet --output "$WORK/$a-sast-scan.json" "$WORK/src/$a" || true
    elif [[ $a == juice-shop && -f $OCP_SAST ]]; then
      cp "$OCP_SAST" "$WORK/$a-sast-scan.json"
    fi
  done
}

# Concert 3.1.0's validator (validate_concertdef_sbom) rejects what the toolkit writes for ConcertDef 2.0.0:
# criticality/data-sensitivity must be numbers, business.units and environments fail to parse (CNCRTRCOVAL10187E).
# The runtime SBOM (runtime-components) is rejected too, so only the build SBOM is uploaded.
fix_sbom() {
  python3 - "$1" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for k in ("criticality", "data-sensitivity"):
    if k in d: d[k] = int(d[k])
if "business" in d: d["business"] = {"name": d["business"]["name"]}
d.pop("environments", None)
json.dump(d, open(p, "w"), indent=2)
PY
}

step_sbom() {
  local api_server; api_server=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query cluster.endpoint --output text)
  for a in $APPS; do
    local info name img repo branch crit sens desc host digest
    info=$(app_info "$a")
    name=$(field "$info" 2); img=$(field "$info" 3); repo=$(field "$info" 4); branch=$(field "$info" 5)
    crit=$(field "$info" 6); sens=$(field "$info" 7); desc=$(field "$info" 8)
    host=$(lb_host "$a")
    digest=$(kubectl get pod -n demo-apps -l app="$a" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' | sed 's/.*@//')
    log "App SBOM configs: $name"
    # ConcertDef 2.0.0: 'components' and 'runtime' are mutually exclusive, hence two files.
    cat > "$WORK/$a-app-build.yaml" <<EOF
spec_version: "2.0.0"
concert:
  application:
    output_file: "$a-app-build-sbom.json"
    app_name: "$name"
    description: "$desc"
    version: "1.0.0"
    business:
      name: "Demo Corp"
      units:
      - name: "Digital"
        email: "app-owner@example.com"
    app_impact:
      criticality: "$crit"
      data_sensitivity: "$sens"
    tags: ["demo", "eks"]
    components:
    - component_name: "$a"
      repositories:
      - name: "$repo"
        url: "https://github.com/$GITHUB_USER/$repo"
        branch: "$branch"
      images:
      - name: "${img%%:*}"
        depends_on: ["$a"]
    environment_targets:
    - name: "$ENV_NAME"
      access_points:
      - name: "$a-web"
        base_url: "http://$host"
        port: 80
      properties:
        platform_type: "eks"
        deployment_purpose: "production"
    services:
    - name: "$a-web"
      type: "app_end_point"
      network_exposure: "public"
      endpoints: ["/"]
      reliant_by: ["$a"]
EOF
    cat > "$WORK/$a-app-runtime.yaml" <<EOF
spec_version: "2.0.0"
concert:
  application:
    output_file: "$a-app-runtime-sbom.json"
    app_name: "$name"
    description: "$desc"
    version: "1.0.0"
    business:
      name: "Demo Corp"
      units:
      - name: "Digital"
        email: "app-owner@example.com"
    app_impact:
      criticality: "$crit"
      data_sensitivity: "$sens"
    tags: ["demo", "eks"]
    environment_targets:
    - name: "$ENV_NAME"
      access_points:
      - name: "$a-web"
        base_url: "http://$host"
        port: 80
      depends_on: ["$CLUSTER"]
      properties:
        platform_type: "eks"
        deployment_purpose: "production"
    services:
    - name: "$a-web"
      type: "app_end_point"
      network_exposure: "public"
      endpoints: ["/"]
    runtime:
    - name: "$CLUSTER"
      type: "kubernetes"
      depends_on: ["$a-web"]
      properties:
        platform: "eks"
        cluster_platform: "aws"
        cluster_region: "$REGION"
        cluster_name: "$CLUSTER"
      api-server: "$api_server"
      namespaces:
      - name: "demo-apps"
        labels: ["app:$a"]
        images:
        - name: "${img%%:*}"
          tag: "${img##*:}"
          digest: "$digest"
EOF
    toolkit "app-sbom --app-config /toolkit-data/$a-app-build.yaml"
    toolkit "app-sbom --app-config /toolkit-data/$a-app-runtime.yaml"
    fix_sbom "$WORK/$a-app-build-sbom.json"
  done
}

step_certs() {
  local concert wf; concert=$(concert_host)
  wf=$(kubectl get svc -n concert-workflows solis-gw-ext -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  log "Certificate inventory (live endpoints + app TLS certs with expired / expiring dates)"
  python3 -I - "$WORK/cert-config.yaml" "$concert" "$wf" <<'EOF'
import sys, random, datetime as dt
out, concert, wf = sys.argv[1:4]
now = dt.datetime.now(dt.timezone.utc)
fmt = lambda t: t.strftime("%Y-%m-%d %H:%M:%S +0000 UTC")
# (access point, app, days until expiry): one expired, two expiring soon
certs = [("juice-shop-web", "juice-shop", -12), ("webgoat-web", "webgoat", 9), ("wrongsecrets-web", "wrongsecrets", 27)]
lines = ['spec_version: "1.0.2"', "concert:", '  output_file: "certificates.json"', "  certificates:",
         f'  - server: "https://{concert}"', f'  - server: "https://{wf}"', '  - server: "https://github.com"']
for ap, app, days in certs:
    end = now + dt.timedelta(days=days); start = end - dt.timedelta(days=365)
    lines += [
        "  - properties:",
        f'      serial_number: "{random.getrandbits(128)}"',
        f"      subject: CN={app}.demo-corp.example",
        "      issuer: CN=Demo Corp Issuing CA,O=Demo Corp,C=US",
        f'      validity_start_date: "{fmt(start)}"',
        f'      validity_end_date: "{fmt(end)}"',
        "      certificate_type: pem",
        "      owner: app-owner@example.com",
        f"      dns_names: '{app}.demo-corp.example'",
        "    access_points:",
        f"    - name: {ap}",
        "      is_public: true",
        f"      url: https://{app}.demo-corp.example",
        "    environment_targets:",
        '    - name: "production-eks"',
    ]
open(out, "w").write("\n".join(lines) + "\n")
EOF
  toolkit "cert-inventory --cert-config /toolkit-data/cert-config.yaml"
}

step_compliance() {
  log "Trivy EKS CIS benchmark against $(kubectl config current-context)"
  trivy k8s --compliance eks-cis-1.4 --report all --format json --output "$WORK/eks-cis-compliance.json"
}

write_upload_config() {   # $1 = output file, $2 = input-data YAML block
  : "${CONCERT_API_KEY:?export CONCERT_API_KEY (Concert UI -> profile -> API key)}"
  cat > "$1" <<EOF
general:
  retries: 3
  timeout: 60
  verbose: true
  insecure: true
app:
  base_url: "https://$(concert_host)/concert"
  instance_id: "0000-0000-0000-0000"
  auth:
    token:
      token: "C_API_KEY $CONCERT_API_KEY"
input-data:
$2
EOF
}

step_upload() {
  local block="  application-def:"
  for a in $APPS; do
    block="$block
  - file: /toolkit-data/$a-app-build-sbom.json"
  done
  block="$block
  image-scan:"
  for a in $APPS; do
    block="$block
  - file: /toolkit-data/$a-image-scan.json
    metadata: {scanner_name: trivy}"
  done
  local sast=""
  for a in $APPS; do
    [[ -f $WORK/$a-sast-scan.json ]] || continue
    local repo; repo=$(field "$(app_info "$a")" 4)
    sast="$sast
  - file: /toolkit-data/$a-sast-scan.json
    metadata: {scanner_name: semgrep, repo_name: $repo, repo_url: \"https://github.com/$GITHUB_USER/$repo\"}"
  done
  [[ -n $sast ]] && block="$block
  static-code-scan:$sast"
  block="$block
  certificate:
  - file: /toolkit-data/certificates.json
    metadata: {env_name: $ENV_NAME}"
  write_upload_config "$WORK/upload-config.yaml" "$block"
  log "Uploading to Concert"
  toolkit "upload-concert --upload-config /toolkit-data/upload-config.yaml"
}

# Re-uploads only the application SBOMs (ConcertDef build + runtime)
step_upload_apps() {
  local block="  application-def:"
  for a in $APPS; do
    block="$block
  - file: /toolkit-data/$a-app-build-sbom.json"
  done
  write_upload_config "$WORK/upload-apps.yaml" "$block"
  log "Uploading application SBOMs to Concert"
  toolkit "upload-concert --upload-config /toolkit-data/upload-apps.yaml"
}

# ConcertDef 1.0.2 deploy SBOMs (written by make-deploy-sboms.py): environment production-eks, EKS runtime and public
# access points. Concert 3.1.0 rejects the 2.0.0 runtime/environments sections, but accepts these.
step_upload_deploy() {
  python3 "$HERE/make-deploy-sboms.py" "$WORK"
  local block="  application-def:"
  for a in $APPS; do block="$block
  - file: /toolkit-data/$a-deploy-sbom.json"; done
  write_upload_config "$WORK/upload-deploy.yaml" "$block"
  log "Uploading deploy SBOMs to Concert"
  toolkit "upload-concert --upload-config /toolkit-data/upload-deploy.yaml"
}

# Re-uploads only the Trivy image scans (e.g. after discovery created new deployments, so findings link to them)
step_upload_scans() {
  local block="  image-scan:"
  for a in $APPS; do block="$block
  - file: /toolkit-data/$a-image-scan.json
    metadata: {scanner_name: trivy}"; done
  write_upload_config "$WORK/upload-scans.yaml" "$block"
  log "Uploading image scans to Concert"
  toolkit "upload-concert --upload-config /toolkit-data/upload-scans.yaml"
}

# Re-uploads only the SAST results (e.g. after a 413 or a MinIO hiccup during 'upload')
step_upload_sast() {
  local sast=""
  for a in $APPS; do
    [[ -f $WORK/$a-sast-scan.json ]] || continue
    local repo; repo=$(field "$(app_info "$a")" 4)
    sast="$sast
  - file: /toolkit-data/$a-sast-scan.json
    metadata: {scanner_name: semgrep, repo_name: $repo, repo_url: \"https://github.com/$GITHUB_USER/$repo\"}"
  done
  write_upload_config "$WORK/upload-sast.yaml" "  static-code-scan:$sast"
  log "Uploading SAST results to Concert"
  toolkit "upload-concert --upload-config /toolkit-data/upload-sast.yaml"
}

step_upload_compliance() {
  write_upload_config "$WORK/upload-compliance.yaml" "  compliance-posture:
  - file: /toolkit-data/eks-cis-compliance.json
    metadata: {scanner_name: trivy}"
  toolkit "upload-concert --upload-config /toolkit-data/upload-compliance.yaml"
}

case ${1:-} in
  deploy) step_deploy;; scan) step_scan;; sbom) step_sbom;; certs) step_certs;;
  compliance) step_compliance;; upload) step_upload;; upload-sast) step_upload_sast;; upload-scans) step_upload_scans;; upload-apps) step_upload_apps;; upload-deploy) step_upload_deploy;;
  upload-compliance) step_upload_compliance;;
  all) step_deploy; step_scan; step_sbom; step_certs; step_upload; step_upload_deploy;;
  *) sed -n '2,25p' "$0"; exit 1;;
esac
