#!/bin/bash

export CLUSTER_NAME="demo"
export K8S_VERSION="1.29"
export AWS_DEFAULT_REGION="ap-northeast-1"
export SVC_CIDR="172.16.0.0/16"
export CLUSTER_ADMIN="arn:aws:iam::625011733915:user/xiangyan"
export NODEGROUP="mng"
export VPC_ID="vpc-0674cdd7208595513"
export SG_ID="sg-052a3527c71965185"
export AZ1="ap-northeast-1a"
export AZ2="ap-northeast-1c"
export AZ3="ap-northeast-1d"
export PUB_SUBNET_1="subnet-0a30581b2acf81011"
export PUB_SUBNET_2="subnet-017030151e2b304fb"
export PUB_SUBNET_3="subnet-03041ef41a19c302e"
export PRI_SUBNET_1="subnet-0076276ba39b907d2"
export PRI_SUBNET_2="subnet-068c41b2b15cd3dd4"
export PRI_SUBNET_2="subnet-0e3fbb88bc117ef90"
export SSH_KEY_NAME="defaultJPPEM"
export 2ND_SUBNET_1="subnet-06bf10b5c39640425"
export 2ND_SUBNET_2="subnet-0dea05381446970e8"
export 2ND_SUBNET_3="subnet-04af8848b98f4a439"

envsubst < all-in-one-template.yaml > all-in-one.yaml

eksctl create cluster -f all-in-one.yaml

eksctl utils write-kubeconfig --cluster "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}"

################################################################################

# Optional: Deploy custom network config

cat >custom-network-config.yaml <<EOF
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: ${AZ1}
spec:
  subnet: ${2ND_SUBNET_1}
---
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: ${AZ2}
spec:
  subnet: ${2ND_SUBNET_2}
---
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata: 
  name: ${AZ3}
spec:
  subnet: ${2ND_SUBNET_3}
EOF

kubectl apply -f custom-network-config.yaml

################################################################################

# Scale up node group

eksctl scale nodegroup --name mng --nodes 3 --cluster "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}"

# Install AWS Load Balancer Controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks

# Check the latest version applicable to your cluster
helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --version 1.7.1 \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait

# Create EBS storage class
cat >ebs-storage-class.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-sc
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
EOF

kubectl apply -f ebs-storage-class.yaml

# Create EFS storage class
cat >efs-storage-class.yaml <<EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-079895de91c8346ae
  directoryPerms: "700"
  gidRangeStart: "1000" # optional
  gidRangeEnd: "2000" # optional
  basePath: "/dynamic_provisioning" # optional
  subPathPattern: "\${.PVC.namespace}/\${.PVC.name}" # optional
  ensureUniqueDirectory: "true" # optional
  reuseAccessPoint: "false" # optional
EOF

kubectl apply -f efs-storage-class.yaml

# Install Karpenter
export KARPENTER_NAMESPACE="karpenter"
export KARPENTER_VERSION="0.35.2"
export AWS_PARTITION="aws" # if you are not using standard partitions, you may need to configure to aws-cn / aws-us-gov
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export TEMPOUT="$(mktemp)"

curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v"${KARPENTER_VERSION}"/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml  > "${TEMPOUT}" \
&& aws cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "${TEMPOUT}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"

eksctl create podidentityassociation \
  --cluster ${CLUSTER_NAME} \
  --namespace "${KARPENTER_NAMESPACE}" \
  --service-account-name karpenter \
  --role-name ${CLUSTER_NAME}-karpenter \
  --permission-policy-arns="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}"
  
eksctl create accessentry --cluster ${CLUSTER_NAME} \
  --principal-arn "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}" \
  --type EC2_LINUX
  
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
# If the role has already been successfully created, you will see:
# An error occurred (InvalidInput) when calling the CreateServiceLinkedRole operation: Service role name AWSServiceRoleForEC2Spot has been taken in this account, please try a different suffix.

# Logout of helm registry to perform an unauthenticated pull against the public ECR
helm registry logout public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version "${KARPENTER_VERSION}" --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=${CLUSTER_NAME}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait

# Install cert-manager
# Please check version compatibility in below web page
# https://cert-manager.io/docs/releases/
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

# Install ADOT prometheus scraper