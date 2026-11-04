#!/usr/bin/env bash
# Creates the EKS cluster for Concert 3.1.0 with the AWS CLI. This automates sections 2-6 of the 3.0.0 guide.
# Runs on macOS (bash 3.2) or Linux. Safe to re-run: anything that already exists is reused.
#
# Optional env vars:
#   CLUSTER (concert-demo)  REGION (us-east-1)  K8S_VERSION (EKS default in standard support)
#   NODE_TYPES (seven 16 vCPU / 32+ GB types, see below)  NODE_COUNT (2)  NODE_DISK_GB (512)
#   CAPACITY_TYPE (SPOT | ON_DEMAND)  NODE_AZ (us-east-1b)
#   EXTRA_ADMIN_ARNS  space-separated IAM user/role ARNs given cluster-admin, besides the creator
#                     (set this when the pipeline creates the cluster, so you can still use kubectl)
set -euo pipefail
CLUSTER=${CLUSTER:-concert-demo}
REGION=${REGION:-us-east-1}
NODEGROUP=${CLUSTER}-nodes
# Several Spot pools that all meet IBM's 16 vCPU / 32 GB minimum, so a reclaim can be replaced quickly
NODE_TYPES=${NODE_TYPES:-c5.4xlarge m6i.4xlarge m5.4xlarge c7i.4xlarge c6a.4xlarge m6a.4xlarge c5a.4xlarge}
NODE_COUNT=${NODE_COUNT:-3}   # 3.1 Hub+Concert+DataApps+Workflows requests ~34 vCPU; 2 nodes give ~31.5
NODE_DISK_GB=${NODE_DISK_GB:-512}
CAPACITY_TYPE=${CAPACITY_TYPE:-SPOT}
# Nodes stay in one AZ: Concert's EBS volumes are zonal, so a replacement Spot node in another AZ
# could not mount them. The control plane still uses every supported AZ.
NODE_AZ=${NODE_AZ:-us-east-1b}
CLUSTER_ROLE=AmazonEKSClusterRole-concert
NODE_ROLE=AmazonEKSNodeRole-concert
EBS_ROLE=AmazonEKS_EBS_CSI_DriverRole-concert
# AZs where EKS cannot place a control plane (us-east-1e is use1-az3)
UNSUPPORTED_AZ_IDS="use1-az3 usw1-az2 cac1-az3"
export AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
log() { echo "[$(date +%H:%M:%S)] $*"; }

# poll <description> <max minutes> <command...>: retries every 20s until the command succeeds
poll() {
  local what=$1 max=$2 i; shift 2
  for ((i = 0; i < max * 3; i++)); do
    "$@" && return 0
    sleep 20
  done
  echo "Timed out after $max min waiting for $what"; exit 1
}

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
log "Account $ACCOUNT, region $REGION, cluster $CLUSTER"

# ensure_role <name> <service principal> <trust actions JSON> <policy ARN>...
ensure_role() {
  local name=$1 service=$2 actions=$3 trust; shift 3
  trust="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"$service\"},\"Action\":$actions}]}"
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$name" --policy-document "$trust"
  else
    aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" >/dev/null
  fi
  for p in "$@"; do aws iam attach-role-policy --role-name "$name" --policy-arn "$p"; done
  log "IAM role ready: $name"
}

log "1/6 IAM roles"
ensure_role "$CLUSTER_ROLE" eks.amazonaws.com '["sts:AssumeRole","sts:TagSession"]' \
  arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
ensure_role "$NODE_ROLE" ec2.amazonaws.com '"sts:AssumeRole"' \
  arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
  arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
ensure_role "$EBS_ROLE" pods.eks.amazonaws.com '["sts:AssumeRole","sts:TagSession"]' \
  arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2

log "2/6 Subnets (default VPC, skipping AZs EKS does not support)"
SUBNETS="" NODE_SUBNET=""
while read -r id az az_id; do
  case " $UNSUPPORTED_AZ_IDS " in *" $az_id "*) continue;; esac
  SUBNETS="$SUBNETS $id"
  [[ $az == "$NODE_AZ" ]] && NODE_SUBNET=$id
done < <(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
           --query 'Subnets[].[SubnetId,AvailabilityZone,AvailabilityZoneId]' --output text)
[[ -n $NODE_SUBNET ]] || { echo "No default subnet in $NODE_AZ"; exit 1; }
SUBNETS=$(echo $SUBNETS)
[[ -n $SUBNETS ]] || { echo "No default-VPC subnets found in $REGION"; exit 1; }
SUBNETS_JSON="[\"$(echo "$SUBNETS" | sed 's/ /","/g')\"]"
log "Control plane subnets: $SUBNETS; node subnet: $NODE_SUBNET ($NODE_AZ)"

log "3/6 EKS control plane (10-15 min)"
if ! aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  K8S_VERSION=${K8S_VERSION:-$(aws eks describe-cluster-versions \
    --query 'clusterVersions[?defaultVersion==`true`].clusterVersion | [0]' --output text)}
  log "Creating Kubernetes $K8S_VERSION cluster"
  aws eks create-cluster --name "$CLUSTER" --kubernetes-version "$K8S_VERSION" \
    --role-arn "arn:aws:iam::$ACCOUNT:role/$CLUSTER_ROLE" \
    --resources-vpc-config "{\"subnetIds\":$SUBNETS_JSON,\"endpointPublicAccess\":true,\"endpointPrivateAccess\":true}" \
    --access-config authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true \
    --upgrade-policy supportType=STANDARD >/dev/null
fi
cluster_active() { [[ $(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text) == ACTIVE ]]; }
poll "cluster $CLUSTER" 30 cluster_active
log "Cluster ACTIVE"

for arn in ${EXTRA_ADMIN_ARNS:-}; do
  aws eks create-access-entry --cluster-name "$CLUSTER" --principal-arn "$arn" >/dev/null 2>&1 || true
  aws eks associate-access-policy --cluster-name "$CLUSTER" --principal-arn "$arn" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
    --access-scope type=cluster >/dev/null
  log "Cluster-admin access entry: $arn"
done

log "4/6 Add-ons"
# ensure_addon <name> [extra create-addon args...]
ensure_addon() {
  local name=$1; shift
  if aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$name" >/dev/null 2>&1; then
    log "  $name already installed"
  else
    aws eks create-addon --cluster-name "$CLUSTER" --addon-name "$name" --resolve-conflicts OVERWRITE "$@" >/dev/null
    log "  $name requested"
  fi
}
ensure_addon vpc-cni
ensure_addon kube-proxy
ensure_addon coredns
ensure_addon eks-pod-identity-agent
ensure_addon aws-ebs-csi-driver \
  --pod-identity-associations "serviceAccount=ebs-csi-controller-sa,roleArn=arn:aws:iam::$ACCOUNT:role/$EBS_ROLE"
ensure_addon metrics-server

log "5/6 Node group: $NODE_COUNT x $CAPACITY_TYPE in $NODE_AZ, ${NODE_DISK_GB} GiB disk, types: $NODE_TYPES (5-10 min)"
if ! aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" >/dev/null 2>&1; then
  aws eks create-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --node-role "arn:aws:iam::$ACCOUNT:role/$NODE_ROLE" --subnets "$NODE_SUBNET" \
    --instance-types $NODE_TYPES --capacity-type "$CAPACITY_TYPE" --ami-type AL2023_x86_64_STANDARD \
    --disk-size "$NODE_DISK_GB" \
    --scaling-config "minSize=$NODE_COUNT,maxSize=$NODE_COUNT,desiredSize=$NODE_COUNT" >/dev/null
fi
nodegroup_active() {
  local s; s=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
    --query nodegroup.status --output text)
  [[ $s == CREATE_FAILED || $s == DEGRADED ]] && {
    aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" --query nodegroup.health
    echo "Node group is $s"; exit 1; }
  [[ $s == ACTIVE ]]
}
poll "node group $NODEGROUP" 25 nodegroup_active
log "Node group ACTIVE"

log "6/6 kubectl access and add-on health"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl get nodes -o wide
addons_active() {
  local bad; bad=$(for a in $(aws eks list-addons --cluster-name "$CLUSTER" --query addons --output text); do
    aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" --query 'addon.[addonName,status]' --output text
  done | grep -v ACTIVE || true)
  [[ -z $bad ]] || { echo "  waiting on: $(echo $bad)"; return 1; }
}
poll "add-ons" 15 addons_active
log "Cluster $CLUSTER is ready"

# Concert 3.1 also needs ReadWriteMany storage (EFS) for its roja-buddy agents service
"$(cd "$(dirname "$0")" && pwd)/00b-create-efs.sh"
