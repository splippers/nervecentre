#!/bin/bash
set -u
D=/tmp/ncsw; TS=$(date +%Y%m%d-%H%M%S); B=/root/nc-backup-$TS
LIVE=$(readlink -f /etc/nginx/sites-enabled/splippers-portal.conf)
sudo mkdir -p $B && sudo cp -a "$LIVE" /var/www/splippers-portal/index.html $B/ && echo "backup: $B"
rollback() { sudo cp -a $B/$(basename "$LIVE") "$LIVE"; sudo cp -a $B/index.html /var/www/splippers-portal/index.html; sudo nginx -t && sudo systemctl reload nginx; echo "ROLLED BACK"; exit 1; }
sudo install -m 644 $D/services.toml /opt/nc-registry/
sudo install -m 644 $D/index.html /var/www/splippers-portal/index.html
sudo install -m 644 $D/nerve.conf "$LIVE"
sudo nginx -t || rollback
sudo systemctl reload nginx || rollback
sleep 1
for p in / /nc/ /fleet/ /fleet/api/fleet /brickwise/api/diagnostics; do c=$(curl -s -o /dev/null -m 5 -w "%{http_code}" http://127.0.0.1$p); echo "$p $c"; [ "$c" = 200 ] || rollback; done
echo SWITCHED
