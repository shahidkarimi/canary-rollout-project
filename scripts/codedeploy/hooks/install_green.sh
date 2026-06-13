#!/usr/bin/env bash
# AfterInstall: pull the signed digest and start the target-color container.
# The active color keeps serving 100% of traffic until validate_and_shift.sh
# proves the new container healthy and performs the weighted canary.
set -euo pipefail
source "$(dirname "$0")/common.sh"

log "installing ${TARGET_COLOR} container from ${IMAGE}"

aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker pull "${IMAGE}"

# Secret consumed at container start: only a fingerprint + version id are
# exposed to the app/env, never the value (podinfo's /env would echo it).
SECRET_ARN=$(aws secretsmanager describe-secret --region "${REGION}" \
  --secret-id "/dockyard/SUPER_SECRET_TOKEN" --query ARN --output text)
SECRET_JSON=$(aws secretsmanager get-secret-value --region "${REGION}" \
  --secret-id "${SECRET_ARN}" --query '{v:SecretString,id:VersionId}' --output json)
SECRET_FP=$(echo "${SECRET_JSON}" | python3 -c 'import sys,json,hashlib;print(hashlib.sha256(json.load(sys.stdin)["v"].encode()).hexdigest()[:16])')
SECRET_VERSION=$(echo "${SECRET_JSON}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

docker rm -f "podinfo-${TARGET_COLOR}" 2>/dev/null || true
docker run -d --name "podinfo-${TARGET_COLOR}" \
  --restart unless-stopped \
  -p "${TARGET_PORT}:9898" \
  -e ENVIRONMENT="${DEPLOY_ENV}" \
  -e COLOR="${TARGET_COLOR}" \
  -e SECRET_FINGERPRINT="${SECRET_FP}" \
  -e SECRET_VERSION_ID="${SECRET_VERSION}" \
  "${IMAGE}"

docker image prune -f >/dev/null
log "container podinfo-${TARGET_COLOR} started on :${TARGET_PORT}"
