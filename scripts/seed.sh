#!/usr/bin/env bash
# Creates one tutor and one student (permanent passwords) for the demo. Run from repo root after `terraform apply`.
set -euo pipefail
POOL=$(terraform -chdir=infra output -raw user_pool_id)
PASS='Demo-Passw0rd-2026'
for pair in "tutor@example.com:tutor" "student@example.com:student"; do
  email=${pair%%:*}; group=${pair##*:}
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$email" \
    --user-attributes Name=email,Value="$email" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null || true
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$email" --password "$PASS" --permanent
  aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username "$email" --group-name "$group"
  echo "created $email ($group)"
done
echo "password for both: $PASS"
