#!/usr/bin/env bash
# Install the CF Tunnel Setup Portal.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cf-portal"
CFPORTAL_PORT="${CFPORTAL_PORT:-8085}"
USER="${SUDO_USER:-jon}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=CF Tunnel Setup Portal — guided cloudflared deployment
After=network-online.target

[Service]
Type=simple
User=${USER}
ExecStart=$(which python3) ${ROOT}/cfportal.py
Restart=on-failure
RestartSec=5
Environment=CFPORTAL_PORT=${CFPORTAL_PORT}
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=${ROOT}

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

echo "CF Portal installed: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${CFPORTAL_PORT}/"
