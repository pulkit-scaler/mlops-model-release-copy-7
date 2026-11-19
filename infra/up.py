"""Makes what the pipeline needs in AWS: the bucket, the role the endpoint runs as,
the two alarms that guard a release, GitHub's OIDC provider, and the role GitHub
Actions assumes.

    GH_TOKEN=$(gh auth token) python infra/up.py

Safe to run twice. Needs AWS credentials for us-east-1, and GH_TOKEN, a GitHub token
that can read this repository.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "release"))
from config import ACCOUNT, BUCKET, ENDPOINT, REGION, session  # noqa: E402

iam = session.client("iam")
s3 = session.client("s3")
cloudwatch = session.client("cloudwatch")
token = os.environ.get("GH_TOKEN") or sys.exit("needs GH_TOKEN, a GitHub token that can read your repository")

# owner/name of this clone's GitHub repository, from its remote, and its numeric IDs
remote = subprocess.run(["git", "remote", "get-url", "origin"], cwd=ROOT,
                        capture_output=True, text=True, check=True).stdout.strip()
github_repo = re.sub(r"^.*[:/]([^/:]+/[^/]+?)(\.git)?$", r"\1", remote)
request = urllib.request.Request(f"https://api.github.com/repos/{github_repo}",
                                 headers={"Authorization": f"Bearer {token}"})
repo = json.load(urllib.request.urlopen(request))
owner, name = github_repo.split("/")
prefix = f"repo:{owner}@{repo['owner']['id']}/{name}@{repo['id']}"

# The bucket the model files go into. Quick setup makes the same one.
try:
    s3.head_bucket(Bucket=BUCKET)
except s3.exceptions.ClientError:
    if REGION == "us-east-1":
        s3.create_bucket(Bucket=BUCKET)
    else:
        s3.create_bucket(Bucket=BUCKET, CreateBucketConfiguration={"LocationConstraint": REGION})


def role(role_name, trust, policy_name, policy):
    """Make the role if it is missing, and set its trust and its one inline policy either way."""
    try:
        iam.get_role(RoleName=role_name)
        iam.update_assume_role_policy(RoleName=role_name, PolicyDocument=json.dumps(trust))
    except iam.exceptions.NoSuchEntityException:
        iam.create_role(RoleName=role_name, AssumeRolePolicyDocument=json.dumps(trust))
    iam.put_role_policy(RoleName=role_name, PolicyName=policy_name, PolicyDocument=json.dumps(policy))


def allow(actions, resource="*", **condition):
    statement = {"Effect": "Allow", "Action": actions, "Resource": resource}
    if condition:
        statement["Condition"] = condition
    return statement


# The role the endpoint runs as: reads the model file, pulls AWS's container, writes logs,
# and reads the alarms during a release. DescribeAlarms has to be on "*". Narrowed to the
# alarms' own names, SageMaker cannot read them and rolls every release back.
role("hotel-release-exec",
     {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": "sts:AssumeRole",
                                              "Principal": {"Service": "sagemaker.amazonaws.com"}}]},
     "run-endpoint",
     {"Version": "2012-10-17", "Statement": [
         allow("s3:GetObject", f"arn:aws:s3:::{BUCKET}/hotel/*"),
         allow(["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]),
         allow(["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]),
         allow("cloudwatch:DescribeAlarms")]})

# The two alarms a release is watched by. Any server error from the endpoint in a
# minute, or an average model time over half a second in two minutes running.
dimensions = [{"Name": "EndpointName", "Value": ENDPOINT}, {"Name": "VariantName", "Value": "AllTraffic"}]
cloudwatch.put_metric_alarm(
    AlarmName="hotel-release-errors", Namespace="AWS/SageMaker", MetricName="Invocation5XXErrors",
    Dimensions=dimensions, Statistic="Sum", Period=60, EvaluationPeriods=1, Threshold=1,
    ComparisonOperator="GreaterThanOrEqualToThreshold", TreatMissingData="notBreaching")
cloudwatch.put_metric_alarm(
    AlarmName="hotel-release-latency", Namespace="AWS/SageMaker", MetricName="ModelLatency",
    Dimensions=dimensions, Statistic="Average", Period=60, EvaluationPeriods=2, Threshold=500000,
    ComparisonOperator="GreaterThanThreshold", TreatMissingData="notBreaching")

# GitHub's OIDC provider, once per account
providers = [p["Arn"] for p in iam.list_open_id_connect_providers()["OpenIDConnectProviderList"]
             if p["Arn"].endswith("/token.actions.githubusercontent.com")]
oidc_arn = providers[0] if providers else iam.create_open_id_connect_provider(
    Url="https://token.actions.githubusercontent.com", ClientIDList=["sts.amazonaws.com"])["OpenIDConnectProviderArn"]

# The role GitHub Actions assumes. Two kinds of job use it: the register job runs on
# main, and the deploy and rollback jobs run in the production environment.
role("hotel-release-github",
     {"Version": "2012-10-17", "Statement": [{
         "Effect": "Allow", "Principal": {"Federated": oidc_arn}, "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {"StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
                       "StringLike": {"token.actions.githubusercontent.com:sub": [
                           f"{prefix}:ref:refs/heads/main", f"{prefix}:environment:production"]}}}]},
     "release-model",
     {"Version": "2012-10-17", "Statement": [
         allow(["s3:PutObject", "s3:GetObject"], f"arn:aws:s3:::{BUCKET}/hotel/releases/*"),
         allow(["sagemaker:DescribeModelPackageGroup", "sagemaker:CreateModelPackageGroup",
                "sagemaker:CreateModelPackage", "sagemaker:DescribeModelPackage",
                "sagemaker:UpdateModelPackage", "sagemaker:ListModelPackages"]),
         allow(["sagemaker:CreateModel", "sagemaker:DescribeModel", "sagemaker:CreateEndpointConfig",
                "sagemaker:DescribeEndpointConfig", "sagemaker:CreateEndpoint", "sagemaker:UpdateEndpoint",
                "sagemaker:DescribeEndpoint", "sagemaker:InvokeEndpoint"]),
         allow("iam:PassRole", f"arn:aws:iam::{ACCOUNT}:role/hotel-release-exec",
               StringEquals={"iam:PassedToService": "sagemaker.amazonaws.com"})]})
print(f"role for the AWS_ROLE_ARN secret: arn:aws:iam::{ACCOUNT}:role/hotel-release-github")
