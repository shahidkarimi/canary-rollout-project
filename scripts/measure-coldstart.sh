#!/usr/bin/env bash
# Measure Lambda cold starts before/after provisioned concurrency.
# Fires a small concurrent burst at the live alias, then reports init
# duration stats from CloudWatch Logs Insights over the last 15 minutes.
#
#   scripts/measure-coldstart.sh <env> [burst]
#
# Run once right after a deploy with provisioned_concurrency=0 (every burst
# invocation cold-starts) and once after enabling it (provisioned environments
# serve the burst with zero inits). Results go into docs/SCALING.md.
set -euo pipefail

ENV="${1:?env required (dev|prod)}"
BURST="${2:-5}"
REGION="${AWS_REGION:-us-east-1}"
FN="canary-${ENV}-podinfo"
LOG_GROUP="/aws/lambda/${FN}"

echo "== firing burst of ${BURST} concurrent invocations at ${FN}:live"
for i in $(seq 1 "$BURST"); do
  aws lambda invoke --region "$REGION" --function-name "${FN}:live" \
    --payload '{"requestContext":{"http":{"method":"GET","path":"/healthz"}},"rawPath":"/healthz","headers":{},"version":"2.0"}' \
    --cli-binary-format raw-in-base64-out "/tmp/out-$i.json" >/dev/null &
done
wait
echo "   burst complete"

echo "== waiting 60s for logs to land"
sleep 60

START=$(( $(date +%s) - 900 ))
END=$(date +%s)
QUERY_ID=$(aws logs start-query --region "$REGION" \
  --log-group-name "$LOG_GROUP" \
  --start-time "$START" --end-time "$END" \
  --query-string 'filter @type = "REPORT"
    | stats count(*) as invocations,
            count(@initDuration) as cold_starts,
            avg(@initDuration) as init_avg_ms,
            pct(@initDuration, 50) as init_p50_ms,
            pct(@initDuration, 99) as init_p99_ms,
            pct(@duration, 50) as dur_p50_ms,
            pct(@duration, 99) as dur_p99_ms' \
  --query queryId --output text)

for i in $(seq 1 30); do
  STATUS=$(aws logs get-query-results --region "$REGION" --query-id "$QUERY_ID" --query status --output text)
  [[ "$STATUS" == "Complete" ]] && break
  sleep 2
done

echo "== init/duration stats (last 15 min, ${FN})"
aws logs get-query-results --region "$REGION" --query-id "$QUERY_ID" \
  --query 'results[0][].{metric:field,value:value}' --output table

PC=$(aws lambda get-provisioned-concurrency-config --region "$REGION" \
  --function-name "$FN" --qualifier live \
  --query '{requested:RequestedProvisionedConcurrentExecutions,status:Status}' --output text 2>/dev/null || echo "disabled")
echo "== provisioned concurrency on ${FN}:live -> ${PC}"
