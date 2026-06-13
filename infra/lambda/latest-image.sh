#!/usr/bin/env bash
# external data source helper: emit the digest of the newest *real* podinfo
# image, skipping cosign's signature/attestation artifacts (tagged
# sha256-<hex>.sig / .att) which otherwise win "most recent". Real build tags
# look like sha-<gitsha>-run-<runid>, so they start with "sha-" (not "sha256-").
set -euo pipefail
eval "$(jq -r '@sh "REPO=\(.repo) REGION=\(.region)"')"

DIGEST=$(aws ecr describe-images --repository-name "$REPO" --region "$REGION" \
  --query "reverse(sort_by(imageDetails[?imageTags && starts_with(imageTags[0],'sha-')],&imagePushedAt))[0].imageDigest" \
  --output text)

if [[ -z "$DIGEST" || "$DIGEST" == "None" ]]; then
  echo "no real podinfo image found in $REPO (only cosign artifacts?)" >&2
  exit 1
fi

jq -n --arg digest "$DIGEST" '{"digest":$digest}'
