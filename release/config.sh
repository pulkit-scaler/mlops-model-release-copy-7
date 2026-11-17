# Names and settings every release script shares. Sourced, never run.
export AWS_REGION=${AWS_REGION:-us-east-1}
export AWS_DEFAULT_REGION=$AWS_REGION
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export GROUP=hotel-cancellations                      # the model group in the registry
export ENDPOINT=hotel-release                         # the endpoint callers use
export BUCKET=sagemaker-$AWS_REGION-$ACCOUNT          # model files go under hotel/releases/<commit>/
export EXEC_ROLE=arn:aws:iam::$ACCOUNT:role/hotel-release-exec   # the role the endpoint runs as
# AWS's own XGBoost container, the one both earlier models were trained with
export IMAGE=683313688378.dkr.ecr.$AWS_REGION.amazonaws.com/sagemaker-xgboost:1.7-1
export PACKAGE_PREFIX=arn:aws:sagemaker:$AWS_REGION:$ACCOUNT:model-package/$GROUP
