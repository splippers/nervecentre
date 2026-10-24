#!/bin/bash
# Run ON MARVIN (bash -s). Installs the registry-generated portal behind nginx :81 and exposes it
# over HTTPS through Traefik at https://192.168.1.2/. Backs up first; rolls back on any failed check.
# Expects staged files in /tmp/ncsw-marvin: nerve.conf index.html services.toml nc_health.py nc-health.service nc-health.timer traefik-nc.yml
set -u
D=/tmp/ncsw-marvin; TS=$(date +%Y%m%d-%H%M%S); B=/root/nc-backup-$TS
CONF=/etc/nginx/sites-enabled/splippers-portal.conf
TRF=/opt/traefik/dynamic/services.yml
sudo mkdir -p $B /opt/nc-registry && sudo cp -a "$CONF" /var/www/splippers-portal/index.html $B/ && sudo cp -a $TRF $B/ && echo "backup: $B"
rollback() {
  sudo cp -a $B/splippers-portal.conf "$CONF"; sudo cp -a $B/index.html /var/www/splippers-portal/index.html
  sudo cp -a $B/services.yml $TRF; sudo nginx -t && sudo systemctl reload nginx; echo "ROLLED BACK"; exit 1
}
sudo install -m 644 $D/services.toml $D/nc_health.py /opt/nc-registry/
sudo install -m 644 $D/index.html /var/www/splippers-portal/index.html
sudo install -m 644 $D/nerve.conf "$CONF"
sudo nginx -t || rollback
sudo systemctl reload nginx || rollback
sleep 1
for p in / /nc/ /fleet/ /fleet/api/fleet /craicpype/api/agents /brickwise/ /archive/; do
  c=$(curl -s -o /dev/null -m 8 -w "%{http_code}" http://127.0.0.1:81$p); echo "nginx :81 $p $c"; [ "$c" = 200 ] || rollback
done
# Traefik: HTTPS router for the IP / hostnames, same nginx backend as the HTTP one. Hot-reloaded.
if ! grep -q "nerve-centre-https" $TRF; then
  sudo python3 - "$TRF" "$D/traefik-nc.yml" <<'PY'
import sys
p, snip = sys.argv[1], open(sys.argv[2]).read()
s = open(p).read()
marker = "    # ── CF-tunnel-facing routes"
assert s.count(marker) == 1
open(p, "w").write(s.replace(marker, snip + "\n" + marker))
PY
fi
sleep 3
c=$(curl -sk -m 8 -o /dev/null -w "%{http_code}" https://192.168.1.2/); echo "https://192.168.1.2/ $c"; [ "$c" = 200 ] || rollback
c=$(curl -sk -m 8 -o /dev/null -w "%{http_code}" https://192.168.1.2/nc/); echo "https://192.168.1.2/nc/ $c"; [ "$c" = 200 ] || rollback
# health probe
sudo sed 's#health.json eddie 80#health.json marvin 81#' $D/nc-health.service | sudo tee /etc/systemd/system/nc-health.service >/dev/null
sudo install -m 644 $D/nc-health.timer /etc/systemd/system/nc-health.timer
sudo systemctl daemon-reload && sudo systemctl enable --now nc-health.timer >/dev/null 2>&1; sudo systemctl start nc-health.service
echo SWITCHED
