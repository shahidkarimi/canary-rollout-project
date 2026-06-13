#!/usr/bin/env bash
# Bootstrap the Terraform remote state backend (S3 + DynamoDB lock).
# Idempotent: safe to re-run; every step checks before it creates.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="canary-rollout-tfstate-${ACCOUNT_ID}-${REGION}"
LOCK_TABLE="canary-rollout-tf-lock"

echo ">> Account: ${ACCOUNT_ID}  Region: ${REGION}"
echo ">> State bucket: ${STATE_BUCKET}"
echo ">> Lock table:   ${LOCK_TABLE}"

if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  echo ">> Bucket exists, skipping create"
else
  if [[ "${REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  echo ">> Bucket created"
fi

aws s3api put-bucket-versioning --bucket "${STATE_BUCKET}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "${STATE_BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}, "BucketKeyEnabled": true}]
  }'

aws s3api put-public-access-block --bucket "${STATE_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo ">> Lock table exists, skipping create"
else
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" >/dev/null
  aws dynamodb wait table-exists --table-name "${LOCK_TABLE}" --region "${REGION}"
  echo ">> Lock table created"
fi

echo ">> Bootstrap complete"
