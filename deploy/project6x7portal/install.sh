#!/usr/bin/env bash
# Set up Cloudflare Tunnel + Access (ADFS/OIDC) for portal.project6x7.com → localhost:80.
#
# What this does:
#   1. Creates a named Cloudflare Tunnel via the CF REST API.
#   2. Writes /etc/cloudflared/project6x7.yml (config) and project6x7-creds.json (credentials).
#   3. Creates the DNS CNAME portal.project6x7.com → <tunnel-id>.cfargotunnel.com.
#   4. Registers ADFS as a Cloudflare Access OIDC identity provider.
#   5. Creates a Cloudflare Access application + policy for portal.project6x7.com.
#   6. Installs and starts a systemd service (cloudflared-project6x7).
#
# ADFS prerequisites (do these in ADFS before running this script):
#   1. Open ADFS Management → Application Groups → Add Application Group.
#   2. Choose "Server application accessing a web API" template.
#   3. Note the generated Client ID (you'll set OIDC_CLIENT_ID from this).
#   4. Generate a client secret and note it (OIDC_CLIENT_SECRET).
#   5. Add redirect URI: https://portal.project6x7.com/cdn-cgi/access/callback
#   6. In the Web API identifier field, put the same Client ID.
#   7. Under "Permitted scopes" add: openid, profile, email (or allatclaims for UPN).
#   8. Ensure your ADFS Federation Service is published publicly via WAP/ADFS Proxy
#      so Cloudflare can reach https://ADFS_URL/adfs/.well-known/openid-configuration.
#
# Required environment variables:
#   CF_API_TOKEN        Cloudflare API token (see permissions below)
#   CF_ACCOUNT_ID       Cloudflare account ID (dashboard → right sidebar)
#   CF_ZONE_ID          Zone ID for project6x7.com (dashboard → zone overview sidebar)
#   ADFS_URL            Public ADFS base URL, e.g. https://adfs.corp.com
#   OIDC_CLIENT_ID      Client ID from the ADFS Application Group
#   OIDC_CLIENT_SECRET  Client secret from the ADFS Application Group
#
# Optional:
#   TUNNEL_NAME              default: project6x7-portal
#   BACKEND                  default: http://localhost:80
#   ACCESS_ALLOW_DOMAIN      email domain to allow (e.g. corp.com); required unless ACCESS_ALLOW_GROUP is set
#   ACCESS_ALLOW_GROUP       ADFS group name/SID to restrict access; takes precedence if both set
#   ACCESS_IDP_NAME          display name for the IdP entry (default: "Corporate ADFS")
#   ACCESS_APP_NAME          display name for the Access app (default: "Project6x7 Portal")
#   ACCESS_SESSION_DURATION  e.g. 24h (default: 8h)
#   OIDC_SCOPES              space-separated, default: "openid profile email"
#   TUNNEL_DIR               default: /etc/cloudflared
#   CLOUDFLARED_BIN          default: auto-detected
#   SERVICE_USER             systemd service user (default: SUDO_USER or current user)
#
# API token permissions needed:
#   Account > Cloudflare Tunnel: Edit
#   Zone (project6x7.com) > DNS: Edit
#   Account > Access: Apps and Policies: Edit
#   Account > Access: Identity Providers: Edit
#
# Usage:
#   export CF_API_TOKEN=...  CF_ACCOUNT_ID=...  CF_ZONE_ID=...
#   export ADFS_URL=https://adfs.corp.com
#   export OIDC_CLIENT_ID=...  OIDC_CLIENT_SECRET=...
#   export ACCESS_ALLOW_DOMAIN=corp.com
#   sudo -E ./deploy/project6x7portal/install.sh

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────

TUNNEL_NAME="${TUNNEL_NAME:-project6x7-portal}"
HOSTNAME="portal.project6x7.com"
BACKEND="${BACKEND:-http://localhost:80}"

CF_API_TOKEN="${CF_API_TOKEN:?Set CF_API_TOKEN}"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:?Set CF_ACCOUNT_ID}"
CF_ZONE_ID="${CF_ZONE_ID:?Set CF_ZONE_ID (zone ID for project6x7.com)}"

ADFS_URL="${ADFS_URL:?Set ADFS_URL (e.g. https://adfs.corp.com)}"
ADFS_URL="${ADFS_URL%/}"  # strip trailing slash
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:?Set OIDC_CLIENT_ID (from ADFS Application Group)}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:?Set OIDC_CLIENT_SECRET}"
OIDC_SCOPES="${OIDC_SCOPES:-openid profile email}"

ACCESS_ALLOW_DOMAIN="${ACCESS_ALLOW_DOMAIN:-}"
ACCESS_ALLOW_GROUP="${ACCESS_ALLOW_GROUP:-}"
ACCESS_IDP_NAME="${ACCESS_IDP_NAME:-Corporate ADFS}"
ACCESS_APP_NAME="${ACCESS_APP_NAME:-Project6x7 Portal}"
ACCESS_SESSION_DURATION="${ACCESS_SESSION_DURATION:-8h}"

TUNNEL_DIR="${TUNNEL_DIR:-/etc/cloudflared}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-$(command -v cloudflared 2>/dev/null || echo /usr/local/bin/cloudflared)}"
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo nobody)}}"
SERVICE_NAME="cloudflared-project6x7"
CREDS_FILE="${TUNNEL_DIR}/project6x7-creds.json"
CONFIG_FILE="${TUNNEL_DIR}/project6x7.yml"

# Derive ADFS OIDC endpoints from ADFS_URL
OIDC_AUTH_URL="${ADFS_URL}/adfs/oauth2/authorize"
OIDC_TOKEN_URL="${ADFS_URL}/adfs/oauth2/token"
OIDC_CERTS_URL="${ADFS_URL}/adfs/discovery/keys"

# ── guards ────────────────────────────────────────────────────────────────────

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo -E ./install.sh to preserve env vars)." >&2
  exit 1
fi

if [[ ! -x "$CLOUDFLARED_BIN" ]]; then
  echo "cloudflared not found at $CLOUDFLARED_BIN" >&2
  exit 1
fi

if [[ -z "$ACCESS_ALLOW_DOMAIN" && -z "$ACCESS_ALLOW_GROUP" ]]; then
  echo "Set ACCESS_ALLOW_DOMAIN (e.g. corp.com) or ACCESS_ALLOW_GROUP (ADFS group name)." >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
command -v openssl  >/dev/null 2>&1 || { echo "openssl required" >&2; exit 1; }
command -v curl     >/dev/null 2>&1 || { echo "curl required" >&2; exit 1; }

# Verify ADFS discovery endpoint is reachable before committing any changes
echo "==> Checking ADFS discovery endpoint..."
DISC_URL="${ADFS_URL}/adfs/.well-known/openid-configuration"
if ! curl -sf --max-time 10 "$DISC_URL" >/dev/null; then
  echo "Cannot reach $DISC_URL" >&2
  echo "Ensure ADFS is published publicly via WAP/ADFS Proxy and reachable from this machine." >&2
  exit 1
fi
echo "    OK: $DISC_URL"

# ── helpers ───────────────────────────────────────────────────────────────────

CF_API="https://api.cloudflare.com/client/v4"

cf_post() {
  curl -sS -X POST "${CF_API}/${1}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${2}"
}

jq_field() {
  python3 -c "import sys,json; print(json.load(sys.stdin)${1})"
}

check_success() {
  local resp="$1" label="$2"
  local ok
  ok=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success',''))")
  if [[ "$ok" != "True" ]]; then
    echo "FAILED: $label" >&2
    echo "$resp" | python3 -m json.tool >&2
    exit 1
  fi
}

mkdir -p "$TUNNEL_DIR"

# ── step 1: create tunnel ─────────────────────────────────────────────────────

echo
echo "==> [1/6] Creating tunnel: ${TUNNEL_NAME}"

TUNNEL_SECRET=$(openssl rand -base64 32)

TUNS_RESP=$(cf_post "accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
  "{\"name\":\"${TUNNEL_NAME}\",\"tunnel_secret\":\"${TUNNEL_SECRET}\"}")
check_success "$TUNS_RESP" "create tunnel"

TUNNEL_ID=$(echo "$TUNS_RESP" | jq_field "['result']['id']")
echo "    Tunnel ID: ${TUNNEL_ID}"

# ── step 2: write credentials + config ────────────────────────────────────────

echo
echo "==> [2/6] Writing cloudflared config"

python3 - <<PYCREDS
import json, pathlib
creds = {
    "AccountTag":   "${CF_ACCOUNT_ID}",
    "TunnelID":     "${TUNNEL_ID}",
    "TunnelName":   "${TUNNEL_NAME}",
    "TunnelSecret": "${TUNNEL_SECRET}",
}
p = pathlib.Path("${CREDS_FILE}")
p.write_text(json.dumps(creds, indent=2))
p.chmod(0o600)
print(f"    Credentials: {p}")
PYCREDS

cat > "${CONFIG_FILE}" <<YAMLEOF
tunnel: ${TUNNEL_NAME}
credentials-file: ${CREDS_FILE}

ingress:
  - hostname: ${HOSTNAME}
    service: ${BACKEND}
  - service: http_status:404
YAMLEOF
chmod 0644 "${CONFIG_FILE}"
echo "    Config: ${CONFIG_FILE}"

# ── step 3: DNS CNAME ─────────────────────────────────────────────────────────

echo
echo "==> [3/6] Creating DNS CNAME: ${HOSTNAME} → ${TUNNEL_ID}.cfargotunnel.com"

DNS_RESP=$(cf_post "zones/${CF_ZONE_ID}/dns_records" \
  "{\"type\":\"CNAME\",\"name\":\"${HOSTNAME}\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}")
check_success "$DNS_RESP" "create DNS CNAME"
echo "    DNS record created (proxied)"

# ── step 4: Cloudflare Access OIDC identity provider (ADFS) ──────────────────

echo
echo "==> [4/6] Registering ADFS as OIDC identity provider: ${ACCESS_IDP_NAME}"

IDP_BODY=$(python3 -c "
import json
scopes = '${OIDC_SCOPES}'.split()
body = {
    'name': '${ACCESS_IDP_NAME}',
    'type': 'oidc',
    'config': {
        'client_id':     '${OIDC_CLIENT_ID}',
        'client_secret': '${OIDC_CLIENT_SECRET}',
        'auth_url':      '${OIDC_AUTH_URL}',
        'token_url':     '${OIDC_TOKEN_URL}',
        'certs_url':     '${OIDC_CERTS_URL}',
        'scopes':        scopes,
    },
}
print(json.dumps(body))
")

IDP_RESP=$(cf_post "accounts/${CF_ACCOUNT_ID}/access/identity_providers" "$IDP_BODY")
check_success "$IDP_RESP" "create OIDC identity provider"
IDP_ID=$(echo "$IDP_RESP" | jq_field "['result']['id']")
echo "    IdP ID: ${IDP_ID}"

# ── step 5: Access application + policy ───────────────────────────────────────

echo
echo "==> [5/6] Creating Cloudflare Access application: ${ACCESS_APP_NAME}"

APP_BODY=$(python3 -c "
import json
body = {
    'name':             '${ACCESS_APP_NAME}',
    'domain':           '${HOSTNAME}',
    'type':             'self_hosted',
    'session_duration': '${ACCESS_SESSION_DURATION}',
    'allowed_idps':     ['${IDP_ID}'],
    'auto_redirect_to_identity': True,
}
print(json.dumps(body))
")

APP_RESP=$(cf_post "accounts/${CF_ACCOUNT_ID}/access/apps" "$APP_BODY")
check_success "$APP_RESP" "create Access application"
APP_ID=$(echo "$APP_RESP" | jq_field "['result']['uid']")
echo "    App ID: ${APP_ID}"

echo
echo "==> [5b/6] Creating Access policy"

POLICY_INCLUDE=$(python3 -c "
import json
group = '${ACCESS_ALLOW_GROUP}'
domain = '${ACCESS_ALLOW_DOMAIN}'
if group:
    # Match on the OIDC groups claim sent by ADFS
    rule = [{'oidc': {'claim_name': 'groups', 'claim_value': group}}]
else:
    rule = [{'email_domain': {'domain': domain}}]
print(json.dumps(rule))
")

POLICY_BODY=$(python3 -c "
import json, sys
include = json.load(sys.stdin)
body = {
    'name':     'AD Users',
    'decision': 'allow',
    'include':  include,
}
print(json.dumps(body))
" <<< "${POLICY_INCLUDE}")

POLICY_RESP=$(cf_post "accounts/${CF_ACCOUNT_ID}/access/apps/${APP_ID}/policies" "$POLICY_BODY")
check_success "$POLICY_RESP" "create Access policy"
echo "    Policy created"

# ── step 6: systemd service ───────────────────────────────────────────────────

echo
echo "==> [6/6] Installing systemd service: ${SERVICE_NAME}"

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=Cloudflare Tunnel — ${TUNNEL_NAME} (portal.project6x7.com)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
ExecStart=${CLOUDFLARED_BIN} tunnel --config ${CONFIG_FILE} --no-autoupdate run
Restart=on-failure
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
SVCEOF

chown "${SERVICE_USER}:" "${CREDS_FILE}" "${CONFIG_FILE}"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

# ── done ──────────────────────────────────────────────────────────────────────

echo
echo "Done."
echo
echo "  Tunnel:     ${TUNNEL_NAME} (${TUNNEL_ID})"
echo "  Config:     ${CONFIG_FILE}"
echo "  Creds:      ${CREDS_FILE}"
echo "  Service:    ${SERVICE_NAME} ($(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo unknown))"
echo "  URL:        https://${HOSTNAME}/"
echo "  Backend:    ${BACKEND}"
echo "  IdP:        ${ACCESS_IDP_NAME} (${IDP_ID})"
echo "  ADFS:       ${ADFS_URL}"
echo "  Access app: ${ACCESS_APP_NAME} (${APP_ID})"
echo
if [[ -n "${ACCESS_ALLOW_GROUP}" ]]; then
  echo "  Policy:     allow OIDC groups claim = ${ACCESS_ALLOW_GROUP}"
else
  echo "  Policy:     allow email domain = ${ACCESS_ALLOW_DOMAIN}"
fi
echo
echo "  ADFS reminder: ensure the redirect URI is registered in ADFS:"
echo "    https://${HOSTNAME}/cdn-cgi/access/callback"
echo
echo "  Check tunnel: systemctl status ${SERVICE_NAME}"
echo "  Logs:         journalctl -u ${SERVICE_NAME} -f"
