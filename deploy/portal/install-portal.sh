#!/usr/bin/env bash
# Install the Splippers unified web portal from NerveCentre (nginx, port 80).
# Host-agnostic: Brickwise can load-balance across multiple backends (e.g. Eddie + Marvin).
#
# Brickwise / Archive / SIC / Monyatron / Jonotron / CEO-Simulator / Deanotron / Projects / WorkAdventure: 8756 / 8000 / 8787 / 5050 / 8011 / 8080 / 8791 / 8765 / (WA: see WORKADVENTURE_*).
#
# Usage (from repo checkout):
#   sudo ./deploy/portal/install-portal.sh
#
# Load-balanced Brickwise (same port on each Gluster node):
#   sudo BRICKWISE_BACKENDS="10.0.0.1:8756 10.0.0.2:8756" ./deploy/portal/install-portal.sh
#
# Archive or SIC only on one node — pin redirects (optional):
#   sudo ARCHIVE_REDIRECT_HOST=eddie.lan SIC_REDIRECT_HOST=eddie.lan ./deploy/portal/install-portal.sh
#
# Replicated Archive + SIC (Marvin + Eddie) — reverse-proxy under /nc/archive/ and /nc/sic/ instead of redirects:
#   sudo ARCHIVE_BACKENDS="10.0.0.1:8000 10.0.0.2:8000" \
#        SIC_BACKENDS="10.0.0.1:8787 10.0.0.2:8787" ./deploy/portal/install-portal.sh
# When ARCHIVE_BACKENDS / SIC_BACKENDS are unset, portal uses HTTP redirects to :ARCHIVE_PORT / :SIC_PORT (same as $host).
#
# Monyatron (Flask on Marvin or elsewhere):
#   sudo MONYATRON_BACKENDS="10.0.0.1:5050 10.0.0.2:5050" ./deploy/portal/install-portal.sh
#
# Jonotron (FastAPI harness — default backend 8011 so Splippers Archive can keep 8000):
#   sudo JONOTRON_BACKENDS="10.0.0.1:8011 10.0.0.2:8011" ./deploy/portal/install-portal.sh
#
# CEO-Simulator (Flask central — Framework :8080; default backend 8080):
#   sudo CEO_SIMULATOR_BACKENDS="10.0.0.1:8080" ./deploy/portal/install-portal.sh
#
# Project prioritiser (moneymakers/projectscan.py — default 8765, path /nc/projects/):
#   PROJECTSCAN_BACKENDS unset → proxy to 127.0.0.1:${PROJECTSCAN_PORT}
#
# WorkAdventure (Traefik on host port 9080 by default when NerveCentre owns :80):
#   sudo NERVECENTRE_LAN_IP=192.168.1.1 ./deploy/portal/install-portal.sh
# Redirect becomes http://192.168.1.1:9080/ and a /workadventure-hosts.txt helper is installed.
# Or full URL (302 target), e.g. staging:
#   sudo WORKADVENTURE_URL='https://play.staging.workadventu.re/' ./deploy/portal/install-portal.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BW_PORT="${BW_PORT:-8756}"
ARCHIVE_PORT="${ARCHIVE_PORT:-8000}"
SIC_PORT="${SIC_PORT:-8787}"
# Optional: load-balance Splippers Archive + SIC like Brickwise (strip /archive|/sic prefix toward backends)
ARCHIVE_BACKENDS="${ARCHIVE_BACKENDS:-}"
ARCHIVE_LB_METHOD="${ARCHIVE_LB_METHOD:-least_conn}"
SIC_BACKENDS="${SIC_BACKENDS:-}"
SIC_LB_METHOD="${SIC_LB_METHOD:-least_conn}"
MONYATRON_PORT="${MONYATRON_PORT:-5050}"
# Space-separated host:port list; unset or empty → single backend 127.0.0.1:$BW_PORT
BRICKWISE_BACKENDS="${BRICKWISE_BACKENDS:-}"
# least_conn (default), "", or ip_hash (sticky by client IP)
BRICKWISE_LB_METHOD="${BRICKWISE_LB_METHOD:-least_conn}"
# Space-separated host:port; unset → 127.0.0.1:$MONYATRON_PORT (Marvin local Monyatron)
MONYATRON_BACKENDS="${MONYATRON_BACKENDS:-}"
MONYATRON_LB_METHOD="${MONYATRON_LB_METHOD:-least_conn}"
JONOTRON_PORT="${JONOTRON_PORT:-8011}"
JONOTRON_BACKENDS="${JONOTRON_BACKENDS:-}"
JONOTRON_LB_METHOD="${JONOTRON_LB_METHOD:-least_conn}"
CEO_SIMULATOR_PORT="${CEO_SIMULATOR_PORT:-8080}"
CEO_SIMULATOR_BACKENDS="${CEO_SIMULATOR_BACKENDS:-}"
CEO_SIMULATOR_LB_METHOD="${CEO_SIMULATOR_LB_METHOD:-least_conn}"
CEOS_API_PORT="${CEOS_API_PORT:-8004}"
CEOS_API_BACKENDS="${CEOS_API_BACKENDS:-}"
CEOS_API_LB_METHOD="${CEOS_API_LB_METHOD:-least_conn}"
DEANOTRON_PORT="${DEANOTRON_PORT:-8791}"
CHARKIVE_PORT="${CHARKIVE_PORT:-8082}"
MAIL_PORTAL_PORT="${MAIL_PORTAL_PORT:-8083}"

PORTAL_PREFIX="/nc"
VPN_PORTAL_PORT="${VPN_PORTAL_PORT:-8084}"
SURVEY_PORTAL_PORT="${SURVEY_PORTAL_PORT:-8086}"
AITEAMS_PORTAL_PORT="${AITEAMS_PORTAL_PORT:-8087}"
HW_PORTAL_PORT="${HW_PORTAL_PORT:-8088}"
FD_PORTAL_PORT="${FD_PORTAL_PORT:-8089}"
# WorkAdventure: optional full redirect URL; else NERVECENTRE_LAN_IP + WORKADVENTURE_PORT (Traefik publish port); else *.localhost
NERVECENTRE_LAN_IP="${NERVECENTRE_LAN_IP:-}"
WORKADVENTURE_URL="${WORKADVENTURE_URL:-}"
WORKADVENTURE_PLAY_HOST="${WORKADVENTURE_PLAY_HOST:-play.workadventure.localhost}"
# Host port where WorkAdventure Traefik listens (docker compose reverse-proxy 9080:80).
WORKADVENTURE_PORT="${WORKADVENTURE_PORT:-9080}"
# moneymakers/projectscan.py dashboard (nginx strips /nc/projects/ → backend /)
PROJECTSCAN_PORT="${PROJECTSCAN_PORT:-8765}"
PROJECTSCAN_BACKENDS="${PROJECTSCAN_BACKENDS:-}"
WWW="${WWW:-/var/www/splippers-portal}"
SITE_NAME="${SITE_NAME:-splippers-portal}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
  echo "nginx is not installed. On Debian/Ubuntu: sudo apt install nginx" >&2
  exit 1
fi

generic_lb_upstream_block() {
  local name="$1"
  local backends_list="$2"
  local lb_method="$3"
  local lb="" backends="${backends_list}"

  case "${lb_method}" in
    least_conn) lb="least_conn;" ;;
    ip_hash)    lb="ip_hash;" ;;
    round_robin|"")
      lb=""
      ;;
    *)
      echo "Unknown LB_METHOD=${lb_method} for ${name} (use least_conn, ip_hash, or round_robin)." >&2
      exit 1
      ;;
  esac

  echo "upstream ${name} {"
  if [[ -n "${lb}" ]]; then
    echo "    ${lb}"
  fi
  for be in ${backends}; do
    echo "    server ${be};"
  done
  echo "}"
}

archive_upstream_block() {
  generic_lb_upstream_block nerve_archive "${ARCHIVE_BACKENDS}" "${ARCHIVE_LB_METHOD}"
}

sic_upstream_block() {
  generic_lb_upstream_block nerve_sic "${SIC_BACKENDS}" "${SIC_LB_METHOD}"
}

brickwise_upstream_block() {
  local lb="" backends=""
  if [[ -z "${BRICKWISE_BACKENDS// }" ]]; then
    backends="127.0.0.1:${BW_PORT}"
  else
    backends="${BRICKWISE_BACKENDS}"
  fi

  case "${BRICKWISE_LB_METHOD}" in
    least_conn) lb="least_conn;" ;;
    ip_hash)    lb="ip_hash;" ;;
    round_robin|"")
      lb=""
      ;;
    *)
      echo "Unknown BRICKWISE_LB_METHOD=${BRICKWISE_LB_METHOD} (use least_conn, ip_hash, or round_robin)." >&2
      exit 1
      ;;
  esac

  echo "upstream nerve_brickwise {"
  if [[ -n "${lb}" ]]; then
    echo "    ${lb}"
  fi
  for be in ${backends}; do
    echo "    server ${be};"
  done
  echo "}"
}

monyatron_upstream_block() {
  local lb="" backends=""
  if [[ -z "${MONYATRON_BACKENDS// }" ]]; then
    backends="127.0.0.1:${MONYATRON_PORT}"
  else
    backends="${MONYATRON_BACKENDS}"
  fi

  case "${MONYATRON_LB_METHOD}" in
    least_conn) lb="least_conn;" ;;
    ip_hash)    lb="ip_hash;" ;;
    round_robin|"")
      lb=""
      ;;
    *)
      echo "Unknown MONYATRON_LB_METHOD=${MONYATRON_LB_METHOD} (use least_conn, ip_hash, or round_robin)." >&2
      exit 1
      ;;
  esac

  echo "upstream nerve_monyatron {"
  if [[ -n "${lb}" ]]; then
    echo "    ${lb}"
  fi
  for be in ${backends}; do
    echo "    server ${be};"
  done
  echo "}"
}

projectscan_upstream_block() {
  local backends=""
  if [[ -z "${PROJECTSCAN_BACKENDS// }" ]]; then
    backends="127.0.0.1:${PROJECTSCAN_PORT}"
  else
    backends="${PROJECTSCAN_BACKENDS}"
  fi

  echo "upstream nerve_projectscan {"
  echo "    least_conn;"
  for be in ${backends}; do
    echo "    server ${be};"
  done
  echo "}"
}

jonotron_upstream_block() {
  local lb="" backends=""
  if [[ -z "${JONOTRON_BACKENDS// }" ]]; then
    backends="127.0.0.1:${JONOTRON_PORT}"
  else
    backends="${JONOTRON_BACKENDS}"
  fi

  case "${JONOTRON_LB_METHOD}" in
    least_conn) lb="least_conn;" ;;
    ip_hash)    lb="ip_hash;" ;;
    round_robin|"")
      lb=""
      ;;
    *)
      echo "Unknown JONOTRON_LB_METHOD=${JONOTRON_LB_METHOD} (use least_conn, ip_hash, or round_robin)." >&2
      exit 1
      ;;
  esac

  echo "upstream nerve_jonotron {"
  if [[ -n "${lb}" ]]; then
    echo "    ${lb}"
  fi
  for be in ${backends}; do
    echo "    server ${be};"
  done
  echo "}"
}

ceosimulator_upstream_block() {
  local lb="" backends=""
  if [[ -z "${CEO_SIMULATOR_BACKENDS// }" ]]; then
    backends="127.0.0.1:${CEO_SIMULATOR_PORT}"
  else
    backends="${CEO_SIMULATOR_BACKENDS}"
  fi

  case "${CEO_SIMULATOR_LB_METHOD}" in
    least_conn) lb="least_conn;" ;;
    ip_hash)    lb="ip_hash;" ;;
    round_robin|"")
      lb=""
      ;;
    *)
      echo "Unknown CEO_SIMULATOR_LB_METHOD=${CEO_SIMULATOR_LB_METHOD} (use least_conn, ip_hash, or round_robin)." >&2
      exit 1
      ;;
  esac

  echo "upstream nerve_ceo_simulator {"
  if [[ -n "${lb}" ]]; then
    echo "    ${lb}"
  fi
  for be in ${backends}; do
    echo "    server ${be};"
  done
  echo "}"
}

ceosapi_upstream_block() {
  local lb="" backends=""
  if [[ -z "${CEOS_API_BACKENDS// }" ]]; then
    backends="127.0.0.1:${CEOS_API_PORT}"
  else
    backends="${CEOS_API_BACKENDS}"
  fi

  case "${CEOS_API_LB_METHOD}" in
    least_conn) lb="least_conn;" ;;
    ip_hash)    lb="ip_hash;" ;;
    round_robin|"")
      lb=""
      ;;
    *)
      echo "Unknown CEOS_API_LB_METHOD=${CEOS_API_LB_METHOD} (use least_conn, ip_hash, or round_robin)." >&2
      exit 1
      ;;
  esac

  echo "upstream nerve_ceos_api {"
  if [[ -n "${lb}" ]]; then
    echo "    ${lb}"
  fi
  for be in ${backends}; do
    echo "    server ${be};"
  done
  echo "}"
}

charkive_upstream_block() {
  echo "upstream nerve_charkive {"
  echo "    server 127.0.0.1:${CHARKIVE_PORT};"
  echo "}"
}

archive_redirect_stmt() {
  if [[ -n "${ARCHIVE_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${ARCHIVE_REDIRECT_HOST}:${ARCHIVE_PORT}/;"
  else
    echo "return 302 http://\$host:${ARCHIVE_PORT}/;"
  fi
}

sic_redirect_stmt() {
  if [[ -n "${SIC_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${SIC_REDIRECT_HOST}:${SIC_PORT}/;"
  else
    echo "return 302 http://\$host:${SIC_PORT}/;"
  fi
}

deanotron_redirect_stmt() {
  if [[ -n "${DEANOTRON_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${DEANOTRON_REDIRECT_HOST}:${DEANOTRON_PORT}/;"
  else
    echo "return 302 http://\$host:${DEANOTRON_PORT}/;"
  fi
}

mailportal_redirect_stmt() {
  if [[ -n "${MAIL_PORTAL_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${MAIL_PORTAL_REDIRECT_HOST}:${MAIL_PORTAL_PORT}/;"
  else
    echo "return 302 http://\$host:${MAIL_PORTAL_PORT}/;"
  fi
}

vpnportal_redirect_stmt() {
  if [[ -n "${VPN_PORTAL_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${VPN_PORTAL_REDIRECT_HOST}:${VPN_PORTAL_PORT}/;"
  else
    echo "return 302 http://\$host:${VPN_PORTAL_PORT}/;"
  fi
}

surveyportal_redirect_stmt() {
  if [[ -n "${SURVEY_PORTAL_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${SURVEY_PORTAL_REDIRECT_HOST}:${SURVEY_PORTAL_PORT}/;"
  else
    echo "return 302 http://\$host:${SURVEY_PORTAL_PORT}/;"
  fi
}

aiteams_redirect_stmt() {
  if [[ -n "${AITEAMS_PORTAL_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${AITEAMS_PORTAL_REDIRECT_HOST}:${AITEAMS_PORTAL_PORT}/;"
  else
    echo "return 302 http://\$host:${AITEAMS_PORTAL_PORT}/;"
  fi
}

hardwareportal_redirect_stmt() {
  if [[ -n "${HW_PORTAL_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${HW_PORTAL_REDIRECT_HOST}:${HW_PORTAL_PORT}/;"
  else
    echo "return 302 http://\$host:${HW_PORTAL_PORT}/;"
  fi
}

fleetdynamics_redirect_stmt() {
  if [[ -n "${FD_PORTAL_REDIRECT_HOST:-}" ]]; then
    echo "return 302 http://${FD_PORTAL_REDIRECT_HOST}:${FD_PORTAL_PORT}/;"
  else
    echo "return 302 http://\$host:${FD_PORTAL_PORT}/;"
  fi
}

workadventure_redirect_stmt() {
  if [[ -n "${WORKADVENTURE_URL:-}" ]]; then
    echo "return 302 ${WORKADVENTURE_URL};"
    return
  fi
  if [[ -n "${NERVECENTRE_LAN_IP:-}" ]]; then
    local ip="${NERVECENTRE_LAN_IP}"
    local p="${WORKADVENTURE_PORT}"
    if [[ "${p}" == "80" ]]; then
      echo "return 302 http://${ip}/;"
    else
      echo "return 302 http://${ip}:${p}/;"
    fi
    return
  fi
  local h="${WORKADVENTURE_PLAY_HOST}"
  local p="${WORKADVENTURE_PORT}"
  if [[ "${p}" == "80" ]]; then
    echo "return 302 http://${h}/;"
  else
    echo "return 302 http://${h}:${p}/;"
  fi
}

ARCH_LINE="$(archive_redirect_stmt)"
SIC_LINE="$(sic_redirect_stmt)"
DEAN_LINE="$(deanotron_redirect_stmt)"
MAIL_LINE="$(mailportal_redirect_stmt)"
VPN_LINE="$(vpnportal_redirect_stmt)"
SURVEY_LINE="$(surveyportal_redirect_stmt)"
AITEAMS_LINE="$(aiteams_redirect_stmt)"
HW_LINE="$(hardwareportal_redirect_stmt)"
FD_LINE="$(fleetdynamics_redirect_stmt)"
WA_LINE="$(workadventure_redirect_stmt)"

if [[ -n "${ARCHIVE_BACKENDS// }" ]]; then
  ARCHIVE_LOC_BODY="$(cat <<'ARCHLOC'


    location = /archive {
        return 301 http://\$host/archive/;
    }

    # Splippers Archive — load-balanced; strip /archive/ toward backends (VIP-friendly).
    location /archive/ {
        proxy_pass http://nerve_archive/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_set_header Accept-Encoding "";

        sub_filter_types application/javascript application/json;
        sub_filter_once off;
        sub_filter '"/api/' '"/archive/api/';
        sub_filter "'/api/" "'/archive/api/";
    }
ARCHLOC
)"
else
  ARCHIVE_LOC_BODY="$(cat <<ARCHLOC


    location = /archive {
        ${ARCH_LINE}
    }
    location /archive/ {
        ${ARCH_LINE}
    }
ARCHLOC
)"
fi

if [[ -n "${SIC_BACKENDS// }" ]]; then
  SIC_LOC_BODY="$(cat <<'SICLOC'


    location = /sic {
        return 301 http://\$host/sic/;
    }

    # SIC WebSocket — React hardcodes ws://host/ws; intercept before the / catch-all.
    location /ws {
        proxy_pass http://nerve_sic;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }

    location /sic/ {
        proxy_pass http://nerve_sic/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_set_header Accept-Encoding "";

        sub_filter_types application/javascript application/json;
        sub_filter_once off;
        sub_filter '"/assets/' '"/sic/assets/';
        sub_filter "'/assets/" "'/sic/assets/";
        sub_filter '"/api/' '"/sic/api/';
        sub_filter "'/api/" "'/sic/api/";
    }
SICLOC
)"
else
  SIC_LOC_BODY="$(cat <<SICLOC


    location = /sic {
        ${SIC_LINE}
    }
    location /sic/ {
        ${SIC_LINE}
    }
SICLOC
)"
fi

mkdir -p "$WWW"

TMP="$(mktemp)"
{
  if [[ -n "${ARCHIVE_BACKENDS// }" ]]; then
    archive_upstream_block
  fi
  if [[ -n "${SIC_BACKENDS// }" ]]; then
    sic_upstream_block
  fi
  brickwise_upstream_block
  monyatron_upstream_block
  jonotron_upstream_block
  ceosimulator_upstream_block
  ceosapi_upstream_block
  charkive_upstream_block
  projectscan_upstream_block
  cat <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # Security headers
    server_tokens off;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), camera=(), microphone=()" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Unified NerveCentre landing page is the default for http://host/ and http://host:80/
    root "${WWW}";
    index index.html;

    location = /brickwise {
        return 301 http://\$host/brickwise/;
    }

    # Brickwise (Flask): strip /brickwise/ prefix; HTML sub_filter fixes /api paths for the browser.
    location /brickwise/ {
        proxy_pass http://nerve_brickwise/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_set_header Accept-Encoding "";

        sub_filter_once off;
        sub_filter '"/api/' '"/brickwise/api/';
        sub_filter "'/api/" "'/brickwise/api/";
    }

    location = /monyatron {
        return 301 http://\$host/monyatron/;
    }

    # Monyatron (Flask): strip /monyatron/ prefix; HTML sub_filter fixes /api paths.
    location /monyatron/ {
        proxy_pass http://nerve_monyatron/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_set_header Accept-Encoding "";

        sub_filter_once off;
        sub_filter '"/api/' '"/monyatron/api/';
        sub_filter "'/api/" "'/monyatron/api/";
    }

    location = /jonotron {
        return 301 http://\$host/jonotron/;
    }

    # Jonotron (FastAPI): strip /jonotron/ prefix; rewrite /api and /ui in HTML + JS for the browser.
    location /jonotron/ {
        proxy_pass http://nerve_jonotron/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_set_header Accept-Encoding "";

        sub_filter_types application/javascript;
        sub_filter_once off;
        sub_filter '"/api/' '"/jonotron/api/';
        sub_filter "'/api/" "'/jonotron/api/";
        sub_filter '"/ui/' '"/jonotron/ui/';
        sub_filter "'/ui/" "'/jonotron/ui/";
    }

    location = /ceo-simulator {
        return 301 http://\$host/ceo-simulator/;
    }

    # CEO-Simulator (Flask central): strip /ceo-simulator/ prefix; sub_filter for JSON/HTML clients using relative /api.
    location /ceo-simulator/ {
        proxy_pass http://nerve_ceo_simulator/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_set_header Accept-Encoding "";

        sub_filter_types application/javascript application/json;
        sub_filter_once off;
        sub_filter '"/api/' '"/ceo-simulator/api/';
        sub_filter "'/api/" "'/ceo-simulator/api/";
    }

    location = /ceos-api {
        return 301 http://\$host/ceos-api/;
    }

    # CEOS 4.0 API (FastAPI/uvicorn): strip /ceos-api/ prefix; rewrite JSON path refs for browser.
    location /ceos-api/ {
        proxy_pass http://nerve_ceos_api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_set_header Accept-Encoding "";

        sub_filter_types application/javascript application/json;
        sub_filter_once off;
        sub_filter '"/docs'   '"/ceos-api/docs';
        sub_filter '"/openapi' '"/ceos-api/openapi';
    }
${ARCHIVE_LOC_BODY}
${SIC_LOC_BODY}

    # CF Tunnel Setup Portal — standalone Flask app on port 8085.
    location = /cf {
        return 301 http://\$host/cf/;
    }
    location /cf/ {
        proxy_pass http://127.0.0.1:8085/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /charkive {
        return 301 http://\$host/charkive/;
    }

    # Charkive (FastAPI web dashboard): strip /charkive/ prefix; rewrite API + static paths in JS.
    location /charkive/ {
        proxy_pass http://nerve_charkive/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
        proxy_set_header Accept-Encoding "";

        sub_filter_types application/javascript;
        sub_filter_once off;
        sub_filter '"/api/' '"/charkive/api/';
        sub_filter "'/api/" "'/charkive/api/";
        sub_filter '"/static/' '"/charkive/static/';
        sub_filter "'/static/" "'/charkive/static/";
    }

    # Deanotron (Expo web) — absolute asset paths; redirect to dedicated port (see Deanotron deploy/).
    location = /deanotron {
        ${DEAN_LINE}
    }
    location /deanotron/ {
        ${DEAN_LINE}
    }

    # Ceo-Sim Mail Portal — standalone Flask app with absolute paths; redirect to dedicated port.
    location = /mail-portal {
        ${MAIL_LINE}
    }
    location /mail-portal/ {
        ${MAIL_LINE}
    }

    # VPN Portal — WireGuard peer management Flask app.
    location = /vpn-portal {
        ${VPN_LINE}
    }
    location /vpn-portal/ {
        ${VPN_LINE}
    }

    # Survey Portal — add ideas and context to projects.
    location = /survey-portal {
        ${SURVEY_LINE}
    }
    location /survey-portal/ {
        ${SURVEY_LINE}
    }

    # AI Teams Portal — manage teams, assignments, activity.
    location = /ai-teams {
        ${AITEAMS_LINE}
    }
    location /ai-teams/ {
        ${AITEAMS_LINE}
    }

    # Hardware Resources Portal — fleet inventory, load monitoring, bottlenecks.
    location = /hardware {
        ${HW_LINE}
    }
    location /hardware/ {
        ${HW_LINE}
    }

    # Fleet Dynamics — live health, cough tests, node invitations.
    location = /fleet {
        ${FD_LINE}
    }
    location /fleet/ {
        ${FD_LINE}
    }

    # WorkAdventure — Traefik multi-host setup; redirect to play URL (configure WORKADVENTURE_* env vars).
    location = /workadventure {
        return 301 http://\$host/workadventure/;
    }
    location /workadventure/ {
        ${WA_LINE}
    }

    location = /projects {
        return 301 http://\$host/projects/;
    }

    # Project prioritiser (Python http.server — run from sibling moneymakers checkout)
    location /projects/ {
        proxy_pass http://nerve_projectscan/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }

    # NerveCentre portal also available at /nc/ (alias to WWW root)
    location /nc/ {
        alias ${WWW}/;
        index index.html;
    }

    # /nc without trailing slash → /nc/
    location = /nc {
        return 301 /nc/;
    }

    # nc.splippers.com bare root → /nc/ (tunnel entry point)
    location = / {
        if (\$http_host = "nc.splippers.com") { return 301 https://nc.splippers.com/nc/; }
        try_files \$uri \$uri/ /index.html;
    }

    # Everything else — serve static files; / → index.html (NerveCentre UI)
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX
} >"$TMP"

install -m 0644 "${ROOT}/index.html" "${WWW}/index.html"
if [[ -f "${ROOT}/moneymakers-drive-guide.html" ]]; then
  install -m 0644 "${ROOT}/moneymakers-drive-guide.html" "${WWW}/moneymakers-drive-guide.html"
fi

# One-line /etc/hosts helper so clients resolve *.workadventure.localhost to the NerveCentre host (LAN IP).
WA_HOST_LINE="play.workadventure.localhost front.workadventure.localhost room-api.workadventure.localhost maps.workadventure.localhost api.workadventure.localhost map-storage.workadventure.localhost uploader.workadventure.localhost redis.workadventure.localhost icon.workadventure.localhost oidc.workadventure.localhost matrix.workadventure.localhost traefik.workadventure.localhost pusher.workadventure.localhost xmpp.workadventure.localhost"
if [[ -n "${NERVECENTRE_LAN_IP:-}" ]]; then
  cat >"${WWW}/workadventure-hosts.txt" <<EOF
# Add this line to /etc/hosts (Linux/macOS) or C:\\Windows\\System32\\drivers\\etc\\hosts (Windows Administrator).
# Then open http://${NERVECENTRE_LAN_IP}:${WORKADVENTURE_PORT}/ or use NerveCentre → WorkAdventure.
${NERVECENTRE_LAN_IP} ${WA_HOST_LINE}
EOF
else
  cat >"${WWW}/workadventure-hosts.txt" <<'EOF'
# Re-run install-portal.sh with NERVECENTRE_LAN_IP set to this machine’s LAN address, e.g.:
#   sudo NERVECENTRE_LAN_IP=192.168.1.1 ./deploy/portal/install-portal.sh
# A one-line hosts entry will be generated here automatically.
EOF
fi
chmod 0644 "${WWW}/workadventure-hosts.txt"

install -m 0644 "$TMP" "/etc/nginx/sites-available/${SITE_NAME}.conf"
rm -f "$TMP"

if [[ -e "/etc/nginx/sites-enabled/default" ]]; then
  echo "Disabling stock nginx default site (was claiming port 80)."
  rm -f /etc/nginx/sites-enabled/default
fi

ln -sf "/etc/nginx/sites-available/${SITE_NAME}.conf" "/etc/nginx/sites-enabled/${SITE_NAME}.conf"

nginx -t
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
else
  systemctl start nginx
fi

echo "Splippers portal (NerveCentre) installed."
echo "  Static files: ${WWW}/"
echo "  Config: /etc/nginx/sites-available/${SITE_NAME}.conf"
if [[ -z "${BRICKWISE_BACKENDS// }" ]]; then
  echo "  Brickwise upstream: 127.0.0.1:${BW_PORT} (set BRICKWISE_BACKENDS for load balancing)"
else
  echo "  Brickwise upstream (load-balanced): ${BRICKWISE_BACKENDS}"
fi
if [[ -z "${ARCHIVE_BACKENDS// }" ]]; then
  echo "  Splippers Archive: redirect → http://${ARCHIVE_REDIRECT_HOST:-\$host}:${ARCHIVE_PORT}/ (set ARCHIVE_BACKENDS for load-balanced /archive/ proxy)"
else
  echo "  Splippers Archive (/archive/): upstream ${ARCHIVE_BACKENDS}"
fi
if [[ -z "${SIC_BACKENDS// }" ]]; then
  echo "  SIC: redirect → http://${SIC_REDIRECT_HOST:-\$host}:${SIC_PORT}/ (set SIC_BACKENDS for load-balanced /sic/ proxy)"
else
  echo "  SIC (/sic/): upstream ${SIC_BACKENDS}"
fi
if [[ -z "${MONYATRON_BACKENDS// }" ]]; then
  echo "  Monyatron upstream: 127.0.0.1:${MONYATRON_PORT} (set MONYATRON_BACKENDS to load-balance)"
else
  echo "  Monyatron upstream (load-balanced): ${MONYATRON_BACKENDS}"
fi
if [[ -z "${JONOTRON_BACKENDS// }" ]]; then
  echo "  Jonotron upstream: 127.0.0.1:${JONOTRON_PORT} (set JONOTRON_BACKENDS to load-balance; default 8011 avoids clash with Archive on 8000)"
else
  echo "  Jonotron upstream (load-balanced): ${JONOTRON_BACKENDS}"
fi
if [[ -z "${CEO_SIMULATOR_BACKENDS// }" ]]; then
  echo "  CEO-Simulator upstream: 127.0.0.1:${CEO_SIMULATOR_PORT} (set CEO_SIMULATOR_BACKENDS to load-balance)"
else
  echo "  CEO-Simulator upstream (load-balanced): ${CEO_SIMULATOR_BACKENDS}"
fi
if [[ -z "${CEOS_API_BACKENDS// }" ]]; then
  echo "  CEOS 4.0 API upstream: 127.0.0.1:${CEOS_API_PORT} (set CEOS_API_BACKENDS to load-balance)"
else
  echo "  CEOS 4.0 API upstream (load-balanced): ${CEOS_API_BACKENDS}"
fi
  echo "  Charkive:  http://127.0.0.1:${CHARKIVE_PORT}/ (portal /charkive/ → proxy)"
  echo "  Deanotron redirect: ${DEANOTRON_REDIRECT_HOST:-\$host}:${DEANOTRON_PORT} (Expo web)"
  echo "  Ceo-Sim Mail Portal redirect: ${MAIL_PORTAL_REDIRECT_HOST:-\$host}:${MAIL_PORTAL_PORT} (mail compose UI)"
  echo "  Survey Portal redirect: ${SURVEY_PORTAL_REDIRECT_HOST:-\$host}:${SURVEY_PORTAL_PORT} (project ideas/context)"
  echo "  AI Teams Portal redirect: ${AITEAMS_PORTAL_REDIRECT_HOST:-\$host}:${AITEAMS_PORTAL_PORT} (team management)"
  echo "  Hardware Portal redirect: ${HW_PORTAL_REDIRECT_HOST:-\$host}:${HW_PORTAL_PORT} (fleet/load/bottlenecks)"
  echo "  Fleet Dynamics redirect: ${FD_PORTAL_REDIRECT_HOST:-\$host}:${FD_PORTAL_PORT} (live health/cough/invite)"
if [[ -n "${WORKADVENTURE_URL:-}" ]]; then
  echo "  WorkAdventure (/workadventure/): redirect → ${WORKADVENTURE_URL}"
elif [[ -n "${NERVECENTRE_LAN_IP:-}" ]]; then
  if [[ "${WORKADVENTURE_PORT}" == "80" ]]; then
    echo "  WorkAdventure (/workadventure/): redirect → http://${NERVECENTRE_LAN_IP}/ · /workadventure-hosts.txt"
  else
    echo "  WorkAdventure (/workadventure/): redirect → http://${NERVECENTRE_LAN_IP}:${WORKADVENTURE_PORT}/ · /workadventure-hosts.txt"
  fi
else
  if [[ "${WORKADVENTURE_PORT}" == "80" ]]; then
    echo "  WorkAdventure (/workadventure/): redirect → http://${WORKADVENTURE_PLAY_HOST}/"
  else
    echo "  WorkAdventure (/workadventure/): redirect → http://${WORKADVENTURE_PLAY_HOST}:${WORKADVENTURE_PORT}/ (set WORKADVENTURE_URL or NERVECENTRE_LAN_IP to override)"
  fi
fi
if [[ -z "${PROJECTSCAN_BACKENDS// }" ]]; then
  echo "  Project prioritiser (/projects/): upstream 127.0.0.1:${PROJECTSCAN_PORT} (PROJECTSCAN_BACKENDS for load-balancing)"
else
  echo "  Project prioritiser (/projects/): upstream ${PROJECTSCAN_BACKENDS}"
fi
echo "  Internal: http://$(hostname -I 2>/dev/null | awk '{print $1}')/nc/"
echo "  External: https://nervecentre.splippers.com/nc/"
