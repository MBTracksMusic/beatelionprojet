#!/usr/bin/env bash

# Source Supabase CLI secrets from a local env file into the current shell.
# Usage:
#   source scripts/source-supabase-env.sh
#   source scripts/source-supabase-env.sh .env.staging

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Use: source scripts/source-supabase-env.sh [env-file]"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/.env.local}"
PROJECT_REF_FILE="$ROOT_DIR/supabase/.temp/project-ref"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Env file not found: $ENV_FILE"
  return 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${SUPABASE_DB_PASSWORD:-}" ]]; then
  echo "SUPABASE_DB_PASSWORD is missing in $ENV_FILE"
  return 1
fi

if [[ -z "${SUPABASE_PROJECT_REF:-}" && -f "$PROJECT_REF_FILE" ]]; then
  export SUPABASE_PROJECT_REF
  SUPABASE_PROJECT_REF="$(<"$PROJECT_REF_FILE")"
fi

echo "Loaded SUPABASE_DB_PASSWORD for Supabase CLI."
if [[ -n "${SUPABASE_PROJECT_REF:-}" ]]; then
  echo "Project ref: $SUPABASE_PROJECT_REF"
fi
echo "Next step: supabase db pull"
