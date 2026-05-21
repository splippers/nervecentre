#!/usr/bin/env bash
# enroll-cf-token.sh — Save a Cloudflare API token and immediately run Access setup.
#
# Usage:
#   bash enroll-cf-token.sh <token>
#
# The token needs these permissions:
#   Account > Cloudflare Access : Edit
#   Account > Cloudflare Tunnel : Edit
#   Zone    > DNS               : Edit
#   Zone    > Zone              : Read
#   Zone Resource: All zones
#
set -euo pipefail

TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
  echo "Usage: bash enroll-cf-token.sh <cf-api-token>" >&2
  exit 1
fi

TOKEN_FILE="/home/jon/.cloudflared/cf-admin.token"
echo "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
echo "Token saved to $TOKEN_FILE"

SETUP="$(dirname "$0")/cf-access-setup.sh"
if [[ -f "$SETUP" ]]; then
  echo "Running Access setup..."
  bash "$SETUP"
else
  echo "cf-access-setup.sh not found alongside this script — run it manually."
fi
