#!/usr/bin/env bash
# Install the Survey Portal (Flask) — add ideas/context to existing projects.
# Registers as systemd service on port 8086 (configurable via SURVEY_PORTAL_PORT).
#
# Usage:
#   sudo ./deploy/surveyportal/install-surveyportal.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="survey-portal"
SURVEY_PORTAL_PORT="${SURVEY_PORTAL_PORT:-8086}"
USER="${SUDO_USER:-jon}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

pip3 install flask --quiet 2>/dev/null || true

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Survey Portal — add ideas and context to projects
After=network-online.target

[Service]
Type=simple
User=${USER}
ExecStart=$(which python3) ${ROOT}/surveyportal.py
Restart=on-failure
RestartSec=5
Environment=SURVEY_PORTAL_PORT=${SURVEY_PORTAL_PORT}
Environment=PROJECTS_ROOT=/mnt/EDDIE-SANDIEGO/Projects
Environment=SURVEY_DATA_DIR=/home/${USER}/.surveyportal
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=${ROOT}

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
systemctl restart "${SERVICE_NAME}.service"

echo "Survey Portal installed:"
echo "  Service: ${SERVICE_NAME}.service"
echo "  Port:    ${SURVEY_PORTAL_PORT}"
echo "  URL:     http://$(hostname -I 2>/dev/null | awk '{print $1}'):${SURVEY_PORTAL_PORT}/"
