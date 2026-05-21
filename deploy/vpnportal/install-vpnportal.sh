#!/usr/bin/env bash
# Install the VPN Portal (Flask WireGuard manager) on the LAN.
# Registers as systemd service on port 8084 (configurable via VPN_PORTAL_PORT).
#
# Usage:
#   sudo ./deploy/vpnportal/install-vpnportal.sh
#
# Env overrides:
#   VPN_PORTAL_PORT=8084   # Web UI port
#   WG_CONTAINER=wireguard  # Docker container name
#   WG_CONF_PATH=/home/jon/Projects/docker-wireguard/config
#   WG_ENDPOINT=splippers.hopto.org:51820
#   WG_SERVER_PUBKEY=fYRDkIU2FeM254nZq8A6UVa4YMiahndPTOaRa6uFjA0=
#   WG_SUBNET=10.13.13
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTAL_DIR="${ROOT}"
SERVICE_NAME="vpn-portal"

VPN_PORTAL_PORT="${VPN_PORTAL_PORT:-8084}"
WG_CONTAINER="${WG_CONTAINER:-wireguard}"
WG_CONF_PATH="${WG_CONF_PATH:-/home/jon/Projects/docker-wireguard/config}"
WG_ENDPOINT="${WG_ENDPOINT:-splippers.hopto.org:51820}"
WG_SERVER_PUBKEY="${WG_SERVER_PUBKEY:-fYRDkIU2FeM254nZq8A6UVa4YMiahndPTOaRa6uFjA0=}"
WG_SUBNET="${WG_SUBNET:-10.13.13}"
WG_DNS="${WG_DNS:-1.1.1.1}"
USER="${SUDO_USER:-jon}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# Install deps
pip3 install flask qrcode[pil] --quiet 2>/dev/null || true

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=VPN Portal — WireGuard peer management
After=network-online.target docker.service
Wants=docker.service

[Service]
Type=simple
User=${USER}
ExecStart=$(which python3) ${PORTAL_DIR}/vpnportal.py
Restart=on-failure
RestartSec=5
Environment=VPN_PORTAL_PORT=${VPN_PORTAL_PORT}
Environment=WG_CONTAINER=${WG_CONTAINER}
Environment=WG_CONF_PATH=${WG_CONF_PATH}
Environment=WG_ENDPOINT=${WG_ENDPOINT}
Environment=WG_SERVER_PUBKEY=${WG_SERVER_PUBKEY}
Environment=WG_SUBNET=${WG_SUBNET}
Environment=WG_DNS=${WG_DNS}
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=${PORTAL_DIR}

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

echo "VPN Portal installed:"
echo "  Service: ${SERVICE_NAME}.service"
echo "  Port:    ${VPN_PORTAL_PORT}"
echo "  URL:     http://$(hostname -I 2>/dev/null | awk '{print $1}'):${VPN_PORTAL_PORT}/"
echo "  Endpoint: ${WG_ENDPOINT}"
echo "  Peers:   ${WG_CONF_PATH}/peer_*/"
