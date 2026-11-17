#!/usr/bin/env bash
# Makes what the pipeline needs in AWS: the bucket, the role the endpoint runs as,
# GitHub's OIDC provider, and the role GitHub Actions assumes.
#
#     infra/up.sh
#
# Safe to run twice. Needs the AWS CLI signed in to us-east-1, and GH_TOKEN, a
# GitHub token that can read this repository (Metadata read-only is enough).
set -euo pipefail
cd "$(dirname "$0")/.."
source release/config.sh
: "${GH_TOKEN:?needs GH_TOKEN, a GitHub token that can read your repository}"
mkdir -p scratch

# owner/name of this clone's GitHub repository, from its remote
GITHUB_REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')
read OWNER_ID REPO_ID <<< "$(curl -s -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$GITHUB_REPO" |
  python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["owner"]["id"], d["id"])')"
: "${REPO_ID:?GitHub returned no IDs. Check that GH_TOKEN can read your repository}"
PREFIX="repo:${GITHUB_REPO%/*}@${OWNER_ID}/${GITHUB_REPO#*/}@${REPO_ID}"

# The bucket the model files go into. Quick setup makes the same one.
aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null || aws s3 mb "s3://$BUCKET" --region "$AWS_REGION" >/dev/null

# The role the endpoint runs as: reads the model file, pulls AWS's container, writes logs
cat > scratch/exec-trust.json <<'JSON'
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
  "Principal": {"Service": "sagemaker.amazonaws.com"}, "Action": "sts:AssumeRole"}]}
JSON
cat > scratch/exec-policy.json <<JSON
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::${BUCKET}/hotel/*"},
  {"Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"},
  {"Effect": "Allow", "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], "Resource": "*"},
  {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "*"}]}
JSON
aws iam get-role --role-name hotel-release-exec >/dev/null 2>&1 ||
  aws iam create-role --role-name hotel-release-exec --assume-role-policy-document file://scratch/exec-trust.json >/dev/null
aws iam put-role-policy --role-name hotel-release-exec --policy-name run-endpoint --policy-document file://scratch/exec-policy.json

# GitHub's OIDC provider, once per account
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn, '/token.actions.githubusercontent.com')].Arn | [0]" --output text)
if [ "$OIDC_ARN" = None ]; then
  OIDC_ARN=$(aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com --query OpenIDConnectProviderArn --output text)
fi

# The role GitHub Actions assumes. Two kinds of job use it: the register job runs on
# main, and the deploy and rollback jobs run in the production environment.
cat > scratch/github-trust.json <<JSON
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
  "Principal": {"Federated": "$OIDC_ARN"}, "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {"StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
    "StringLike": {"token.actions.githubusercontent.com:sub": ["${PREFIX}:ref:refs/heads/main", "${PREFIX}:environment:production"]}}}]}
JSON
cat > scratch/github-policy.json <<JSON
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::${BUCKET}/hotel/releases/*"},
  {"Effect": "Allow", "Action": ["sagemaker:DescribeModelPackageGroup", "sagemaker:CreateModelPackageGroup",
     "sagemaker:CreateModelPackage", "sagemaker:DescribeModelPackage", "sagemaker:UpdateModelPackage",
     "sagemaker:ListModelPackages"], "Resource": "*"},
  {"Effect": "Allow", "Action": ["sagemaker:CreateModel", "sagemaker:DescribeModel", "sagemaker:CreateEndpointConfig",
     "sagemaker:DescribeEndpointConfig", "sagemaker:CreateEndpoint", "sagemaker:UpdateEndpoint",
     "sagemaker:DescribeEndpoint", "sagemaker:InvokeEndpoint"], "Resource": "*"},
  {"Effect": "Allow", "Action": "iam:PassRole", "Resource": "arn:aws:iam::${ACCOUNT}:role/hotel-release-exec",
   "Condition": {"StringEquals": {"iam:PassedToService": "sagemaker.amazonaws.com"}}}]}
JSON
aws iam get-role --role-name hotel-release-github >/dev/null 2>&1 ||
  aws iam create-role --role-name hotel-release-github --assume-role-policy-document file://scratch/github-trust.json >/dev/null
aws iam update-assume-role-policy --role-name hotel-release-github --policy-document file://scratch/github-trust.json
aws iam put-role-policy --role-name hotel-release-github --policy-name release-model --policy-document file://scratch/github-policy.json
echo "role for the AWS_ROLE_ARN secret: arn:aws:iam::${ACCOUNT}:role/hotel-release-github"
