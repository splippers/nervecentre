#!/usr/bin/env bash
# Set up nervecentre.splippers.com via Cloudflare Tunnel + Access.
#
# Prerequisites:
#   1. Cloudflare API token with DNS:Edit, Access:Write, Tunnel:Write permissions
#      (same token used by cfportal — stored at /tmp/cfportal-uploads/api_token.txt)
#   2. cloudflared installed
#   3. Tunnel already created by cfportal (nc-splippers)
#
# Usage:
#   sudo bash deploy/charkive/setup-cf-access.sh
#
# This script:
#   1. Adds DNS CNAME nervecentre.splippers.com → tunnel
#   2. Updates tunnel config to route nervecentre.splippers.com → localhost:80
#   3. Creates Cloudflare Access application requiring jon@splippers.com
#   4. Restarts cloudflared

set -euo pipefail

CF_API="https://api.cloudflare.com/client/v4"
TUNNEL_DIR="/etc/cloudflared"
STATE_DIR="/tmp/cfportal-uploads"
TUNNEL_NAME="nc-splippers"
SVC_NAME="cloudflared-nc-splippers"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() { echo -e "${RED}error: $*${NC}" >&2; exit 1; }
ok()  { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}warning: $*${NC}"; }

# ── helpers ───────────────────────────────────────────────────────────────

TOKEN=""
if [[ -f "${STATE_DIR}/api_token.txt" ]]; then
  TOKEN="$(cat "${STATE_DIR}/api_token.txt")"
fi
if [[ -z "${TOKEN}" ]]; then
  die "No API token found at ${STATE_DIR}/api_token.txt. Run cfportal first."
fi

ACCOUNT_ID=""
if [[ -f "${STATE_DIR}/account_id" ]]; then
  ACCOUNT_ID="$(cat "${STATE_DIR}/account_id")"
fi

ZONE_ID=""
ZONE_NAME=""
if [[ -f "${STATE_DIR}/zone_id" ]]; then
  ZONE_ID="$(cat "${STATE_DIR}/zone_id")"
fi
if [[ -f "${STATE_DIR}/zone_name" ]]; then
  ZONE_NAME="$(cat "${STATE_DIR}/zone_name")"
fi

TUNNEL_ID=""
if [[ -f "${STATE_DIR}/tunnel_id" ]]; then
  TUNNEL_ID="$(cat "${STATE_DIR}/tunnel_id")"
fi

cf_get() {
  curl -s -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    "${CF_API}/${1#/}"
}

cf_post() {
  curl -s -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "${2:-{}}" "${CF_API}/${1#/}"
}

cf_put() {
  curl -s -X PUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "${2:-{}}" "${CF_API}/${1#/}"
}

cf_patch() {
  curl -s -X PATCH -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "${2:-{}}" "${CF_API}/${1#/}"
}

# ── Discover zone if not set ─────────────────────────────────────────────

if [[ -z "${ZONE_ID}" ]] || [[ "${ZONE_ID}" == "MANUAL" ]]; then
  echo "Discovering zone..."
  ZONES=$(cf_get "zones?name=splippers.com")
  ZID=$(echo "${ZONES}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null || true)
  ZNAME=$(echo "${ZONES}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['name'] if d.get('result') else '')" 2>/dev/null || true)

  if [[ -z "${ZID}" ]]; then
    echo "Trying broader zone discovery..."
    ZONES=$(cf_get "zones?per_page=50")
    for row in $(echo "${ZONES}" | python3 -c "import sys,json; [print(z['id'],z['name']) for z in json.load(sys.stdin).get('result',[])]" 2>/dev/null); do
      read -r ZID ZNAME <<< "${row}"
      if echo "${ZNAME}" | grep -qi "splippers"; then
        break
      fi
    done
  fi

  if [[ -z "${ZID}" ]]; then
    die "Could not discover zone. Set CFPORTAL_ZONE_ID env var or provide zone_id in cfportal."
  fi
  echo "  Zone: ${ZNAME} (${ZID})"
  ZONE_ID="${ZID}"
  ZONE_NAME="${ZNAME}"
fi

# Discover account if not set
if [[ -z "${ACCOUNT_ID}" ]]; then
  echo "Discovering account..."
  ACCS=$(cf_get "accounts")
  ACCOUNT_ID=$(echo "${ACCS}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null || true)
  if [[ -z "${ACCOUNT_ID}" ]]; then
    die "Could not discover account."
  fi
  echo "  Account: ${ACCOUNT_ID}"
fi

# Discover tunnel if not set
if [[ -z "${TUNNEL_ID}" ]]; then
  echo "Discovering tunnel ${TUNNEL_NAME}..."
  TUNNELS=$(cf_get "accounts/${ACCOUNT_ID}/cfd_tunnel")
  TUNNEL_ID=$(echo "${TUNNELS}" | python3 -c "
import sys,json
for t in json.load(sys.stdin).get('result',[]):
    if t.get('name')=='${TUNNEL_NAME}' and not t.get('deleted'):
        print(t['id'])
" 2>/dev/null || true)
  if [[ -z "${TUNNEL_ID}" ]]; then
    die "Tunnel '${TUNNEL_NAME}' not found. Create it via cfportal first."
  fi
  echo "  Tunnel: ${TUNNEL_ID}"
fi

HOSTNAME="nervecentre.splippers.com"
CNAME="${TUNNEL_ID}.cfargotunnel.com"

# ── Step 1: DNS Record ───────────────────────────────────────────────────

echo ""
echo "=== Step 1: DNS CNAME ${HOSTNAME} → ${CNAME} ==="
EXISTING=$(cf_get "zones/${ZONE_ID}/dns_records?type=CNAME&name=${HOSTNAME}")
EXISTS=$(echo "${EXISTING}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('result') and len(d['result'])>0 else 'no')" 2>/dev/null || echo "no")

if [[ "${EXISTS}" == "yes" ]]; then
  ok "DNS record for ${HOSTNAME} already exists."
  RECORD_ID=$(echo "${EXISTING}" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null || true)
else
  echo "Creating DNS CNAME ${HOSTNAME} → ${CNAME}..."
  RESULT=$(cf_post "zones/${ZONE_ID}/dns_records" \
    "{\"type\":\"CNAME\",\"name\":\"nervecentre\",\"content\":\"${CNAME}\",\"ttl\":120,\"proxied\":true}")
  SUCCESS=$(echo "${RESULT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('success') else d.get('errors',[{}])[0].get('message','fail'))" 2>/dev/null || echo "fail")
  if [[ "${SUCCESS}" != "ok" ]]; then
    die "DNS record failed: ${SUCCESS}"
  fi
  RECORD_ID=$(echo "${RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['id'])" 2>/dev/null || true)
  ok "DNS record created (ID: ${RECORD_ID})"
fi

# ── Step 2: Update tunnel config ─────────────────────────────────────────

echo ""
echo "=== Step 2: Update tunnel config.yml ==="
CONFIG_FILE="${TUNNEL_DIR}/config.yml"
if [[ -f "${CONFIG_FILE}" ]]; then
  # Check if nervecentre.splippers.com is already in the ingress
  if grep -q "nervecentre.splippers.com" "${CONFIG_FILE}" 2>/dev/null; then
    ok "Tunnel config already includes ${HOSTNAME}."
  else
    echo "Adding ${HOSTNAME} to tunnel ingress..."
    # Insert a new ingress rule before the catch-all (last rule)
    python3 -c "
import yaml, sys
with open('${CONFIG_FILE}') as f:
    cfg = yaml.safe_load(f)
# Insert nervecentre before the catch-all (last) rule
ingress = cfg.get('ingress', [])
if len(ingress) > 0:
    ingress.insert(-1, {'hostname': '${HOSTNAME}', 'service': 'http://localhost:80'})
else:
    ingress.append({'hostname': '${HOSTNAME}', 'service': 'http://localhost:80'})
cfg['ingress'] = ingress
with open('${CONFIG_FILE}', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
print('Updated config.yml')
" || die "Failed to update config.yml"
    ok "Tunnel config updated."
  fi
else
  warn "No config.yml at ${TUNNEL_DIR} — skipping tunnel config update."
fi

# ── Step 3: Cloudflare Access Application ─────────────────────────────────

echo ""
echo "=== Step 3: Cloudflare Access Application ==="
ACCESS_URL="https://${HOSTNAME}"

# Check if an Access app already exists
EXISTING_APP=$(cf_get "accounts/${ACCOUNT_ID}/access/apps?name=${HOSTNAME}")
APP_EXISTS=$(echo "${EXISTING_APP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('result') and len(d['result'])>0 else 'no')" 2>/dev/null || echo "no")

if [[ "${APP_EXISTS}" == "yes" ]]; then
  APP_ID=$(echo "${EXISTING_APP}" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null || true)
  ok "Access application for ${HOSTNAME} already exists (ID: ${APP_ID})."
else
  echo "Creating Access application for ${HOSTNAME}..."
  APP_BODY=$(cat <<EOF
{
  "name": "${HOSTNAME}",
  "domain": "${HOSTNAME}",
  "session_duration": "24h",
  "type": "self_hosted",
  "allowed_idps": ["all"],
  "auto_redirect_to_identity": false,
  "enable_binding_cookie": false,
  "app_launcher_visible": false
}
EOF
)
  APP_RESULT=$(cf_post "accounts/${ACCOUNT_ID}/access/apps" "${APP_BODY}")
  APP_SUCCESS=$(echo "${APP_RESULT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('success') else d.get('errors',[{}])[0].get('message','fail'))" 2>/dev/null || echo "fail")
  if [[ "${APP_SUCCESS}" != "ok" ]]; then
    die "Access app creation failed: ${APP_SUCCESS}"
  fi
  APP_ID=$(echo "${APP_RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['id'])" 2>/dev/null || true)
  ok "Access application created (ID: ${APP_ID})"
fi

# ── Step 4: Access Policy — only jon@splippers.com ───────────────────────

echo ""
echo "=== Step 4: Access Policy (jon@splippers.com) ==="
POLICY_BODY=$(cat <<EOF
{
  "name": "Allowed users",
  "decision": "allow",
  "include": [
    {"email": {"email": "jon@splippers.com"}}
  ],
  "exclude": [],
  "require": [],
  "precedence": 1
}
EOF
)

# Check if policy already exists
EXISTING_POLICIES=$(cf_get "accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies")
HAS_POLICY=$(echo "${EXISTING_POLICIES}" | python3 -c "
import sys,json
for p in json.load(sys.stdin).get('result',[]):
    if p.get('name')=='Allowed users':
        print('yes')
        break
else:
    print('no')
" 2>/dev/null || echo "no")

if [[ "${HAS_POLICY}" == "yes" ]]; then
  ok "Access policy 'Allowed users' already exists."
else
  echo "Creating Access policy allowing jon@splippers.com..."
  POLICY_RESULT=$(cf_post "accounts/${ACCOUNT_ID}/access/apps/${APP_ID}/policies" "${POLICY_BODY}")
  POLICY_SUCCESS=$(echo "${POLICY_RESULT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('success') else d.get('errors',[{}])[0].get('message','fail'))" 2>/dev/null || echo "fail")
  if [[ "${POLICY_SUCCESS}" != "ok" ]]; then
    die "Access policy creation failed: ${POLICY_SUCCESS}"
  fi
  POLICY_ID=$(echo "${POLICY_RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['id'])" 2>/dev/null || true)
  ok "Access policy created (ID: ${POLICY_ID})"
fi

echo ""
echo "=== Step 5: Restart tunnel ==="
if systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null; then
  systemctl restart "${SVC_NAME}"
  ok "Tunnel restarted."
elif command -v cloudflared >/dev/null 2>&1 && [[ -f "${CONFIG_FILE}" ]]; then
  warn "Service ${SVC_NAME} not running. Start it with: sudo systemctl start ${SVC_NAME}"
else
  warn "cloudflared not found or no config — tunnel config saved but not running."
fi

echo ""
echo "=============================================="
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "  Domain:  https://${HOSTNAME}/nc/"
echo "  Tunnel:  ${TUNNEL_NAME}"
echo "  Access:  Restricted to jon@splippers.com"
echo ""
echo "To add additional users (manual):"
echo "  Visit https://dash.teams.cloudflare.com/"
echo "  → nervecentre.splippers.com → Policies"
echo "  → Add email to 'Allowed users' policy"
echo ""
echo "Or via API:"
echo "  ./deploy/charkive/add-cf-user.sh <email>"
echo "=============================================="
