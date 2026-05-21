#!/usr/bin/env bash
# Albatross Protocol — install snmpd/snmptrapd + peer traps with community ALBATROSS
# Usage: sudo ./deploy-albatross.sh <THIS_IP> [PEER_IP...]
set -euo pipefail

THIS_IP="${1:-}"
shift || true
PEERS=("$@")

if [[ -z "$THIS_IP" ]]; then
  echo "Usage: sudo $0 <THIS_HOST_IP> [PEER_IP...]"
  echo "  e.g. sudo $0 192.168.1.1 192.168.1.2 192.168.1.65"
  exit 1
fi

RO_COMMUNITY="${ALBATROSS_RO_COMMUNITY:-$(openssl rand -hex 12)}"
TRAP_COMMUNITY="ALBATROSS"
ALLOW_NET="${ALBATROSS_ALLOW_NET:-192.168.1.0/24}"

echo "=== Albatross Protocol: $(hostname) @ $THIS_IP ==="
echo "  RO: $RO_COMMUNITY  Trap: $TRAP_COMMUNITY  Net: $ALLOW_NET"
echo "  Peers: ${PEERS[*]:-(none)}"
echo

# Install
if command -v apt-get &>/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq snmpd snmp snmptrapd
elif command -v dnf &>/dev/null; then
  dnf install -y -q net-snmp net-snmp-utils net-snmp-perl
elif command -v yum &>/dev/null; then
  yum install -y -q net-snmp net-snmp-utils net-snmp-perl
fi

# --- snmpd.conf ---
cat > /etc/snmp/snmpd.conf <<SNMPD
rocommunity $RO_COMMUNITY $ALLOW_NET
agentAddress udp:161
sysName $(hostname)
sysLocation Splippers-Fleet
sysContact jon@splippers.com
authtrapenable 1
trapcommunity $TRAP_COMMUNITY
SNMPD

for peer in "${PEERS[@]}"; do
  echo "trap2sink $peer $TRAP_COMMUNITY" >> /etc/snmp/snmpd.conf
done

# --- snmptrapd.conf ---
cat > /etc/snmp/snmptrapd.conf <<TRAPD
authCommunity log,execute,net $TRAP_COMMUNITY
disableAuthorization yes
traphandle default /usr/bin/logger -t ALBATROSS-TRAIL "ALBATROSS trap from %a: %v"
TRAPD

# Enable trap daemon
sed -i 's/^SNMPDRUN=.*/SNMPDRUN=yes/' /etc/default/snmpd 2>/dev/null || true
sed -i 's/^TRAPDRUN=.*/TRAPDRUN=yes/' /etc/default/snmpd 2>/dev/null || true

systemctl enable snmpd 2>/dev/null || true
systemctl restart snmpd || true

if systemctl list-unit-files snmptrapd.service &>/dev/null 2>&1; then
  systemctl enable snmptrapd || true
  systemctl restart snmptrapd || true
fi

echo
echo "=== ALBATROSS PROTOCOL ACTIVE on $(hostname) ==="
echo "  snmpwalk -v2c -c '$RO_COMMUNITY' $THIS_IP 1.3.6.1.2.1.1"
echo "  Send test trap: snmptrap -v2c -c '$TRAP_COMMUNITY' <PEER> '' 1.3.6.1.4.1.0 0 ALBATROSS-TEST s 'Hello from $(hostname)'"
echo "  View traps: journalctl -t ALBATROSS-TRAIL -n 20"
