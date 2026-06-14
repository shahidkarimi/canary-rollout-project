#!/usr/bin/env bash
# Smoke + synthetic checks against a podinfo front door.
#   scripts/smoke.sh <base-url> [label].
# Self-signed ALB cert => -k. Exit non-zero on any failure.
set -euo pipefail

BASE="${1:?base url required}"
LABEL="${2:-$BASE}"
CURL=(curl -ksS -m 10)

fail() { echo "SMOKE FAIL [${LABEL}] $*"; exit 1; }

echo "== smoke [${LABEL}] ${BASE}"

# 1. health, with retries: a just-shifted Lambda version or a freshly
#    registered target can cold-start past a single request's timeout.
CODE=000
for attempt in $(seq 1 12); do
  CODE=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${BASE}/healthz" || echo 000)
  [[ "${CODE}" =~ ^[23] ]] && break
  echo "   /healthz attempt ${attempt}: ${CODE}, retrying..."
  sleep 5
done
[[ "${CODE}" =~ ^[23] ]] || fail "/healthz returned ${CODE} after retries"
echo "   /healthz ${CODE}"

# 2. root + correlation ID
HDRS=$("${CURL[@]}" -D - -o /dev/null "${BASE}/")
echo "${HDRS}" | head -1 | grep -q ' 200' || fail "/ not 200"
REQ_ID=$(echo "${HDRS}" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-request-id"{print $2}')
[[ -n "${REQ_ID}" ]] || fail "missing X-Request-Id header"
echo "   / 200, X-Request-Id=${REQ_ID}"

# 3. version
VERSION=$("${CURL[@]}" "${BASE}/version")
echo "   /version ${VERSION}"

# 4. synthetic: 20 requests, zero non-2xx tolerated, p95 < 1s
ERRORS=0
TIMES=()
for i in $(seq 1 20); do
  OUT=$("${CURL[@]}" -o /dev/null -w '%{http_code} %{time_total}' "${BASE}/api/info" || echo "000 0")
  CODE="${OUT%% *}"; T="${OUT##* }"
  [[ "${CODE}" == "200" ]] || ERRORS=$((ERRORS + 1))
  TIMES+=("${T}")
done
[[ "${ERRORS}" -eq 0 ]] || fail "synthetic: ${ERRORS}/20 non-200 responses"
P95=$(printf '%s\n' "${TIMES[@]}" | sort -n | awk 'BEGIN{c=0}{v[c++]=$1}END{print v[int(c*0.95)]}')
awk -v p="${P95}" 'BEGIN{exit !(p < 1.0)}' || fail "synthetic: p95 ${P95}s >= 1s"
echo "   synthetic 20/20 OK, p95 ${P95}s"

echo "== smoke [${LABEL}] PASS"
