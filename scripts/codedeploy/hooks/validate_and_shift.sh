#!/usr/bin/env bash
# ValidateService: local health check on every host; the elected leader then
# performs the weighted ALB canary (90/10 -> alarm watch -> 0/100).
#
# A non-zero exit anywhere here fails the deployment, which triggers
# CodeDeploy auto-rollback (redeploy of the last good revision); the leader
# additionally restores 100% of traffic to the active color immediately.
#
# Canary parameters: 10% for 120s. With 60s alarm periods the two rollback
# alarms (target 5xx, target p99 response time) each get two evaluation
# windows before full shift; at demo traffic levels longer holds add waiting,
# not signal.
set -euo pipefail
source "$(dirname "$0")/common.sh"

CANARY_PERCENT=10
CANARY_HOLD_SECONDS=120
ALARMS=("${NAME}-alb-target-5xx" "${NAME}-alb-target-rt-p99")

# --- 1. local container health ----------------------------------------------
for i in $(seq 1 30); do
  if curl -fsS -m 2 "http://localhost:${TARGET_PORT}/healthz" >/dev/null; then
    log "local ${TARGET_COLOR} container healthy"
    break
  fi
  [[ $i -eq 30 ]] && { log "local health check failed"; exit 1; }
  sleep 2
done

# --- 2. leader election (lowest in-service instance id in the ASG) -----------
ASG_NAME="${NAME}-asg"
LEADER=$(aws autoscaling describe-auto-scaling-groups --region "${REGION}" \
  --auto-scaling-group-names "${ASG_NAME}" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
  --output text | tr '\t' '\n' | sort | head -1)

if [[ "${INSTANCE_ID}" != "${LEADER}" ]]; then
  log "follower: waiting for leader ${LEADER} to complete the shift"
  for i in $(seq 1 150); do
    [[ "$(get_param "${PARAM_COLOR}")" == "${TARGET_COLOR}" ]] && { log "shift confirmed"; exit 0; }
    sleep 5
  done
  log "timed out waiting for traffic shift"
  exit 1
fi
log "leader: orchestrating canary shift to ${TARGET_COLOR}"

# --- 3. resolve ALB resources -------------------------------------------------
LISTENER_ARN=$(aws elbv2 describe-listeners --region "${REGION}" \
  --load-balancer-arn "$(aws elbv2 describe-load-balancers --region "${REGION}" \
    --names "${NAME}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query 'Listeners[?Port==`443`].ListenerArn' --output text)
TARGET_TG=$(aws elbv2 describe-target-groups --region "${REGION}" \
  --names "${NAME}-${TARGET_COLOR}" --query 'TargetGroups[0].TargetGroupArn' --output text)
OTHER_COLOR=$([[ "${TARGET_COLOR}" == "blue" ]] && echo green || echo blue)
OTHER_TG=$(aws elbv2 describe-target-groups --region "${REGION}" \
  --names "${NAME}-${OTHER_COLOR}" --query 'TargetGroups[0].TargetGroupArn' --output text)

set_weights() { # $1 = target weight, $2 = other weight
  aws elbv2 modify-listener --region "${REGION}" --listener-arn "${LISTENER_ARN}" \
    --default-actions "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[
      {\"TargetGroupArn\":\"${TARGET_TG}\",\"Weight\":$1},
      {\"TargetGroupArn\":\"${OTHER_TG}\",\"Weight\":$2}]}}]" >/dev/null
  log "weights: ${TARGET_COLOR}=$1 ${OTHER_COLOR}=$2"
}

rollback() {
  log "ROLLBACK: restoring 100% to ${OTHER_COLOR}"
  set_weights 0 100
  exit 1
}

# --- 4. wait for the target TG to be fully healthy ----------------------------
for i in $(seq 1 30); do
  HEALTHY=$(aws elbv2 describe-target-health --region "${REGION}" \
    --target-group-arn "${TARGET_TG}" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)
  [[ "${HEALTHY}" -ge 2 ]] && { log "target TG healthy (${HEALTHY}/2)"; break; }
  [[ $i -eq 30 ]] && { log "target TG never became healthy"; rollback; }
  sleep 5
done

# --- 5. canary: 10%, hold, watch alarms ---------------------------------------
if [[ -n "${ACTIVE_PORT}" ]]; then
  set_weights "${CANARY_PERCENT}" "$((100 - CANARY_PERCENT))"
  ELAPSED=0
  while [[ ${ELAPSED} -lt ${CANARY_HOLD_SECONDS} ]]; do
    sleep 15; ELAPSED=$((ELAPSED + 15))
    FIRING=$(aws cloudwatch describe-alarms --region "${REGION}" \
      --alarm-names "${ALARMS[@]}" --state-value ALARM \
      --query 'length(MetricAlarms)' --output text)
    [[ "${FIRING}" != "0" ]] && { log "alarm firing during canary hold"; rollback; }
    log "canary hold ${ELAPSED}/${CANARY_HOLD_SECONDS}s: alarms OK"
  done
else
  log "first deploy: no active color, promoting directly"
fi

# --- 6. promote to 100% and record state --------------------------------------
set_weights 100 0
put_param "${PARAM_COLOR}" "${TARGET_COLOR}"
put_param "${PARAM_IMAGE}" "${IMAGE}"
log "promotion complete: ${TARGET_COLOR} serving 100%"
