#!/usr/bin/env bash
# Shared context for CodeDeploy hooks. Sourced, not executed.
set -euo pipefail

BUNDLE_DIR=/opt/canary/deploy
PROJECT=canary

DEPLOY_ENV="$(cat "${BUNDLE_DIR}/deploy-env.txt")"
IMAGE_DIGEST="$(cat "${BUNDLE_DIR}/image-digest.txt")"

TOKEN=$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
imds() { curl -sS -H "X-aws-ec2-metadata-token: ${TOKEN}" "http://169.254.169.254/latest/meta-data/$1"; }

REGION="$(imds placement/region)"
INSTANCE_ID="$(imds instance-id)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${ECR_REGISTRY}/${PROJECT}/podinfo@${IMAGE_DIGEST}"

NAME="${PROJECT}-${DEPLOY_ENV}"
BLUE_PORT=9898
GREEN_PORT=9899

PARAM_COLOR="/${PROJECT}/${DEPLOY_ENV}/ec2/active-color"
PARAM_IMAGE="/${PROJECT}/${DEPLOY_ENV}/ec2/active-image"

get_param() { aws ssm get-parameter --region "${REGION}" --name "$1" --query Parameter.Value --output text 2>/dev/null || echo none; }
put_param() { aws ssm put-parameter --region "${REGION}" --name "$1" --value "$2" --type String --overwrite >/dev/null; }

ACTIVE_COLOR="$(get_param "${PARAM_COLOR}")"
case "${ACTIVE_COLOR}" in
  blue)  TARGET_COLOR=green; TARGET_PORT=${GREEN_PORT}; ACTIVE_PORT=${BLUE_PORT} ;;
  green) TARGET_COLOR=blue;  TARGET_PORT=${BLUE_PORT};  ACTIVE_PORT=${GREEN_PORT} ;;
  *)     TARGET_COLOR=blue;  TARGET_PORT=${BLUE_PORT};  ACTIVE_PORT="" ;; # first ever deploy
esac

log() { echo "[canary-deploy][${DEPLOY_ENV}][${INSTANCE_ID}] $*"; }
