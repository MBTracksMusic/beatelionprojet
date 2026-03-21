#!/bin/bash

set -euo pipefail

echo "Scanning for real secrets..."

tmp_matches="$(mktemp)"
trap 'rm -f "$tmp_matches"' EXIT

# Scan the repo while skipping safe/template/doc/test/generated SQL content.
find . \
  -type d \( -name node_modules -o -name .git -o -name dist -o -name build -o -name docs -o -name tests \) -prune \
  -o -type f \
  ! -name ".env.example" \
  ! -name "README.md" \
  ! -name "*.sql" \
  -print0 \
  | xargs -0 grep -nH -E \
    '(^|[^A-Z0-9_])(SUPABASE_SERVICE_ROLE_KEY|STRIPE_SECRET_KEY|STRIPE_WEBHOOK_SECRET|RESEND_API_KEY|HCAPTCHA_SECRET_KEY|CONTRACT_SERVICE_SECRET|VERCEL_OIDC_TOKEN)(=|:)|Bearer[[:space:]]+[A-Za-z0-9._=-]{20,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' \
  | grep -v "your_" \
  | grep -v "_xxx" \
  | grep -v ".env.example" \
  | grep -v "README" \
  | awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value);
      sub(/[[:space:]]+$/, "", value);
      return value;
    }

    function unquote(value) {
      value = trim(value);
      gsub(/^["'\''"]|["'\''"]$/, "", value);
      return value;
    }

    function is_placeholder(value) {
      return value == "" ||
        value ~ /^your_/ ||
        value ~ /_xxx$/ ||
        value == "sk_test_xxx" ||
        value == "whsec_xxx" ||
        value == "G-XXXXXXXXXX" ||
        value ~ /example\.com/;
    }

    function looks_like_jwt(value) {
      return value ~ /^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;
    }

    function looks_like_long_base64(value) {
      return length(value) > 40 && value ~ /^[A-Za-z0-9+\/=_-]+$/;
    }

    function looks_like_bearer(line) {
      return line ~ /Bearer[[:space:]]+[A-Za-z0-9._=-]{20,}/;
    }

    {
      line = $0;

      if (looks_like_bearer(line)) {
        print line;
        next;
      }

      if (line ~ /:VITE_[A-Z0-9_]+=/) {
        next;
      }

      raw = line;
      sub(/^[^:]+:[0-9]+:/, "", raw);
      sub(/^[^=]+=/, "", raw);
      value = unquote(raw);

      if (is_placeholder(value)) {
        next;
      }

      if (looks_like_jwt(value) || looks_like_long_base64(value)) {
        print line;
      }
    }
  ' > "$tmp_matches" || true

if [[ -s "$tmp_matches" ]]; then
  echo "REAL SECRET FOUND"
  cat "$tmp_matches"
  exit 1
fi

echo "No real secrets found. Deployment allowed."
