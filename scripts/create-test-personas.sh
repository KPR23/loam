#!/bin/bash
# One-time provisioning: creates the Julia/Philip test-account users in the
# staging Supabase project and writes their real credentials into the
# gitignored Loam/Config/Secrets.xcconfig.
#
# Run this yourself in a terminal — never paste a service_role key into chat
# or commit it anywhere. Get the key from:
#   Supabase Dashboard -> loam-demo project -> Settings -> API -> service_role
#
# Usage:
#   SUPABASE_SERVICE_ROLE_KEY=... scripts/create-test-personas.sh

set -euo pipefail

SUPABASE_URL="https://iazyvupjvtuiezugurvo.supabase.co"
SECRETS_FILE="Loam/Config/Secrets.xcconfig"

if [ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]; then
  echo "Set SUPABASE_SERVICE_ROLE_KEY (Dashboard -> loam-demo -> Settings -> API -> service_role) and re-run." >&2
  exit 1
fi

random_password() {
  # 24 chars, alnum + a couple of symbols, no shell-hostile characters.
  LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom | head -c 24
}

create_user() {
  local email="$1"
  local password="$2"
  curl -sS -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$password\",\"email_confirm\":true}"
}

JULIA_EMAIL="julia.test@dev.loam.app"
PHILIP_EMAIL="philip.test@dev.loam.app"
JULIA_PASSWORD=$(random_password)
PHILIP_PASSWORD=$(random_password)

echo "Creating Julia..." >&2
JULIA_RESPONSE=$(create_user "$JULIA_EMAIL" "$JULIA_PASSWORD")
JULIA_ID=$(echo "$JULIA_RESPONSE" | plutil -extract id raw -o - -r - 2>/dev/null || echo "$JULIA_RESPONSE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

echo "Creating Philip..." >&2
PHILIP_RESPONSE=$(create_user "$PHILIP_EMAIL" "$PHILIP_PASSWORD")
PHILIP_ID=$(echo "$PHILIP_RESPONSE" | plutil -extract id raw -o - -r - 2>/dev/null || echo "$PHILIP_RESPONSE" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')

if [ -z "$JULIA_ID" ] || [ -z "$PHILIP_ID" ]; then
  echo "Failed to create one or both users. Responses:" >&2
  echo "Julia: $JULIA_RESPONSE" >&2
  echo "Philip: $PHILIP_RESPONSE" >&2
  exit 1
fi

cat > "$SECRETS_FILE" <<EOF
// Development-only test personas. This file is gitignored and included only by
// Debug.xcconfig. Never copy these values into a production project or scheme.
LOAM_TEST_JULIA_USER_ID = $JULIA_ID
LOAM_TEST_JULIA_EMAIL = $JULIA_EMAIL
LOAM_TEST_JULIA_PASSWORD = $JULIA_PASSWORD
LOAM_TEST_PHILIP_USER_ID = $PHILIP_ID
LOAM_TEST_PHILIP_EMAIL = $PHILIP_EMAIL
LOAM_TEST_PHILIP_PASSWORD = $PHILIP_PASSWORD
EOF

echo "Wrote $SECRETS_FILE"
echo "Julia user id:  $JULIA_ID"
echo "Philip user id: $PHILIP_ID"
echo
echo "Clean-build the app so Xcode picks up the new xcconfig values."
