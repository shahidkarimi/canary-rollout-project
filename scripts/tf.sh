#!/usr/bin/env bash
# Terraform wrapper: one stack directory, one state key per environment.
#   scripts/tf.sh <global|lambda|ec2|observability> <dev|prod|-> <terraform args...>
# Examples:
#   scripts/tf.sh global -    apply
#   scripts/tf.sh ec2    dev  plan
#   scripts/tf.sh lambda prod apply -auto-approve
set -euo pipefail

STACK="${1:?stack required (global|lambda|ec2|observability)}"
ENV="${2:?env required (dev|prod, or - for global/observability)}"
shift 2

DIR="$(cd "$(dirname "$0")/../infra/${STACK}" && pwd)"
cd "${DIR}"

if [[ "${STACK}" == "global" || "${STACK}" == "observability" ]]; then
  KEY="${STACK}/terraform.tfstate"
  ENV_ARGS=()
  export TF_DATA_DIR=".terraform"
else
  [[ "${ENV}" == "dev" || "${ENV}" == "prod" ]] || { echo "env must be dev|prod for ${STACK}"; exit 1; }
  KEY="${STACK}/${ENV}/terraform.tfstate"
  ENV_ARGS=(-var "env=${ENV}")
  # Separate plugin/state dirs so dev and prod inits never clobber each other.
  export TF_DATA_DIR=".terraform-${ENV}"
fi

terraform init -input=false -reconfigure -backend-config="key=${KEY}" >/dev/null

CMD="${1:-}"
case "${CMD}" in
  plan|apply|destroy|refresh)
    terraform "$@" "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}"
    ;;
  *)
    terraform "$@"
    ;;
esac
