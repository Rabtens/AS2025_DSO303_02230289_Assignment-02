#!/usr/bin/env bash
# Creates one tutor and one student (permanent passwords) for the demo. Run from repo root after `terraform apply`.
set -euo pipefail
POOL=$(terraform -chdir=infra output -raw user_pool_id)
: "${DEMO_TUTOR_EMAIL:?Set the demo tutor email}"
: "${DEMO_STUDENT_EMAIL:?Set the demo student email}"
: "${DEMO_PASSWORD:?Set the demo account password}"
test "$DEMO_TUTOR_EMAIL" != "$DEMO_STUDENT_EMAIL"
for pair in "$DEMO_TUTOR_EMAIL:tutor" "$DEMO_STUDENT_EMAIL:student"; do
  email=${pair%%:*}; group=${pair##*:}
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$email" \
    --user-attributes Name=email,Value="$email" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$email" --password "$DEMO_PASSWORD" --permanent
  aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username "$email" --group-name "$group"
  echo "created $email ($group)"
done
