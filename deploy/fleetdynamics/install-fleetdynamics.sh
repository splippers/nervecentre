#!/usr/bin/env bash
# Install the Fleet Dynamics Portal (Flask) — live fleet health, cough tests, invitations.
# Registers as systemd service on port 8089 (configurable via FD_PORTAL_PORT).
#
# Usage:
#   sudo ./deploy/fleetdynamics/install-fleetdynamics.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="fleetdynamics-portal"
FD_PORTAL_PORT="${FD_PORTAL_PORT:-8089}"
USER="${SUDO_USER:-jon}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

pip3 install flask --quiet 2>/dev/null || true

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Fleet Dynamics Portal — live health, cough tests, invitations
After=network-online.target

[Service]
Type=simple
User=${USER}
ExecStart=$(which python3) ${ROOT}/fleetdynamics.py
Restart=on-failure
RestartSec=5
Environment=FD_PORTAL_PORT=${FD_PORTAL_PORT}
Environment=FD_DATA_DIR=/home/${USER}/.fleetdynamics
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=${ROOT}

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

echo "Fleet Dynamics Portal installed:"
echo "  Service: ${SERVICE_NAME}.service"
echo "  Port:    ${FD_PORTAL_PORT}"
echo "  URL:     http://$(hostname -I 2>/dev/null | awk '{print $1}'):${FD_PORTAL_PORT}/"
