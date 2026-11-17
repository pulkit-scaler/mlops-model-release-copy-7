#!/usr/bin/env bash
# Put candidate/model.tar.gz into S3 and register it as the next version of the
# model group, waiting for approval. Prints the new version number.
#
#     release/register.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source release/config.sh
SHA=${GITHUB_SHA:-$(git rev-parse HEAD)}
SOURCE=${GITHUB_SERVER_URL:+$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID}

# The group is made the first time and found every time after
aws sagemaker describe-model-package-group --model-package-group-name "$GROUP" >/dev/null 2>&1 ||
  aws sagemaker create-model-package-group --model-package-group-name "$GROUP" \
    --model-package-group-description "Predicts whether a hotel booking will be cancelled" >/dev/null

KEY=hotel/releases/$SHA/model.tar.gz
aws s3 cp candidate/model.tar.gz "s3://$BUCKET/$KEY" --only-show-errors

ARN=$(aws sagemaker create-model-package --model-package-group-name "$GROUP" \
  --model-approval-status PendingManualApproval \
  --model-package-description "Candidate from commit ${SHA:0:7}" \
  --customer-metadata-properties "git_sha=$SHA,source=${SOURCE:-local}" \
  --inference-specification "{
    \"Containers\": [{\"Image\": \"$IMAGE\", \"ModelDataUrl\": \"s3://$BUCKET/$KEY\"}],
    \"SupportedContentTypes\": [\"text/csv\"], \"SupportedResponseMIMETypes\": [\"text/csv\"]}" \
  --query ModelPackageArn --output text)
VERSION=${ARN##*/}
echo "registered $GROUP version $VERSION, status PendingManualApproval"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "version=$VERSION" >> "$GITHUB_OUTPUT"
exit 0
