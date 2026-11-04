#!/usr/bin/env bash
# Shared (ReadWriteMany) storage for Concert 3.1.0: the roja-buddy agents service mounts RWX PVCs,
# which EBS cannot provide. Creates an EFS file system, the EFS CSI add-on and the 'efs-sc' StorageClass
# (set as FILE_STORAGE_CLASS_CONCERT in params.ini). Runs on macOS or Linux; safe to re-run.
set -euo pipefail
CLUSTER=${CLUSTER:-concert-demo}
REGION=${REGION:-us-east-1}
NODE_AZ=${NODE_AZ:-us-east-1b}
EFS_ROLE=AmazonEKS_EFS_CSI_DriverRole-concert
EFS_NAME=${CLUSTER}-efs
export AWS_DEFAULT_REGION=$REGION AWS_PAGER=""
log() { echo "[$(date +%H:%M:%S)] $*"; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

log "1/5 IAM role for the EFS CSI driver"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
aws iam get-role --role-name "$EFS_ROLE" >/dev/null 2>&1 \
  || aws iam create-role --role-name "$EFS_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws iam attach-role-policy --role-name "$EFS_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy

log "2/5 Security group allowing NFS from the VPC"
VPC=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC" --query 'Vpcs[0].CidrBlock' --output text)
SG=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" Name=group-name,Values="$EFS_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ $SG == None ]]; then
  SG=$(aws ec2 create-security-group --vpc-id "$VPC" --group-name "$EFS_NAME" \
    --description "NFS to EFS for $CLUSTER" --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 2049 --cidr "$CIDR" >/dev/null
fi
log "Security group $SG (NFS from $CIDR)"

log "3/5 EFS file system with a mount target in $NODE_AZ"
FS=$(aws efs describe-file-systems --query "FileSystems[?Name=='$EFS_NAME'].FileSystemId | [0]" --output text)
if [[ $FS == None ]]; then
  FS=$(aws efs create-file-system --encrypted --performance-mode generalPurpose --throughput-mode elastic \
    --tags Key=Name,Value="$EFS_NAME" Key=kubernetes.io/cluster/$CLUSTER,Value=owned \
    --query FileSystemId --output text)
fi
until [[ $(aws efs describe-file-systems --file-system-id "$FS" --query 'FileSystems[0].LifeCycleState' --output text) == available ]]; do sleep 5; done
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=availability-zone,Values="$NODE_AZ" \
  Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
if [[ $(aws efs describe-mount-targets --file-system-id "$FS" --query 'length(MountTargets)') == 0 ]]; then
  aws efs create-mount-target --file-system-id "$FS" --subnet-id "$SUBNET" --security-groups "$SG" >/dev/null
fi
until [[ $(aws efs describe-mount-targets --file-system-id "$FS" --query 'MountTargets[0].LifeCycleState' --output text) == available ]]; do sleep 10; done
log "EFS $FS available in $NODE_AZ"

log "4/5 EFS CSI driver add-on"
if ! aws eks describe-addon --cluster-name "$CLUSTER" --addon-name aws-efs-csi-driver >/dev/null 2>&1; then
  aws eks create-addon --cluster-name "$CLUSTER" --addon-name aws-efs-csi-driver --resolve-conflicts OVERWRITE \
    --pod-identity-associations "serviceAccount=efs-csi-controller-sa,roleArn=arn:aws:iam::$ACCOUNT:role/$EFS_ROLE" >/dev/null
fi
until [[ $(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name aws-efs-csi-driver --query addon.status --output text) == ACTIVE ]]; do sleep 10; done
log "aws-efs-csi-driver ACTIVE"

log "5/5 StorageClass efs-sc (one EFS access point per PVC)"
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: $FS
  directoryPerms: "777"
  basePath: /concert
EOF
log "Shared storage ready: StorageClass efs-sc -> $FS"
