#!/usr/bin/env bash
# Add a user to the nervecentre.splippers.com Cloudflare Access policy.
#
# Usage:
#   sudo bash deploy/charkive/add-cf-user.sh user@example.com
set -euo pipefail

CF_API="https://api.cloudflare.com/client/v4"
STATE_DIR="/tmp/cfportal-uploads"

die() { echo "error: $*" >&2; exit 1; }

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <email> [email2 ...]"
  exit 1
fi

TOKEN=""
if [[ -f "${STATE_DIR}/api_token.txt" ]]; then
  TOKEN="$(cat "${STATE_DIR}/api_token.txt")"
fi
[[ -n "${TOKEN}" ]] || die "No API token found at ${STATE_DIR}/api_token.txt"

ACCOUNT_ID=""
if [[ -f "${STATE_DIR}/account_id" ]]; then
  ACCOUNT_ID="$(cat "${STATE_DIR}/account_id")"
fi
[[ -n "${ACCOUNT_ID}" ]] || die "No account_id found. Run setup-cf-access.sh first."

HOSTNAME="nervecentre.splippers.com"

cf_get() { curl -s -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" "${CF_API}/${1#/}"; }
cf_put() { curl -s -X PUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${2}" "${CF_API}/${1#/}"; }

# Find the Access app
APPS=$(cf_get "accounts/${ACCOUNT_ID}/access/apps")
APP_ID=$(echo "${APPS}" | python3 -c "
import sys,json
for a in json.load(sys.stdin).get('result',[]):
    if 'nervecentre' in a.get('domain',''):
        print(a['id'])
        break
" 2>/dev/null || true)
[[ -n "${APP_ID}" ]] || die "Access app for nervecentre not found."

# Find the "Allowed users" policy
POLICIES=$(cf_get "accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies")
POLICY_ID=$(echo "${POLICIES}" | python3 -c "
import sys,json
for p in json.load(sys.stdin).get('result',[]):
    if p.get('name')=='Allowed users':
        print(p['id'])
        break
" 2>/dev/null || true)
[[ -n "${POLICY_ID}" ]] || die "Allowed users policy not found."

# Get current policy
CURRENT=$(cf_get "accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies/${POLICY_ID}")
CURRENT_INCLUDE=$(echo "${CURRENT}" | python3 -c "
import sys,json
d=json.load(sys.stdin)
import json as j
print(j.dumps(d.get('result',{}).get('include',[])))
" 2>/dev/null || echo "[]")

# Add new emails
ADDED=0
for EMAIL in "$@"; do
  if ! echo "${CURRENT_INCLUDE}" | python3 -c "import sys,json; [e for e in json.load(sys.stdin) if e.get('email',{}).get('email')=='${EMAIL}']" 2>/dev/null | grep -q "${EMAIL}"; then
    UPDATED=$(echo "${CURRENT_INCLUDE}" | python3 -c "
import sys,json
incs=json.load(sys.stdin)
incs.append({'email':{'email':'${EMAIL}'}})
print(json.dumps(incs))
")
    CURRENT_INCLUDE="${UPDATED}"
    ADDED=$((ADDED + 1))
    echo "Added: ${EMAIL}"
  else
    echo "Already present: ${EMAIL}"
  fi
done

if [[ "${ADDED}" -gt 0 ]]; then
  BODY="{\"name\":\"Allowed users\",\"decision\":\"allow\",\"include\":${CURRENT_INCLUDE},\"exclude\":[],\"require\":[]}"
  cf_put "accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies/${POLICY_ID}" "${BODY}" >/dev/null
  echo "Policy updated with ${ADDED} new user(s)."
fi
