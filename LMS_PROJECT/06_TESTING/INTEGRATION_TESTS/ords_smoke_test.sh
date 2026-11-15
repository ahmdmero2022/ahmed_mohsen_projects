#!/usr/bin/env bash
# ORDS smoke / abuse test for the LMS integration API.  STATUS: written, NOT executed.
# Maps to test IDs: I-06 (catalog), I-07 (verify + 429), I-08..I-10 (HR sync), R-14 (429 + Retry-After),
# R-15 (forged client-IP header ignored), S-16 (verification discloses minimal data), S-17 (no format oracle).
#
# Required environment (never put secrets in this file):
#   BASE_URL        e.g. https://lms-test.example.invalid/ords/lms      (the PROXY URL, not ORDS directly)
#   TOKEN_URL       e.g. https://lms-test.example.invalid/ords/lms/oauth/token
#   HR_CLIENT_ID / HR_CLIENT_SECRET       OAuth2 client lms_hr_sync
#   RO_CLIENT_ID / RO_CLIENT_SECRET       OAuth2 client lms_portal_ro
#   VALID_CODE      a real verification code from test data (optional; enables the positive verify test)
# HR tests need the departments/positions from 02_DATABASE/10_test_data.sql (TD-OPS, TD-LEAD, TD-ANALYST) and create SMK* users.
# Usage: BASE_URL=... ./ords_smoke_test.sh
set -u
: "${BASE_URL:?}" "${TOKEN_URL:?}"
pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1  ($2)"; fail=$((fail+1)); }
expect() { # name, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected $2 got $3"; fi; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
token() { curl -s -u "$1:$2" -d grant_type=client_credentials "$TOKEN_URL" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))'; }

# ---- S-17: unknown and malformed codes look the same --------------------------------------------------
expect "verify unknown code -> 404"       404 "$(code "$BASE_URL/public/certificates/ZZZZZZZZZZZZ")"
expect "verify malformed code -> 404"     404 "$(code "$BASE_URL/public/certificates/..%2f..%2fetc")"

# ---- I-07 / S-16: positive verification returns minimal fields -----------------------------------------
if [ -n "${VALID_CODE:-}" ]; then
  body=$(curl -s "$BASE_URL/public/certificates/$VALID_CODE")
  echo "$body" | python3 -c '
import sys,json
d=json.load(sys.stdin)
allowed={"valid","status","title","issued_on","expires_on","holder"}
extra=set(d)-allowed
print("PASS  verify returns only allowed fields" if not extra else "FAIL  verify leaked fields: %s"%sorted(extra))
sys.exit(1 if extra else 0)' && pass=$((pass+1)) || fail=$((fail+1))
fi

# ---- R-14: quota exceeded -> 429 + Retry-After (policy CERT_VERIFY = 30/min per client) ------------------
hit429=0; retry=""
for i in $(seq 1 45); do
  c=$(curl -s -o /dev/null -D /tmp/lms_hdr.$$ -w '%{http_code}' "$BASE_URL/public/certificates/ZZZZZZZZZZZZ")
  if [ "$c" = "429" ]; then hit429=1; retry=$(grep -i '^retry-after:' /tmp/lms_hdr.$$ | tr -d '\r' | awk '{print $2}'); break; fi
done
rm -f /tmp/lms_hdr.$$
expect "limit reached -> 429" 1 "$hit429"
[ -n "$retry" ] && ok "Retry-After header present ($retry s)" || bad "Retry-After header" "missing"

# ---- R-15: forging the client-IP header must not buy a fresh quota ---------------------------------------
c=$(code -H "X-LMS-Client-IP: 203.0.113.$((RANDOM%250+1))" "$BASE_URL/public/certificates/ZZZZZZZZZZZZ")
expect "forged X-LMS-Client-IP does not reset the quota (proxy overwrites it)" 429 "$c"

# ---- authentication on protected modules -----------------------------------------------------------------
expect "catalog without token -> 401" 401 "$(code "$BASE_URL/catalog/courses")"
expect "hr without token -> 401"      401 "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$BASE_URL/hr/employees")"

if [ -n "${RO_CLIENT_ID:-}" ]; then
  T=$(token "$RO_CLIENT_ID" "$RO_CLIENT_SECRET")
  expect "catalog with token -> 200"  200 "$(code -H "Authorization: Bearer $T" "$BASE_URL/catalog/courses?limit=5")"
  expect "catalog limit is capped"    200 "$(code -H "Authorization: Bearer $T" "$BASE_URL/catalog/courses?limit=100000")"
  expect "catalog SQLi-looking q is inert" 200 "$(code -H "Authorization: Bearer $T" --get --data-urlencode "q=' OR 1=1--" "$BASE_URL/catalog/courses")"
  expect "catalog unknown id -> 404"  404 "$(code -H "Authorization: Bearer $T" "$BASE_URL/catalog/courses/999999999")"
  expect "RO client cannot call HR"   403 "$(code -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d '{"employees":[]}' "$BASE_URL/hr/employees")"
fi

# ---- I-08..I-10: HR sync --------------------------------------------------------------------------------
if [ -n "${HR_CLIENT_ID:-}" ]; then
  T=$(token "$HR_CLIENT_ID" "$HR_CLIENT_SECRET")
  H=(-H "Authorization: Bearer $T" -H 'Content-Type: application/json')
  expect "hr empty batch -> 400" 400 "$(code -X POST "${H[@]}" -d '{"employees":[]}' "$BASE_URL/hr/employees")"
  expect "hr not json -> 400"    400 "$(code -X POST "${H[@]}" -d 'nope' "$BASE_URL/hr/employees")"
  good='{"employees":[
    {"username":"smoke.mgr","employee_no":"SMK001","name_en":"Smoke Manager","email":"smoke.mgr@example.invalid","department_code":"TD-OPS","position_code":"TD-LEAD"},
    {"username":"smoke.emp","employee_no":"SMK002","name_en":"Smoke Employee","email":"smoke.emp@example.invalid","department_code":"TD-OPS","position_code":"TD-ANALYST","manager_employee_no":"SMK001"}]}'
  expect "hr valid batch -> 200"  200 "$(code -X POST "${H[@]}" -d "$good" "$BASE_URL/hr/employees")"
  expect "hr replay is idempotent -> 200" 200 "$(code -X POST "${H[@]}" -d "$good" "$BASE_URL/hr/employees")"
  bad_item='{"employees":[{"username":"","employee_no":"SMK003","name_en":"x","email":"x@example.invalid"}]}'
  expect "hr invalid item -> 207" 207 "$(code -X POST "${H[@]}" -d "$bad_item" "$BASE_URL/hr/employees")"
  term='{"employees":[{"username":"smoke.emp","employee_no":"SMK002","name_en":"Smoke Employee","email":"smoke.emp@example.invalid","status":"INACTIVE"}]}'
  expect "hr deactivation -> 200" 200 "$(code -X POST "${H[@]}" -d "$term" "$BASE_URL/hr/employees")"
  echo "NOTE  verify in the database: LMS_USERS SMK002 status=INACTIVE, manager link SMK002->SMK001, and clean up SMK* rows."
fi

echo "----"; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
