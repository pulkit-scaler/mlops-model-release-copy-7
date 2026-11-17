#!/usr/bin/env bash
# Deletes everything the pipeline and infra/up.sh created in AWS.
#
#     infra/down.sh
#
# Safe to run twice. The bucket and its other contents are left alone.
set -uo pipefail
cd "$(dirname "$0")/.."
source release/config.sh

aws sagemaker delete-endpoint --endpoint-name "$ENDPOINT" 2>/dev/null &&
  aws sagemaker wait endpoint-deleted --endpoint-name "$ENDPOINT" 2>/dev/null
for n in $(aws sagemaker list-endpoint-configs --name-contains hotel-release --query 'EndpointConfigs[].EndpointConfigName' --output text); do
  aws sagemaker delete-endpoint-config --endpoint-config-name "$n"
done
for n in $(aws sagemaker list-models --name-contains hotel-release --query 'Models[].ModelName' --output text); do
  aws sagemaker delete-model --model-name "$n"
done
for v in $(aws sagemaker list-model-packages --model-package-group-name "$GROUP" --query 'ModelPackageSummaryList[].ModelPackageArn' --output text 2>/dev/null); do
  aws sagemaker delete-model-package --model-package-name "$v"
done
# The group goes only once SageMaker has finished deleting its versions, so retry for a minute
for try in $(seq 12); do
  aws sagemaker delete-model-package-group --model-package-group-name "$GROUP" 2>/dev/null && break
  aws sagemaker describe-model-package-group --model-package-group-name "$GROUP" >/dev/null 2>&1 || break
  sleep 5
done
aws s3 rm "s3://$BUCKET/hotel/releases/" --recursive --only-show-errors
for role in hotel-release-github hotel-release-exec; do
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  aws iam delete-role --role-name "$role" 2>/dev/null
done
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?ends_with(Arn, '/token.actions.githubusercontent.com')].Arn | [0]" --output text)
[ "$OIDC_ARN" != None ] && aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"
echo "endpoint, registry entries, release files and roles deleted"
