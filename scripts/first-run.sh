#!/usr/bin/env bash
# First-time bring-up: fresh clone / fresh account -> fully running system.
# Runs every stack in dependency order and works around the chicken-and-egg the
# README warns about: the `lambda` stack's data.external.latest_image needs a
# REAL podinfo image (tagged sha-<gitsha>-run-<runid>) in ECR before it can
# resolve a digest -- cosign's .sig/.att artifacts win "most recent" but don't
# count. So we ensure that image exists (triggering the pipeline build if not)
# before applying lambda.
#
# Idempotent: every Terraform apply is a no-op when nothing changed, so this is
# safe to re-run after a partial failure.
#
#   scripts/first-run.sh
#
# Env overrides:
#   AWS_REGION          (default eu-north-1)
#   SKIP_FINAL_PIPELINE=1   skip the closing full pipeline run (infra only)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
TF="${ROOT}/scripts/tf.sh"

REGION="${AWS_REGION:-eu-north-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REPO="canary/podinfo"        # = ${project}/podinfo, matches infra/lambda data source
WORKFLOW="pipeline"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Digest of the newest *real* image, or empty. Mirrors latest-image.sh exactly,
# so "non-empty" == "the lambda data source will succeed".
real_image_digest() {
  aws ecr describe-images --repository-name "${REPO}" --region "${REGION}" \
    --query "reverse(sort_by(imageDetails[?imageTags && starts_with(imageTags[0],'sha-')],&imagePushedAt))[0].imageDigest" \
    --output text 2>/dev/null || true
}

# Latest pipeline run id (databaseId), or empty.
latest_run_id() {
  gh run list --workflow "${WORKFLOW}" --limit 1 --json databaseId \
    --jq '.[0].databaseId' 2>/dev/null || true
}

echo ">> Account ${ACCOUNT_ID} | Region ${REGION} | Repo ${REPO}"

# --- 0. state backend + Terraform version ----------------------------------
step "bootstrap state backend (idempotent)"
scripts/bootstrap.sh
tfenv install   # honors .terraform-version (1.15.6)

# --- 1. global: ECR, OIDC roles, KMS, SNS, secret + rotation, log redaction --
step "global apply"
"${TF}" global - apply -auto-approve

# --- 2. ec2 dev: VPC, ALB, ASG, CodeDeploy ----------------------------------
step "ec2 dev apply"
"${TF}" ec2 dev apply -auto-approve

# --- 3. ensure a real image exists before touching lambda -------------------
step "ensure first real image in ECR"
DIGEST="$(real_image_digest)"
if [[ -z "${DIGEST}" || "${DIGEST}" == "None" ]]; then
  echo ">> No sha-<gitsha>-run-<runid> image yet -- triggering the pipeline to build one."
  echo ">> (this first run's deploy-dev may FAIL at 'Lambda: publish version' because"
  echo ">>  lambda isn't applied yet -- that's expected; we only need the build to push.)"
  gh workflow run "${WORKFLOW}"
  echo -n ">> Waiting for the build job to push the image"
  for _ in $(seq 1 60); do          # up to ~20 min
    DIGEST="$(real_image_digest)"
    [[ -n "${DIGEST}" && "${DIGEST}" != "None" ]] && break
    echo -n "."
    sleep 20
  done
  echo
fi
if [[ -z "${DIGEST}" || "${DIGEST}" == "None" ]]; then
  echo "!! Timed out waiting for a real image in ${REPO}. Check the pipeline build job:" >&2
  echo "   gh run view $(latest_run_id)" >&2
  exit 1
fi
echo ">> Real image present: ${DIGEST}"

# --- 4. lambda dev (now the digest lookup resolves) -------------------------
step "lambda dev apply"
"${TF}" lambda dev apply -auto-approve

# --- 5. prod stacks ---------------------------------------------------------
step "ec2 prod apply"
"${TF}" ec2 prod apply -auto-approve

step "lambda prod apply (provisioned_concurrency=0 -- account cap of 10 blocks >0)"
"${TF}" lambda prod apply -auto-approve -var provisioned_concurrency=0

# --- 6. observability dashboard ---------------------------------------------
step "observability apply"
"${TF}" observability - apply -auto-approve -var 'envs=["dev","prod"]'

# --- 7. final clean pipeline run: build -> deploy-dev -> stop at prod gate ---
if [[ "${SKIP_FINAL_PIPELINE:-0}" == "1" ]]; then
  echo ">> SKIP_FINAL_PIPELINE=1 set -- infrastructure is up; not running the pipeline."
else
  step "full pipeline run (deploys both runtimes in dev, then waits for prod approval)"
  PREV_RUN="$(latest_run_id)"
  gh workflow run "${WORKFLOW}"
  RUN_ID=""
  for _ in $(seq 1 15); do          # wait for the new run to register
    RUN_ID="$(latest_run_id)"
    [[ -n "${RUN_ID}" && "${RUN_ID}" != "${PREV_RUN}" ]] && break
    sleep 4
  done
  echo ">> Watching run ${RUN_ID} ..."
  for _ in $(seq 1 60); do          # up to ~20 min
    STATUS="$(gh run view "${RUN_ID}" --json status --jq '.status' 2>/dev/null || true)"
    printf '   [%s] %s\n' "$(date +%H:%M:%S)" "${STATUS}"
    # 'waiting' == parked at the prod required-reviewer gate (deliberate human step)
    [[ "${STATUS}" == "completed" || "${STATUS}" == "waiting" ]] && break
    sleep 20
  done
  echo ">> deploy-dev result:"
  gh run view "${RUN_ID}" --json jobs \
    --jq '.jobs[] | select(.name|test("build|deploy-dev")) | "   "+.name+": "+(.conclusion//.status)'
  echo
  echo ">> Pipeline is parked at the prod approval gate -- this is intentional."
  echo "   Approve to promote prod:"
  echo "   https://github.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/actions/runs/${RUN_ID}"
fi

# --- done -------------------------------------------------------------------
step "done -- front doors + dashboard"
DASH="$("${TF}" observability - output -raw dashboard_url 2>/dev/null || true)"
[[ -n "${DASH}" ]] && echo ">> Dashboard: ${DASH}"
echo ">> Smoke (best-effort):"
LAMBDA_API="$("${TF}" lambda dev output -raw api_endpoint 2>/dev/null || true)"
ALB_DNS="$("${TF}" ec2 dev output -raw alb_dns_name 2>/dev/null || true)"
[[ -n "${LAMBDA_API}" ]] && curl -s  -o /dev/null -w "   lambda dev  %{http_code}  ${LAMBDA_API}\n" "${LAMBDA_API}/" || true
[[ -n "${ALB_DNS}"   ]] && curl -sk -o /dev/null -w "   ec2 dev ALB %{http_code}  https://${ALB_DNS}\n" "https://${ALB_DNS}/" || true
