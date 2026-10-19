#!/bin/bash
# Creates the two sample users on a running local Supabase stack and loads seed.sql.
# Everything here is fake and local; the credentials are the ones the screenshot workflow passes to the app.
#
# Usage: scripts/screenshots/seed-backend.sh   (after `supabase start`)

set -euo pipefail

cd "$(dirname "$0")/../.."

eval "$(supabase status -o env | grep -E '^(API_URL|SERVICE_ROLE_KEY|DB_URL)=')"

create_user() {
  curl --fail --silent --show-error --output /dev/null --request POST "$API_URL/auth/v1/admin/users" \
    --header "apikey: $SERVICE_ROLE_KEY" --header "Authorization: Bearer $SERVICE_ROLE_KEY" \
    --header 'Content-Type: application/json' \
    --data "{\"id\":\"$1\",\"email\":\"$2\",\"password\":\"$3\",\"email_confirm\":true,\"user_metadata\":{\"full_name\":\"$4\"}}"
}

create_user 00000000-0000-4000-8000-0000000000a1 julia@screenshots.invalid screenshot-julia Julia
create_user 00000000-0000-4000-8000-0000000000b2 philip@screenshots.invalid screenshot-philip Philip

psql "$DB_URL" --quiet --file scripts/screenshots/seed.sql
echo "Seeded Julia and Philip."
