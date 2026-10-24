#!/usr/bin/env bash
# =============================================================================
# scripts/tf.sh - run Terraform for one deployment target with the right backend.
#
#   ./scripts/tf.sh <stack> --scope <scope> [--env <env>] <terraform args...>
#
#   ./scripts/tf.sh 10-foundation --env dev --scope env init
#   ./scripts/tf.sh 40-unity-catalog --env prd --scope domain:claims plan -out claims.tfplan
#   ./scripts/tf.sh 20-identity --scope shared apply shared.tfplan
#
# A target is (stack, environment, scope); each has its own state key:
#   <stack>/shared.tfstate | <stack>/<env>/{env,access,domain-<name>}.tfstate
# See util/scope.py. `init` always uses -reconfigure so switching targets is safe.
#
# Auth: whatever `az login` session is active (you locally, the environment's
# Terraform SP in CI via azure/login OIDC). Both azurerm and databricks providers use it.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${1:?usage: tf.sh <stack> --scope <scope> [--env <env>] <terraform args...>}"; shift
DIR="$ROOT/stacks/$STACK"
[[ -d "$DIR" ]] || { echo "No such stack: $STACK" >&2; exit 1; }
TF="${TF_BIN:-terraform}"

ENVIRONMENT=""; SCOPE=""
while [[ "${1:-}" == "--env" || "${1:-}" == "--scope" ]]; do
  [[ -n "${2:-}" ]] || { echo "$1 needs a value" >&2; exit 1; }
  case "$1" in --env) ENVIRONMENT="$2" ;; --scope) SCOPE="$2" ;; esac
  shift 2
done
[[ -n "$SCOPE" ]] || { echo "pass --scope (shared | env | access | domain:<name>)" >&2; exit 1; }

cfg() { python3 "$ROOT/scripts/config_value.py" "$1"; }
KEY="$(python3 "$ROOT/scripts/state_key.py" "$STACK" "${ENVIRONMENT:--}" "$SCOPE")"

# The stack reads its target from these variables (also valid with a saved plan).
export TF_VAR_scope="$SCOPE"
if [[ -n "$ENVIRONMENT" ]]; then export TF_VAR_environment="$ENVIRONMENT"; fi

if [[ "${1:-}" == "init" ]]; then
  shift
  exec "$TF" -chdir="$DIR" init -reconfigure \
    -backend-config="resource_group_name=$(cfg state.resource_group)" \
    -backend-config="storage_account_name=$(cfg state.storage_account)" \
    -backend-config="container_name=$(cfg state.container)" \
    -backend-config="key=${KEY}" \
    -backend-config="use_azuread_auth=true" \
    "$@"
fi

exec "$TF" -chdir="$DIR" "$@"
