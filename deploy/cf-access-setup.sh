#!/usr/bin/env bash
# cf-access-setup.sh — Create Cloudflare Access applications for all exposed tunnels.
# Requires a token with: Account>Access:Edit, Account>Tunnel:Edit, Zone>DNS:Edit, Zone>Zone:Read
#
# Usage:  CF_TOKEN=<token> bash cf-access-setup.sh
#
set -euo pipefail

TOKEN_FILE="/home/jon/.cloudflared/cf-admin.token"
if [[ -z "${CF_TOKEN:-}" && -f "$TOKEN_FILE" ]]; then
  CF_TOKEN="$(cat "$TOKEN_FILE")"
fi
CF_TOKEN="${CF_TOKEN:?No token found. Run: echo '<token>' > $TOKEN_FILE}"
ALLOWED_EMAIL="jon@splippers.com"

# ── helpers ──────────────────────────────────────────────────────────────────

cf() {
  local method="$1" path="$2"; shift 2
  curl -sS -X "$method" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/$path" "$@"
}

check() {
  local res="$1" label="$2"
  if echo "$res" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('success') else 1)" 2>/dev/null; then
    echo "  OK  $label"
  else
    echo "  ERR $label: $(echo "$res" | python3 -c "import sys,json; print(json.load(sys.stdin).get('errors','?'))" 2>/dev/null)"
    return 1
  fi
}

# ── resolve account ID ────────────────────────────────────────────────────────

echo "==> Resolving account..."
ACCOUNT_ID=$(cf GET "accounts" | python3 -c "
import sys,json
d=json.load(sys.stdin)
accs = d.get('result',[])
if not accs: raise SystemExit('No accounts found')
print(accs[0]['id'])
")
echo "    Account: $ACCOUNT_ID"

# ── resolve Google IdP ID (first Google OAuth IdP found) ─────────────────────

echo "==> Resolving Identity Provider..."
GOOGLE_IDP_ID=$(cf GET "accounts/$ACCOUNT_ID/access/identity_providers" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for idp in d.get('result',[]):
    if idp.get('type') in ('google','google-apps','oidc'):
        print(idp['id']); break
" 2>/dev/null || echo "")

if [[ -z "$GOOGLE_IDP_ID" ]]; then
  echo "  WARN No Google IdP found — policies will use 'bypass' for IdP; add Google manually in Access > Settings > Authentication."
  IDP_CLAUSE=""
else
  echo "    IdP: $GOOGLE_IDP_ID"
  IDP_CLAUSE=", \"identity_provider_id\": \"$GOOGLE_IDP_ID\""
fi

# ── create_app <name> <hostname> [<path>] ─────────────────────────────────────
# Creates an Access app + an Allow policy for $ALLOWED_EMAIL.

create_app() {
  local name="$1" hostname="$2" path="${3:-}"
  local domain="${hostname}${path}"
  echo ""
  echo "--> $name  ($domain)"

  # Create the Access application
  APP=$(cf POST "accounts/$ACCOUNT_ID/access/apps" -d "{
    \"name\": \"$name\",
    \"domain\": \"$domain\",
    \"type\": \"self_hosted\",
    \"session_duration\": \"24h\",
    \"auto_redirect_to_identity\": true,
    \"http_only_cookie_attribute\": true,
    \"same_site_cookie_attribute\": \"strict\"
  }")
  check "$APP" "create app"
  APP_ID=$(echo "$APP" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['id'])")

  # Create Allow policy: email match
  POL=$(cf POST "accounts/$ACCOUNT_ID/access/apps/$APP_ID/policies" -d "{
    \"name\": \"Owner only\",
    \"decision\": \"allow\",
    \"precedence\": 1,
    \"include\": [{
      \"email\": {\"email\": \"$ALLOWED_EMAIL\"}$IDP_CLAUSE
    }]
  }")
  check "$POL" "create policy"
}

# ── applications ──────────────────────────────────────────────────────────────
# Hostname map verified from live tunnel configs on 2026-05-19.

echo ""
echo "==> Creating Access applications..."

# hyit.io suite (tunnel 51509067) — all → localhost:9000 except cp → 9001
create_app "hyit — root"          "hyit.io"
create_app "hyit — www"           "www.hyit.io"
create_app "hyit — core"          "core.hyit.io"
create_app "hyit — finance"       "finance.hyit.io"
create_app "hyit — ops"           "ops.hyit.io"
create_app "hyit — rnd"           "rnd.hyit.io"
create_app "hyit — brain"         "brain.hyit.io"
create_app "hyit — control plane" "cp.hyit.io"

# NerveCentre + Albert Freethy archive (tunnel 62e68144) → localhost:80
create_app "NerveCentre"                  "nc.splippers.com"
create_app "Albert Freethy Archive"       "albertedwinfreethy.org"
create_app "Albert Freethy Archive (www)" "www.albertedwinfreethy.org"

# monya tunnel (7396119a): ingest.project6x7.com → localhost:8080
# monya.splippers.com (Ollama) was removed from tunnel on 2026-05-19 — security risk.
# splippers.com / www.splippers.com → Marvin's machine, intentionally public.
create_app "Project6x7 Ingest" "ingest.project6x7.com"

# NOTE: thepermanentway.uk intentionally ungated (public SaaS).
# NOTE: splippers.com / www.splippers.com intentionally public (main site, Marvin's machine).

echo ""
echo "==> Done. Visit https://one.dash.cloudflare.com/$ACCOUNT_ID/access/apps to review."
echo "    If no Google IdP was found, add one at: Access > Settings > Authentication > Add new."
