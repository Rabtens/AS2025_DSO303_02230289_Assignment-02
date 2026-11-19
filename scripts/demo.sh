#!/usr/bin/env bash
# Runs both walkthroughs against the deployed stack and prints evidence. Run from repo root.
set -euo pipefail
OUT=infra; PASS='Demo-Passw0rd-2026'
SITE=$(terraform -chdir=$OUT output -raw site_url)
CLIENT=$(terraform -chdir=$OUT output -raw user_pool_client_id)
BUCKET=$(terraform -chdir=$OUT output -raw uploads_bucket)

login() { aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT" \
  --auth-parameters USERNAME="$1",PASSWORD="$PASS" --query AuthenticationResult.IdToken --output text; }
call() { curl -sS -X "$1" "$SITE/api$2" -H "authorization: $TOKEN" -H 'content-type: application/json' ${3:+-d "$3"}; echo; }

echo "== health"; curl -sS "$SITE/api/health"; echo
TOKEN=$(login tutor@example.com)
echo "== tutor creates exam"
EXAM=$(call POST /exams '{"title":"Demo exam","duration_min":60,"questions":[{"id":"q1","type":"mcq","text":"2+2?","options":["3","4"],"answer":1,"points":1},{"id":"q2","type":"short","text":"Define RPO"}]}')
echo "$EXAM"; ID=$(echo "$EXAM" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

TOKEN=$(login student@example.com)
echo "== WALKTHROUGH 1: student opens exam, answers autosave"
call GET /exams/$ID
call POST /exams/$ID/start
call PUT /exams/$ID/answers '{"answers":{"q1":1,"q2":"Recovery point objective"}}'
call POST /exams/$ID/submit
sleep 5; TOKEN=$(login tutor@example.com); echo "-- auto-marked result:"; call GET /exams/$ID/results

echo "== WALKTHROUGH 2: student uploads 40 MB assignment, tutor notified"
TOKEN=$(login student@example.com)
head -c 40000000 /dev/urandom > /tmp/assignment.zip
PRE=$(call POST /uploads/presign '{"filename":"assignment.zip","size_bytes":40000000}')
URL=$(echo "$PRE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
A=()
while IFS= read -r line; do A+=(-F "$line"); done < <(echo "$PRE" | python3 -c 'import sys,json;[print("%s=%s"%(k,v)) for k,v in json.load(sys.stdin)["fields"].items()]')
curl -sS -o /dev/null -w "S3 direct upload HTTP %{http_code}\n" "${A[@]}" -F file=@/tmp/assignment.zip "$URL"
aws s3 ls "s3://$BUCKET/uploads/" --recursive --human-readable
sleep 8
echo "-- notifier Lambda log (tutor email sent):"
aws logs tail /aws/lambda/exam-platform-notifier --since 2m
echo "-- tutor releases results; student emails queued:"
TOKEN=$(login tutor@example.com); call POST /exams/$ID/release
