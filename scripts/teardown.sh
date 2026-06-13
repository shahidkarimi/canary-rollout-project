#!/usr/bin/env bash
# Ordered, idempotent teardown. Safe to re-run: stacks whose state is already
# empty or absent are skipped. The Terraform state bucket and lock table are
# only removed with --all (after everything else has been destroyed).
#
#   scripts/teardown.sh [--all]
set -euo pipefail

REGION="${AWS_REGION:-eu-north-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
STATE_BUCKET="canary-rollout-tfstate-${ACCOUNT_ID}-${REGION}"
LOCK_TABLE="canary-rollout-tf-lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

destroy() {
  local stack=$1 env=$2 key
  if [[ "$stack" == "global" || "$stack" == "observability" ]]; then
    key="${stack}/terraform.tfstate"
  else
    key="${stack}/${env}/terraform.tfstate"
  fi
  if ! aws s3api head-object --bucket "$STATE_BUCKET" --key "$key" >/dev/null 2>&1; then
    echo ">> ${stack}/${env}: no state, skipping"
    return 0
  fi
  echo ">> destroying ${stack}/${env}"
  "${SCRIPT_DIR}/tf.sh" "$stack" "$env" destroy -input=false -auto-approve
}

# Envs before global (env stacks read global remote state); observability first.
destroy observability -
destroy lambda prod
destroy lambda dev
destroy ec2 prod
destroy ec2 dev
destroy global -

if [[ "${1:-}" == "--all" ]]; then
  echo ">> removing Terraform state backend"
  if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
    # delete all versions AND delete markers (bucket is versioned), then the bucket
    aws s3api list-object-versions --bucket "$STATE_BUCKET" \
      --output json --no-paginate 2>/dev/null \
      | python3 -c '
import sys, json, subprocess
data = json.load(sys.stdin)
objs = [{"Key": o["Key"], "VersionId": o["VersionId"]}
        for o in (data.get("Versions") or []) + (data.get("DeleteMarkers") or [])
        if o.get("Key")]
for i in range(0, len(objs), 500):
    batch = {"Objects": objs[i:i+500], "Quiet": True}
    subprocess.run(["aws", "s3api", "delete-objects", "--bucket", sys.argv[1],
                    "--delete", json.dumps(batch)], check=True, capture_output=True)
print(f"deleted {len(objs)} object versions")' "$STATE_BUCKET"
    aws s3api delete-bucket --bucket "$STATE_BUCKET"
    echo ">> state bucket removed"
  fi
  aws dynamodb delete-table --table-name "$LOCK_TABLE" --region "$REGION" >/dev/null 2>&1 \
    && echo ">> lock table removed" || echo ">> lock table already gone"
fi

echo ">> teardown complete"
