#!/usr/bin/env python3
"""Network Portal — DHCP leases, DNS queries, and LAN utilities for NerveCentre."""

import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, render_template_string, request

app = Flask(__name__)

PORT = int(os.environ.get("NET_PORTAL_PORT", 8091))
MARVIN_IP = "192.168.1.2"
LEASE_PATHS = [
    Path("/var/lib/misc/dnsmasq.leases"),
    Path("/var/lib/dnsmasq/dnsmasq.leases"),
]

_SAFE_HOST = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,251}[a-zA-Z0-9])?$")
_SAFE_QTYPE = {"A", "AAAA", "MX", "PTR", "TXT", "CNAME", "NS", "SRV", "ANY"}

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Net Portal — NerveCentre</title>
  <link rel="preconnect" href="https://fonts.googleapis.com"/>
  <link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;600;700&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet"/>
  <style>
    :root {
      --bg0:#06080c; --bg1:#0d1118; --edge:rgba(255,255,255,0.06);
      --text:#e9eef5; --muted:#94a3b8; --accent:#34d399;
      --accent-dim:rgba(52,211,153,0.12); --accent-border:rgba(52,211,153,0.28);
      --card-r:18px;
    }
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:"DM Sans",system-ui,sans-serif;color:var(--text);min-height:100vh;
      background:radial-gradient(1000px 500px at 10% -5%,rgba(52,211,153,0.1),transparent 55%),
        radial-gradient(800px 400px at 90% 5%,rgba(56,189,248,0.08),transparent 50%),
        linear-gradient(165deg,var(--bg0),var(--bg1) 45%,#05070b);}
    .wrap{max-width:1100px;margin:0 auto;padding:2rem 1.25rem 3rem}
    header{text-align:center;margin-bottom:2rem}
    header h1{font-size:clamp(1.6rem,3.5vw,2rem);font-weight:700;letter-spacing:-0.03em}
    header p{color:var(--muted);font-size:0.97rem;margin-top:0.35rem}
    .back{display:inline-block;margin-bottom:1.5rem;font-size:0.9rem;color:var(--muted);text-decoration:none}
    .back:hover{color:var(--accent)}
    .tabs{display:flex;gap:0.5rem;margin-bottom:1.5rem;flex-wrap:wrap}
    .tab{padding:0.45rem 1rem;border-radius:999px;border:1px solid var(--edge);
      font-size:0.88rem;font-weight:600;cursor:pointer;background:transparent;color:var(--muted);
      transition:all 0.15s ease}
    .tab.active,.tab:hover{background:var(--accent-dim);border-color:var(--accent-border);color:var(--accent)}
    .panel{display:none}.panel.active{display:block}
    .card{background:rgba(14,18,26,0.72);border:1px solid var(--edge);border-radius:var(--card-r);
      backdrop-filter:blur(12px);padding:1.5rem;margin-bottom:1.15rem}
    .card h2{font-size:1.1rem;font-weight:700;margin-bottom:1rem;color:var(--accent)}
    .row{display:flex;gap:0.5rem;flex-wrap:wrap;align-items:flex-end;margin-bottom:1rem}
    input,select{background:rgba(255,255,255,0.05);border:1px solid var(--edge);border-radius:8px;
      color:var(--text);padding:0.5rem 0.75rem;font-family:inherit;font-size:0.93rem;outline:none}
    input:focus,select:focus{border-color:var(--accent-border)}
    input{flex:1;min-width:160px}
    button{background:var(--accent-dim);border:1px solid var(--accent-border);border-radius:8px;
      color:var(--accent);font-weight:600;padding:0.5rem 1.1rem;cursor:pointer;font-family:inherit;
      font-size:0.93rem;white-space:nowrap;transition:all 0.15s ease}
    button:hover{background:rgba(52,211,153,0.2)}
    .result{font-family:"DM Mono",monospace;font-size:0.85rem;color:var(--text);
      background:rgba(0,0,0,0.35);border-radius:10px;padding:1rem;overflow-x:auto;
      white-space:pre-wrap;min-height:2rem;line-height:1.6;margin-top:0.5rem}
    table{width:100%;border-collapse:collapse;font-size:0.88rem}
    th{text-align:left;color:var(--muted);font-weight:600;padding:0.5rem 0.75rem;
      border-bottom:1px solid var(--edge)}
    td{padding:0.5rem 0.75rem;border-bottom:1px solid rgba(255,255,255,0.03)}
    tr:hover td{background:rgba(255,255,255,0.02)}
    .tag{display:inline-block;padding:0.15rem 0.5rem;border-radius:999px;font-size:0.75rem;font-weight:600}
    .tag-marvin{background:rgba(251,146,60,0.12);color:#fb923c;border:1px solid rgba(251,146,60,0.28)}
    .tag-eddie{background:rgba(56,189,248,0.12);color:#38bdf8;border:1px solid rgba(56,189,248,0.28)}
    .tag-ok{background:rgba(52,211,153,0.12);color:#34d399;border:1px solid rgba(52,211,153,0.28)}
    .tag-err{background:rgba(248,113,113,0.12);color:#f87171;border:1px solid rgba(248,113,113,0.28)}
    .label{font-size:0.8rem;color:var(--muted);font-weight:600;margin-bottom:0.35rem}
    .refresh-note{font-size:0.8rem;color:var(--muted);text-align:right;margin-bottom:0.5rem}
    .spinner{display:inline-block;width:14px;height:14px;border:2px solid var(--edge);
      border-top-color:var(--accent);border-radius:50%;animation:spin 0.7s linear infinite;vertical-align:middle}
    @keyframes spin{to{transform:rotate(360deg)}}
    .config-file{margin-bottom:1rem}
    .config-filename{font-size:0.8rem;color:var(--accent);font-weight:600;margin-bottom:0.35rem;font-family:"DM Mono",monospace}
  </style>
</head>
<body>
<div class="wrap">
  <a class="back" href="/nc/">← NerveCentre</a>
  <header>
    <h1>Net Portal</h1>
    <p>DHCP leases · DNS queries · LAN utilities · dnsmasq config</p>
  </header>

  <div class="tabs">
    <button class="tab active" onclick="switchTab('leases',this)">DHCP Leases</button>
    <button class="tab" onclick="switchTab('dns',this)">DNS Query</button>
    <button class="tab" onclick="switchTab('ping',this)">Ping</button>
    <button class="tab" onclick="switchTab('hosts',this)">Hosts File</button>
    <button class="tab" onclick="switchTab('config',this)">dnsmasq Config</button>
  </div>

  <!-- DHCP Leases -->
  <div class="panel active" id="panel-leases">
    <div class="card">
      <h2>Active DHCP Leases</h2>
      <div class="refresh-note"><span id="lease-ts"></span> &nbsp;<button onclick="loadLeases()" style="padding:0.25rem 0.65rem;font-size:0.8rem">Refresh</button></div>
      <div id="lease-table"><div class="result">Loading…</div></div>
    </div>
  </div>

  <!-- DNS Query -->
  <div class="panel" id="panel-dns">
    <div class="card">
      <h2>DNS Query</h2>
      <div class="row">
        <div style="flex:1;min-width:160px">
          <div class="label">Hostname or IP</div>
          <input id="dns-host" type="text" placeholder="e.g. marvin.lan or 8.8.8.8" onkeydown="if(event.key==='Enter')runDns()"/>
        </div>
        <div>
          <div class="label">Type</div>
          <select id="dns-type">
            <option>A</option><option>AAAA</option><option>MX</option>
            <option>PTR</option><option>TXT</option><option>CNAME</option>
            <option>NS</option><option>SRV</option><option>ANY</option>
          </select>
        </div>
        <button onclick="runDns()">Query</button>
      </div>
      <div class="result" id="dns-result">Result appears here.</div>
    </div>
  </div>

  <!-- Ping -->
  <div class="panel" id="panel-ping">
    <div class="card">
      <h2>Ping</h2>
      <div class="row">
        <div style="flex:1">
          <div class="label">Host or IP</div>
          <input id="ping-host" type="text" placeholder="e.g. 192.168.1.2 or marvin.lan" onkeydown="if(event.key==='Enter')runPing()"/>
        </div>
        <div>
          <div class="label">Count</div>
          <select id="ping-count"><option>4</option><option>8</option><option>16</option></select>
        </div>
        <button onclick="runPing()">Ping</button>
      </div>
      <div class="result" id="ping-result">Result appears here.</div>
    </div>
  </div>

  <!-- Hosts File -->
  <div class="panel" id="panel-hosts">
    <div class="card">
      <h2>EDDIE /etc/hosts</h2>
      <div id="hosts-table"><div class="result">Loading…</div></div>
    </div>
  </div>

  <!-- dnsmasq Config -->
  <div class="panel" id="panel-config">
    <div class="card">
      <h2>dnsmasq Config (MARVIN)</h2>
      <div id="config-content"><div class="result">Loading…</div></div>
    </div>
  </div>
</div>

<script>
function switchTab(name, btn) {
  document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.getElementById('panel-' + name).classList.add('active');
  btn.classList.add('active');
  if (name === 'leases') loadLeases();
  if (name === 'hosts') loadHosts();
  if (name === 'config') loadConfig();
}

function fmt(ts) {
  if (!ts || ts === '0') return 'static';
  const d = new Date(parseInt(ts) * 1000);
  return d.toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'}) + ' ' + d.toLocaleDateString();
}

async function loadLeases() {
  document.getElementById('lease-table').innerHTML = '<div class="result"><span class="spinner"></span> Fetching…</div>';
  try {
    const r = await fetch('/api/leases');
    const data = await r.json();
    document.getElementById('lease-ts').textContent = 'Updated ' + new Date().toLocaleTimeString();
    if (!data.length) {
      document.getElementById('lease-table').innerHTML = '<div class="result">No active leases.</div>';
      return;
    }
    let html = '<table><thead><tr><th>IP</th><th>Hostname</th><th>MAC</th><th>Expires</th><th>Server</th></tr></thead><tbody>';
    for (const l of data) {
      if (l.error) {
        html += `<tr><td colspan="5" style="color:#f87171">${l.error}</td></tr>`;
        continue;
      }
      const server = l.server === 'MARVIN'
        ? '<span class="tag tag-marvin">MARVIN</span>'
        : '<span class="tag tag-eddie">EDDIE</span>';
      html += `<tr><td><strong>${l.ip}</strong></td><td>${l.hostname || '—'}</td><td style="font-family:\'DM Mono\',monospace;font-size:0.82rem">${l.mac}</td><td>${fmt(l.expires)}</td><td>${server}</td></tr>`;
    }
    html += '</tbody></table>';
    document.getElementById('lease-table').innerHTML = html;
  } catch(e) {
    document.getElementById('lease-table').innerHTML = '<div class="result" style="color:#f87171">Error: ' + e + '</div>';
  }
}

async function runDns() {
  const host = document.getElementById('dns-host').value.trim();
  const type = document.getElementById('dns-type').value;
  if (!host) return;
  document.getElementById('dns-result').textContent = 'Querying…';
  try {
    const r = await fetch('/api/dns/query', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({host, type})
    });
    const d = await r.json();
    if (d.error) { document.getElementById('dns-result').textContent = 'Error: ' + d.error; return; }
    document.getElementById('dns-result').textContent = d.result || '(no records)';
  } catch(e) {
    document.getElementById('dns-result').textContent = 'Error: ' + e;
  }
}

async function runPing() {
  const host = document.getElementById('ping-host').value.trim();
  const count = document.getElementById('ping-count').value;
  if (!host) return;
  document.getElementById('ping-result').textContent = 'Pinging…';
  try {
    const r = await fetch('/api/ping', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({host, count: parseInt(count)})
    });
    const d = await r.json();
    const result = d.result || '(no output)';
    document.getElementById('ping-result').textContent = result;
    document.getElementById('ping-result').style.color = d.returncode === 0 ? 'var(--accent)' : '#f87171';
  } catch(e) {
    document.getElementById('ping-result').textContent = 'Error: ' + e;
  }
}

async function loadHosts() {
  document.getElementById('hosts-table').innerHTML = '<div class="result"><span class="spinner"></span> Loading…</div>';
  try {
    const r = await fetch('/api/hosts');
    const data = await r.json();
    let html = '<table><thead><tr><th>IP</th><th>Names</th></tr></thead><tbody>';
    for (const h of data) {
      html += `<tr><td style="font-family:'DM Mono',monospace;font-size:0.85rem">${h.ip}</td><td>${h.names.join(', ')}</td></tr>`;
    }
    html += '</tbody></table>';
    document.getElementById('hosts-table').innerHTML = html;
  } catch(e) {
    document.getElementById('hosts-table').innerHTML = '<div class="result" style="color:#f87171">Error: ' + e + '</div>';
  }
}

async function loadConfig() {
  document.getElementById('config-content').innerHTML = '<div class="result"><span class="spinner"></span> Loading…</div>';
  try {
    const r = await fetch('/api/dnsmasq/config');
    const data = await r.json();
    let html = '';
    for (const [fname, content] of Object.entries(data)) {
      const lines = content.split('\\n').filter(l => l.trim() && !l.trim().startsWith('#'));
      html += `<div class="config-file"><div class="config-filename">${fname}</div><div class="result">${lines.join('\\n') || '(empty after stripping comments)'}</div></div>`;
    }
    document.getElementById('config-content').innerHTML = html || '<div class="result">No config files found.</div>';
  } catch(e) {
    document.getElementById('config-content').innerHTML = '<div class="result" style="color:#f87171">Error: ' + e + '</div>';
  }
}

loadLeases();
</script>
</body>
</html>"""


def _read_leases(path: Path, server: str) -> list:
    leases = []
    if not path.exists():
        return leases
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 4:
            leases.append({
                "expires": parts[0],
                "mac": parts[1],
                "ip": parts[2],
                "hostname": parts[3] if parts[3] != "*" else "",
                "client_id": parts[4] if len(parts) > 4 else "",
                "server": server,
            })
    return leases


@app.route("/")
def index():
    return render_template_string(HTML)


@app.route("/api/leases")
def api_leases():
    leases = []
    for p in LEASE_PATHS:
        found = _read_leases(p, "EDDIE")
        if found:
            leases.extend(found)
            break

    try:
        r = subprocess.run(
            ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=4",
             "-o", "BatchMode=yes", MARVIN_IP,
             "cat /var/lib/misc/dnsmasq.leases /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null | sort -u"],
            capture_output=True, text=True, timeout=6,
        )
        for line in r.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                leases.append({
                    "expires": parts[0],
                    "mac": parts[1],
                    "ip": parts[2],
                    "hostname": parts[3] if parts[3] != "*" else "",
                    "client_id": parts[4] if len(parts) > 4 else "",
                    "server": "MARVIN",
                })
    except Exception as e:
        leases.append({"error": f"MARVIN unreachable: {e}", "server": "MARVIN"})

    leases.sort(key=lambda x: [int(p) for p in x.get("ip", "0.0.0.0").split(".")] if "." in x.get("ip", "") else [])
    return jsonify(leases)


@app.route("/api/dns/query", methods=["POST"])
def api_dns_query():
    host = (request.json or {}).get("host", "").strip()
    qtype = (request.json or {}).get("type", "A").strip().upper()
    if not host or not _SAFE_HOST.match(host):
        return jsonify({"error": "invalid host"}), 400
    if qtype not in _SAFE_QTYPE:
        return jsonify({"error": "invalid query type"}), 400
    r = subprocess.run(
        ["dig", "+short", qtype, host, f"@{MARVIN_IP}"],
        capture_output=True, text=True, timeout=10,
    )
    return jsonify({"host": host, "type": qtype, "result": r.stdout.strip(), "error": r.stderr.strip()})


@app.route("/api/ping", methods=["POST"])
def api_ping():
    host = (request.json or {}).get("host", "").strip()
    count = min(max(int((request.json or {}).get("count", 4)), 1), 16)
    if not host or not _SAFE_HOST.match(host):
        return jsonify({"error": "invalid host"}), 400
    r = subprocess.run(
        ["ping", "-c", str(count), "-W", "2", host],
        capture_output=True, text=True, timeout=count * 3 + 5,
    )
    return jsonify({"host": host, "result": r.stdout.strip(), "returncode": r.returncode})


@app.route("/api/hosts")
def api_hosts():
    entries = []
    for line in Path("/etc/hosts").read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        if len(parts) >= 2:
            entries.append({"ip": parts[0], "names": parts[1:]})
    return jsonify(entries)


@app.route("/api/dnsmasq/config")
def api_dnsmasq_config():
    files = {}
    for f in sorted(Path("/etc/dnsmasq.d").glob("*.conf")):
        try:
            files[f.name] = f.read_text()
        except Exception:
            pass
    return jsonify(files)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, debug=False)
