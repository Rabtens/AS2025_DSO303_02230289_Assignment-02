#!/usr/bin/env bash
# Runs both walkthroughs against the deployed stack and prints evidence. Run from repo root.
set -euo pipefail
OUT=infra
: "${DEMO_TUTOR_EMAIL:?Set the demo tutor email}"
: "${DEMO_STUDENT_EMAIL:?Set the demo student email}"
: "${DEMO_PASSWORD:?Set the demo account password}"
SITE=$(terraform -chdir=$OUT output -raw site_url)
CLIENT=$(terraform -chdir=$OUT output -raw user_pool_client_id)
BUCKET=$(terraform -chdir=$OUT output -raw uploads_bucket)

login() { aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH --client-id "$CLIENT" \
  --auth-parameters USERNAME="$1",PASSWORD="$DEMO_PASSWORD" --query AuthenticationResult.IdToken --output text; }
call() { curl --fail-with-body -sS -X "$1" "$SITE/api$2" -H "authorization: $TOKEN" -H 'content-type: application/json' ${3:+-d "$3"} && echo; }

echo "== health"; curl -fsS "$SITE/api/health"; echo
TOKEN=$(login "$DEMO_TUTOR_EMAIL")
echo "== tutor creates exam"
EXAM=$(call POST /exams '{"title":"Demo exam","duration_min":60,"questions":[{"id":"q1","type":"mcq","text":"2+2?","options":["3","4"],"answer":1,"points":1},{"id":"q2","type":"short","text":"Define RPO"}]}')
echo "$EXAM"; ID=$(echo "$EXAM" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

TOKEN=$(login "$DEMO_STUDENT_EMAIL")
echo "== WALKTHROUGH 1: student opens exam, answers autosave"
call GET /exams/$ID
call POST /exams/$ID/start
call PUT /exams/$ID/answers '{"answers":{"q1":1,"q2":"Recovery point objective"}}'
call POST /exams/$ID/submit
TOKEN=$(login "$DEMO_TUTOR_EMAIL")
echo "-- waiting for the MCQ marking worker"
for attempt in {1..12}; do
  RESULTS=$(call GET /exams/$ID/results)
  if jq -e 'any(.[]; (.score | tonumber) == 1)' <<< "$RESULTS" >/dev/null 2>&1; then
    echo "MCQ score: 1"
    break
  fi
  if [ "$attempt" -eq 12 ]; then
    echo "The marking worker did not record the expected score." >&2
    exit 1
  fi
  sleep 5
done

echo "== WALKTHROUGH 2: student uploads 40 MB assignment, tutor notified"
TOKEN=$(login "$DEMO_STUDENT_EMAIL")
WORKDIR=$(mktemp -d)
trap 'rm -rf -- "$WORKDIR"' EXIT
python3 - "$WORKDIR/assignment.zip" <<'PY'
import os
import sys
from zipfile import ZipFile

with ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("payload.bin", os.urandom(39_999_880))
PY
test "$(wc -c < "$WORKDIR/assignment.zip")" -eq 40000000
PRE=$(call POST /uploads/presign '{"filename":"assignment.zip","size_bytes":40000000}')
URL=$(echo "$PRE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
A=()
while IFS= read -r line; do A+=(-F "$line"); done < <(echo "$PRE" | python3 -c 'import sys,json;[print("%s=%s"%(k,v)) for k,v in json.load(sys.stdin)["fields"].items()]')
curl -fsS -o /dev/null -w "S3 direct upload HTTP %{http_code}\n" "${A[@]}" -F "file=@$WORKDIR/assignment.zip" "$URL"
KEY=$(jq -er '.fields.key' <<< "$PRE")
SIZE=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text)
test "$SIZE" -eq 40000000
echo "Stored assignment size: $SIZE bytes"
echo "-- tutor releases results; student emails queued:"
TOKEN=$(login "$DEMO_TUTOR_EMAIL"); call POST /exams/$ID/release
echo "Check the tutor and student inboxes for the upload and release emails."
