#!/bin/bash
# Run ON EDDIE with services.toml nc_health.py nerve.conf index.html nc-health.* in /tmp/ncsw/.
set -u
D=/tmp/ncsw; TS=$(date +%Y%m%d-%H%M%S); B=/root/nc-backup-$TS
LIVE=$(readlink -f /etc/nginx/sites-enabled/splippers-portal.conf)
sudo mkdir -p $B && sudo cp -a "$LIVE" /var/www/splippers-portal/index.html $B/ && echo "backup: $B"
sudo python3 - "$LIVE" $D/nerve.conf $D/final.conf <<'PY'
import sys
live, gen, out = sys.argv[1:]
L = open(live).read().split("\n")
a = next(i for i,l in enumerate(L) if l.strip().startswith("location /api/fleet"))
b = next(i for i,l in enumerate(L) if l.strip().startswith("location = /nc {"))
open(out, "w").write(open(gen).read().replace("@@LIVE_BLOCKS@@", "\n".join(L[a:b])))
PY
rollback() { sudo cp -a $B/$(basename "$LIVE") "$LIVE"; sudo cp -a $B/index.html /var/www/splippers-portal/index.html; sudo nginx -t && sudo systemctl reload nginx; echo "ROLLED BACK"; exit 1; }
sudo install -d /opt/nc-registry && sudo install -m 644 $D/services.toml $D/nc_health.py /opt/nc-registry/
sudo install -m 644 $D/index.html /var/www/splippers-portal/index.html
sudo python3 /opt/nc-registry/nc_health.py /opt/nc-registry/services.toml /var/www/splippers-portal/health.json eddie
sudo install -m 644 $D/final.conf "$LIVE"
sudo nginx -t || rollback
sudo systemctl reload nginx || rollback
sleep 1
curl -s -o /dev/null -m 5 -w "/ %{http_code}\n" http://127.0.0.1/ | grep -q "/ 200" || rollback
sudo install -m 644 $D/nc-health.service $D/nc-health.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now nc-health.timer >/dev/null 2>&1
echo SWITCHED
