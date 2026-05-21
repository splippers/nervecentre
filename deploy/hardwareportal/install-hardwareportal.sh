#!/usr/bin/env bash
# Install the Hardware Resources Portal (Flask) — fleet inventory, load monitoring.
# Registers as systemd service on port 8088 (configurable via HW_PORTAL_PORT).
#
# Usage:
#   sudo ./deploy/hardwareportal/install-hardwareportal.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="hardware-portal"
HW_PORTAL_PORT="${HW_PORTAL_PORT:-8088}"
USER="${SUDO_USER:-jon}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

pip3 install flask --quiet 2>/dev/null || true

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Hardware Resources Portal — fleet, load, bottlenecks
After=network-online.target

[Service]
Type=simple
User=${USER}
ExecStart=$(which python3) ${ROOT}/hardwareportal.py
Restart=on-failure
RestartSec=5
Environment=HW_PORTAL_PORT=${HW_PORTAL_PORT}
Environment=HW_DATA_DIR=/home/${USER}/.hardwareportal
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=${ROOT}

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

echo "Hardware Resources Portal installed:"
echo "  Service: ${SERVICE_NAME}.service"
echo "  Port:    ${HW_PORTAL_PORT}"
echo "  URL:     http://$(hostname -I 2>/dev/null | awk '{print $1}'):${HW_PORTAL_PORT}/"
