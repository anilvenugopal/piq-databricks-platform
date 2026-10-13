#!/usr/bin/env bash
# =============================================================================
# scripts/tf.sh - run Terraform for one stack with the right backend settings.
#
#   ./scripts/tf.sh <stack> <terraform args...>
#   ./scripts/tf.sh 10-foundation init
#   ./scripts/tf.sh 10-foundation plan -out tfplan
#   ./scripts/tf.sh 10-foundation apply tfplan
#
# Auth: whatever `az login` session is active (you locally, the Terraform SP in
# CI via azure/login OIDC). Both azurerm and databricks providers use it.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:?usage: tf.sh <stack> <terraform args...>}"; shift
DIR="$ROOT/stacks/$STACK"
[[ -d "$DIR" ]] || { echo "No such stack: $STACK" >&2; exit 1; }
TF="${TF_BIN:-terraform}"

cfg() { python3 "$ROOT/scripts/config_value.py" "$1"; }

if [[ "${1:-}" == "init" ]]; then
  shift
  exec "$TF" -chdir="$DIR" init \
    -backend-config="resource_group_name=$(cfg state.resource_group)" \
    -backend-config="storage_account_name=$(cfg state.storage_account)" \
    -backend-config="container_name=$(cfg state.container)" \
    -backend-config="key=${STACK}.tfstate" \
    -backend-config="use_azuread_auth=true" \
    "$@"
fi

exec "$TF" -chdir="$DIR" "$@"
