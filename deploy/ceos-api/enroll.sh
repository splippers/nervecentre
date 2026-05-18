#!/usr/bin/env bash
# Enroll CEOS 4.0 API into the Splippers stack.
# Installs a systemd service (ceos-api) that runs uvicorn on CEOS_API_PORT (default 8004).
#
# Usage from NerveCentre root:
#   sudo ./deploy/ceos-api/enroll.sh
#
# Environment:
#   CEOS_SRC       Path to ceo-simulator repo (default: sibling ../ceo-simulator of this NerveCentre checkout)
#   CEOS_USER      Service user (default: SUDO_USER, or current user)
#   CEOS_API_PORT  Listen port (default: 8004)
#   CEOS_VENV      Path to Python venv (default: CEOS_SRC/venv — created if missing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NERVECENTRE="$(cd "$SCRIPT_DIR/../.." && pwd)"
CEOS_SRC="${CEOS_SRC:-$(dirname "$NERVECENTRE")/ceo-simulator}"
CEOS_API_PORT="${CEOS_API_PORT:-8004}"
CEOS_USER="${CEOS_USER:-${SUDO_USER:-$(id -un)}}"
CEOS_VENV="${CEOS_VENV:-${CEOS_SRC}/venv}"
SERVICE_NAME="ceos-api"

die() { echo "enroll.sh: $*" >&2; exit 1; }

[[ -d "${CEOS_SRC}" ]] || die "No ceo-simulator at ${CEOS_SRC} — clone it or set CEOS_SRC."
[[ -f "${CEOS_SRC}/requirements.txt" ]] || die "Missing requirements.txt in ${CEOS_SRC}."

echo "==> NerveCentre enroll: CEOS 4.0 API"
echo "    Repo:    ${CEOS_SRC}"
echo "    User:    ${CEOS_USER}"
echo "    Port:    ${CEOS_API_PORT}"
echo "    Venv:    ${CEOS_VENV}"

# Create venv and install if not already done
if [[ ! -f "${CEOS_VENV}/bin/uvicorn" ]]; then
  echo "==> Creating Python venv at ${CEOS_VENV}..."
  python3 -m venv "${CEOS_VENV}"
  "${CEOS_VENV}/bin/pip" install --quiet --upgrade pip
  "${CEOS_VENV}/bin/pip" install --quiet -r "${CEOS_SRC}/requirements.txt"
  echo "    Dependencies installed."
else
  echo "    Venv already exists — skipping pip install. Run manually if requirements changed:"
  echo "    ${CEOS_VENV}/bin/pip install -r ${CEOS_SRC}/requirements.txt"
fi

# Generate a JWT secret if ceos.env doesn't have one
CEOS_ENV="${CEOS_SRC}/ceos.env"
if [[ ! -f "${CEOS_ENV}" ]]; then
  JWT_SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  cat > "${CEOS_ENV}" <<ENV
CEOS_NODE_ID=ceos-node-eddie
CEOS_EVENT_BUS=memory
CEOS_JWT_SECRET=${JWT_SECRET}
CEOS_ALLOWED_EMAILS=
CEOS_DATA_DIR=${CEOS_SRC}/data/ceos
CEOS_LOG_LEVEL=INFO
CEOS_TICK_SECONDS=60
ENV
  chown "${CEOS_USER}:${CEOS_USER}" "${CEOS_ENV}" 2>/dev/null || true
  chmod 600 "${CEOS_ENV}"
  echo "    Generated ${CEOS_ENV} — add GOOGLE_CLIENT_ID/SECRET and CEOS_ALLOWED_EMAILS to enable OAuth."
fi

mkdir -p "${CEOS_SRC}/data/ceos"
chown -R "${CEOS_USER}:" "${CEOS_SRC}/data" 2>/dev/null || true

# Write systemd unit
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
cat > "${UNIT_FILE}" <<UNIT
[Unit]
Description=CEOS 4.0 API (uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CEOS_USER}
WorkingDirectory=${CEOS_SRC}
EnvironmentFile=${CEOS_ENV}
ExecStart=${CEOS_VENV}/bin/uvicorn ceos.app:app --host 127.0.0.1 --port ${CEOS_API_PORT} --workers 2
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo ""
echo "==> CEOS 4.0 API enrolled."
echo "    Status:  sudo systemctl status ${SERVICE_NAME}"
echo "    Logs:    sudo journalctl -u ${SERVICE_NAME} -f"
echo "    Local:   http://127.0.0.1:${CEOS_API_PORT}/health"
echo "    Portal:  http://192.168.1.1/ceos-api/docs"
echo ""
echo "    Then re-run install-portal.sh to wire it into nginx:"
echo "    sudo CEOS_API_PORT=${CEOS_API_PORT} ./deploy/portal/install-portal.sh"
