#!/usr/bin/env bash
# Rotate /dockyard/SUPER_SECRET_TOKEN and prove both targets pick up the
# fresh value while staying healthy. Only fingerprints (sha256 prefixes) are
# ever displayed or logged; the value itself never leaves Secrets Manager.
#
#   scripts/rotate-and-verify.sh <env>
set -euo pipefail

ENV="${1:?env required (dev|prod)}"
REGION="${AWS_REGION:-us-east-1}"
SECRET_ID="/dockyard/SUPER_SECRET_TOKEN"
NAME="canary-${ENV}"

ALB="https://$(aws elbv2 describe-load-balancers --region "$REGION" --names "${NAME}-alb" \
  --query 'LoadBalancers[0].DNSName' --output text)"
API=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${NAME}-podinfo'].ApiEndpoint" --output text)
LOG_GROUP="/aws/lambda/${NAME}-podinfo"

ec2_fingerprint() {
  curl -ksS -m 10 "${ALB}/env" | tr ',' '\n' | grep -o 'SECRET_FINGERPRINT=[a-f0-9]*' | head -1 | cut -d= -f2
}

lambda_fingerprint() {
  # Latest fingerprint logged by the secret-fp extension.
  aws logs filter-log-events --region "$REGION" --log-group-name "$LOG_GROUP" \
    --filter-pattern '{ $.extension = "secret-fp" && $.fingerprint = "*" }' \
    --start-time $(( ($(date +%s) - 900) * 1000 )) \
    --query 'events[-1].message' --output text 2>/dev/null \
    | grep -o '"fingerprint":"[a-f0-9]*"' | cut -d'"' -f4 || true
}

health() {
  local url=$1 label=$2
  local code
  code=$(curl -ksS -m 10 -o /dev/null -w '%{http_code}' "${url}/healthz")
  echo "   ${label} /healthz -> ${code}"
  [[ "$code" =~ ^[23] ]]
}

echo "== BEFORE rotation"
# poke the Lambda so the extension has logged at least once
curl -ksS -m 10 -o /dev/null "${API}/healthz" || true
EC2_BEFORE=$(ec2_fingerprint); echo "   EC2    fingerprint: ${EC2_BEFORE:-<none>}"
LAMBDA_BEFORE=$(lambda_fingerprint); echo "   Lambda fingerprint: ${LAMBDA_BEFORE:-<none>}"

echo "== Rotating secret"
aws secretsmanager rotate-secret --region "$REGION" --secret-id "$SECRET_ID" >/dev/null
for i in $(seq 1 30); do
  V=$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET_ID" \
    --query 'length(VersionIdsToStages[?@[0]==`AWSPENDING`])' --output text 2>/dev/null || echo x)
  sleep 2
  # rotation is finished when no version is left in AWSPENDING-only state
  PENDING=$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET_ID" \
    --query 'VersionIdsToStages' --output json | python3 -c '
import sys, json
v = json.load(sys.stdin)
print(sum(1 for s in v.values() if s == ["AWSPENDING"]))')
  [[ "$PENDING" == "0" ]] && { echo "   rotation complete"; break; }
  [[ $i -eq 30 ]] && { echo "   rotation did not complete"; exit 1; }
done

echo "== Refreshing EC2 containers (serial, via SSM)"
COLOR=$(aws ssm get-parameter --region "$REGION" --name "/canary/${ENV}/ec2/active-color" \
  --query Parameter.Value --output text)
IMAGE=$(aws ssm get-parameter --region "$REGION" --name "/canary/${ENV}/ec2/active-image" \
  --query Parameter.Value --output text)
PORT=9898; [[ "$COLOR" == "green" ]] && PORT=9899

INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --auto-scaling-group-names "${NAME}-asg" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' --output text)

for ID in $INSTANCE_IDS; do
  echo "   refreshing ${ID}"
  CMD_ID=$(aws ssm send-command --region "$REGION" --instance-ids "$ID" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[
      \"SJ=\$(aws secretsmanager get-secret-value --region ${REGION} --secret-id ${SECRET_ID} --query '{v:SecretString,id:VersionId}' --output json)\",
      \"FP=\$(echo \$SJ | python3 -c 'import sys,json,hashlib;print(hashlib.sha256(json.load(sys.stdin)[\\\"v\\\"].encode()).hexdigest()[:16])')\",
      \"VID=\$(echo \$SJ | python3 -c 'import sys,json;print(json.load(sys.stdin)[\\\"id\\\"])')\",
      \"docker rm -f podinfo-${COLOR}\",
      \"docker run -d --name podinfo-${COLOR} --restart unless-stopped -p ${PORT}:9898 -e ENVIRONMENT=${ENV} -e COLOR=${COLOR} -e SECRET_FINGERPRINT=\$FP -e SECRET_VERSION_ID=\$VID ${IMAGE}\"
    ]" --query 'Command.CommandId' --output text)
  for i in $(seq 1 30); do
    STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" \
      --instance-id "$ID" --query Status --output text 2>/dev/null || echo Pending)
    [[ "$STATUS" == "Success" ]] && break
    [[ "$STATUS" == "Failed" || "$STATUS" == "TimedOut" ]] && { echo "   SSM refresh failed on ${ID}"; exit 1; }
    sleep 3
  done
  sleep 12 # let the ALB health check re-confirm before touching the next host
  health "$ALB" "EC2 (after ${ID})"
done

echo "== Waiting for the Lambda extension refresh cycle (60s)"
sleep 70
curl -ksS -m 10 -o /dev/null "${API}/healthz" || true
sleep 5

echo "== AFTER rotation"
EC2_AFTER=$(ec2_fingerprint); echo "   EC2    fingerprint: ${EC2_AFTER:-<none>}"
LAMBDA_AFTER=$(lambda_fingerprint); echo "   Lambda fingerprint: ${LAMBDA_AFTER:-<none>}"
health "$ALB" "EC2" && health "$API" "Lambda"

[[ -n "$EC2_AFTER" && "$EC2_AFTER" != "$EC2_BEFORE" ]] || { echo "FAIL: EC2 fingerprint unchanged"; exit 1; }
[[ -n "$LAMBDA_AFTER" && "$LAMBDA_AFTER" != "$LAMBDA_BEFORE" ]] || { echo "FAIL: Lambda fingerprint unchanged"; exit 1; }

echo "== PASS: both targets serve with the fresh secret (EC2 ${EC2_BEFORE} -> ${EC2_AFTER}, Lambda ${LAMBDA_BEFORE} -> ${LAMBDA_AFTER})"
