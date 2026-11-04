#!/usr/bin/env bash
# Deletes the demo cluster and everything that costs money, in the order that avoids orphaned ELBs/EBS.
# IAM roles are kept (free, and reused by 00-create-cluster.sh). Runs on macOS or Linux.
set -euo pipefail
CLUSTER=${CLUSTER:-concert-demo}
REGION=${REGION:-us-east-1}
NODEGROUP=${CLUSTER}-nodes
HERE=$(cd "$(dirname "$0")" && pwd)
export AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
log() { echo "[$(date +%H:%M:%S)] $*"; }

# CI passes CONFIRM_CLUSTER=<cluster name> instead of answering the prompt
answer=${CONFIRM_CLUSTER:-}
[[ -n $answer ]] || read -r -p "This permanently deletes cluster '$CLUSTER' in $REGION and all Concert data. Type the cluster name to confirm: " answer
[[ $answer == "$CLUSTER" ]] || { echo "Aborted."; exit 1; }

if aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
  log "1/4 Deleting LoadBalancer services so Kubernetes removes their ELBs"
  kubectl delete namespace demo-apps --ignore-not-found --wait=true --timeout=5m || true
  for ns in ibm-concert-workflows concert-workflows; do kubectl delete svc -n $ns solis-gw-ext --ignore-not-found --wait=true --timeout=5m || true; done
  helm uninstall concert-ingress-nginx -n concert-ingress-nginx --wait 2>/dev/null || true
  log "Giving the cloud controller 60s to finish deleting ELBs"
  sleep 60

  log "2/4 Deleting node groups (5-10 min)"
  for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --query nodegroups --output text); do
    aws eks delete-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" >/dev/null
  done
  for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --query nodegroups --output text); do
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" --nodegroup-name "$ng"
  done

  log "3/4 Deleting cluster (5-10 min)"
  aws eks delete-cluster --name "$CLUSTER" >/dev/null
  aws eks wait cluster-deleted --name "$CLUSTER"
else
  log "Cluster $CLUSTER not found; checking for leftovers only"
fi

log "4/4 Leftovers"
# EFS (shared storage for roja-buddy): mount targets first, then the file system and its security group
FS=$(aws efs describe-file-systems --query "FileSystems[?Name=='${CLUSTER}-efs'].FileSystemId | [0]" --output text)
if [[ $FS != None ]]; then
  for mt in $(aws efs describe-mount-targets --file-system-id "$FS" --query 'MountTargets[].MountTargetId' --output text); do
    aws efs delete-mount-target --mount-target-id "$mt"
  done
  until [[ $(aws efs describe-mount-targets --file-system-id "$FS" --query 'length(MountTargets)') == 0 ]]; do sleep 10; done
  aws efs delete-file-system --file-system-id "$FS" && log "  deleted EFS $FS"
fi
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values="${CLUSTER}-efs" --query 'SecurityGroups[0].GroupId' --output text)
[[ $SG == None ]] || { aws ec2 delete-security-group --group-id "$SG" && log "  deleted security group $SG"; }
TAG="kubernetes.io/cluster/$CLUSTER"
VOLS=$(aws ec2 describe-volumes --filters Name=status,Values=available Name=tag-key,Values="$TAG" \
  --query 'Volumes[].VolumeId' --output text)
for v in $VOLS; do log "  deleting EBS volume $v"; aws ec2 delete-volume --volume-id "$v"; done
# Volumes the EBS CSI driver created without the cluster tag: listed only, since they can't be tied to this cluster
OTHER=$(aws ec2 describe-volumes --filters Name=status,Values=available Name=tag-key,Values=ebs.csi.aws.com/cluster \
  --query 'Volumes[].VolumeId' --output text)
[[ -z $OTHER ]] || echo "  Unattached CSI volumes to review in EC2 -> Volumes: $OTHER"
for lb in $(aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text); do
  if aws elb describe-tags --load-balancer-names "$lb" --query 'TagDescriptions[].Tags[].Key' --output text | grep -qw "$TAG"; then
    echo "  WARNING: ELB $lb still exists for $CLUSTER. Delete it in EC2 -> Load Balancers."
  fi
done
rm -f "$HERE/../.run-state"
log "Teardown complete. IAM roles were kept."
