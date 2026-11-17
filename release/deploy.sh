#!/usr/bin/env bash
# Approve one registered version, put it on the endpoint, and mark it Production.
# The same script rolls back: give it an older version.
#
#     release/deploy.sh VERSION
#
# REJECT_PREVIOUS=1 marks the version it replaces Rejected instead of leaving it approved.
set -euo pipefail
cd "$(dirname "$0")/.."
source release/config.sh
VERSION=${1:?usage: release/deploy.sh VERSION}
ARN=$PACKAGE_PREFIX/$VERSION
NAME=hotel-release-v$VERSION
SECONDS=0

STATUS=$(aws sagemaker describe-model-package --model-package-name "$ARN" --query ModelApprovalStatus --output text)
echo "version $VERSION is $STATUS"

# Approving is the decision. Everything below runs only for an approved version.
aws sagemaker update-model-package --model-package-arn "$ARN" --model-approval-status Approved \
  --approval-description "Released by ${GITHUB_ACTOR:-$USER}" >/dev/null

aws sagemaker describe-model --model-name "$NAME" >/dev/null 2>&1 ||
  aws sagemaker create-model --model-name "$NAME" --execution-role-arn "$EXEC_ROLE" \
    --primary-container "ModelPackageName=$ARN" >/dev/null
aws sagemaker describe-endpoint-config --endpoint-config-name "$NAME" >/dev/null 2>&1 ||
  aws sagemaker create-endpoint-config --endpoint-config-name "$NAME" \
    --production-variants "VariantName=AllTraffic,ModelName=$NAME,InstanceType=ml.m5.large,InitialInstanceCount=1" >/dev/null

if aws sagemaker describe-endpoint --endpoint-name "$ENDPOINT" >/dev/null 2>&1; then
  aws sagemaker update-endpoint --endpoint-name "$ENDPOINT" --endpoint-config-name "$NAME" >/dev/null
  echo "updating $ENDPOINT to version $VERSION"
else
  aws sagemaker create-endpoint --endpoint-name "$ENDPOINT" --endpoint-config-name "$NAME" >/dev/null
  echo "creating $ENDPOINT with version $VERSION"
fi
aws sagemaker wait endpoint-in-service --endpoint-name "$ENDPOINT"
echo "$ENDPOINT in service after ${SECONDS}s"

# The registry follows the endpoint, never the other way round
for V in $(aws sagemaker list-model-packages --model-package-group-name "$GROUP" \
    --query 'ModelPackageSummaryList[].ModelPackageVersion' --output text); do
  [ "$V" = "$VERSION" ] && continue
  if [ "$(aws sagemaker describe-model-package --model-package-name "$PACKAGE_PREFIX/$V" \
      --query ModelLifeCycle.Stage --output text)" = Production ]; then
    aws sagemaker update-model-package --model-package-arn "$PACKAGE_PREFIX/$V" \
      --model-life-cycle "Stage=Archived,StageStatus=Approved,StageDescription=Replaced by version $VERSION" >/dev/null
    if [ -n "${REJECT_PREVIOUS:-}" ]; then
      aws sagemaker update-model-package --model-package-arn "$PACKAGE_PREFIX/$V" --model-approval-status Rejected \
        --approval-description "Rolled back to version $VERSION" >/dev/null
    fi
    echo "version $V archived"
  fi
done
aws sagemaker update-model-package --model-package-arn "$ARN" \
  --model-life-cycle "Stage=Production,StageStatus=Approved,StageDescription=Serving on $ENDPOINT" >/dev/null
echo "version $VERSION is Production"
