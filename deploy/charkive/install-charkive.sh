#!/usr/bin/env bash
# Install Charkive web dashboard as a systemd service.
# Default port 8082 — configurable via CHARKIVE_PORT.
#
# Usage:
#   sudo ./deploy/charkive/install-charkive.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECTS="$(cd "${ROOT}/../.." && pwd)"
CHARKYVE="${PROJECTS}/charkyve"
SERVICE_NAME="charkive-web"
CHARKIVE_PORT="${CHARKIVE_PORT:-8082}"
USER="${SUDO_USER:-jon}"
VENV="${CHARKYVE}/.venv"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if [[ ! -d "${CHARKYVE}" ]]; then
  echo "Charkyve project not found at ${CHARKYVE}" >&2
  exit 1
fi

# Ensure venv exists with web extras
if [[ ! -x "${VENV}/bin/charkive" ]]; then
  echo "Creating venv at ${VENV}"
  python3 -m venv "${VENV}"
  "${VENV}/bin/pip" install -U pip wheel
  "${VENV}/bin/pip" install -e "${CHARKYVE}[web]"
else
  echo "Refreshing venv deps"
  "${VENV}/bin/pip" install -U pip wheel
  "${VENV}/bin/pip" install -e "${CHARKYVE}[web]"
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CHARKYVE_YML="${CHARKYVE}/.charkive.yml"

cat > "${SERVICE_FILE}" <<SERVICE
[Unit]
Description=Charkive Web — SAN fluff dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${CHARKYVE}
ExecStart=${VENV}/bin/charkive web --host 127.0.0.1 --port ${CHARKIVE_PORT}${CHARKYVE_YML:+ --config ${CHARKYVE_YML}}
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

echo "Charkive Web installed:"
echo "  Service: ${SERVICE_NAME}.service"
echo "  Port:    ${CHARKIVE_PORT}"
echo "  URL:     http://127.0.0.1:${CHARKIVE_PORT}/"
  echo "  Portal:  https://nervecentre.splippers.com/nc/charkive/"
  echo "  Portal:  http://192.168.1.1/nc/charkive/"
