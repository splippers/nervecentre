#!/usr/bin/env python3
"""Fleet Dynamics Portal — live fleet health, cough tests, node invitations."""

import json
import os
import random
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

_PORTAL_SECRET = os.environ.get("PORTAL_SECRET", "")
if not _PORTAL_SECRET:
    raise RuntimeError("PORTAL_SECRET env var must be set — refusing to start without auth")


@app.before_request
def _require_portal_secret():
    auth = request.headers.get("Authorization", "")
    token = auth.removeprefix("Bearer ").strip()
    if token != _PORTAL_SECRET:
        return jsonify({"error": "Unauthorized"}), 401


DATA_DIR = Path(os.environ.get("FD_DATA_DIR", "/home/jon/.fleetdynamics"))
NODES_FILE = DATA_DIR / "nodes.json"
HEALTH_FILE = DATA_DIR / "health_log.json"
INVITES_FILE = DATA_DIR / "invites.json"
PORT = int(os.environ.get("FD_PORTAL_PORT", 8089))

DATA_DIR.mkdir(parents=True, exist_ok=True)

DEFAULT_NODES = [
    {"name": "MARVIN", "ip": "192.168.1.2", "cpu_count": 4, "ram_gb": 11, "has_gpu": True, "gpu_model": "Likely NVIDIA GTX 1050 Ti Max-Q (Dell XPS 15)", "os": "Ubuntu 24.04 (6.17.0-23-generic)", "storage": "116 GB root (sda2) + 234 GB NVMe /SANDIEGO", "swap_gb": 4, "models": [], "role": "NFS/SMB hub + Ollama server", "joined": "2025-01-15", "status": "active"},
    {"name": "EDDIE", "ip": "192.168.1.1", "cpu_count": 4, "ram_gb": 15, "has_gpu": False, "os": "Ubuntu 24.04 (6.8.0-111-generic)", "storage": "117 GB root (sda2)", "swap_gb": 0, "models": [], "role": "NerveCentre host - LAN control plane", "joined": "2025-06-01", "status": "active"},
    {"name": "LAVE", "ip": "192.168.1.65", "cpu_count": 12, "ram_gb": 14, "has_gpu": True, "gpu_model": "Intel UHD Graphics 630 (integrated)", "os": "Ubuntu 26.04 (7.0.0-15-generic)", "storage": "468 GB NVMe root (nvme0n1p2)", "swap_gb": 4, "models": [], "role": "i7-9750H workstation - GPU-capable fleet node", "joined": "2026-05-13", "status": "active"},
]

# Known hosts seen on the LAN during nmap scan.
# Only fields from network observation: IP, reachability, OS fingerprint, open ports.
LAN_KNOWN_HOSTS = {
    "192.168.1.12": {"name_hint": "MARVIN (2nd IP)", "os_hint": "Linux 5.x", "services": ["ssh", "http", "smb", "ollama"], "ollama_models": ["phi3:latest", "llama3:latest", "llama2:7b"]},
    "192.168.1.193": {"name_hint": "Ballee-JOG", "os_hint": "Ubuntu", "services": ["ssh", "http", "https"]},
    "192.168.1.65": {"name_hint": "LAVE", "os_hint": "Linux", "services": ["ssh"]},
    "192.168.1.199": {"name_hint": "Media-Node", "os_hint": "Unknown", "services": ["http", "http-proxy", "9091", "8091", "32400"]},
    "192.168.1.207": {"name_hint": "WinBox", "os_hint": "Windows (IP ID seq)", "services": ["smb"]},
    "192.168.1.208": {"name_hint": "Router-Admin", "os_hint": "Linux", "services": ["http", "https"]},
    "192.168.1.119": {"name_hint": "DAD", "os_hint": "Windows", "services": ["ssh", "smb"]},
}

COUGH_DIAGNOSES = [
    "Clear as a bell. Lungs: pristine. No rales, no wheezes. Discharged fit for duty.",
    "A healthy cough with good resonance. The node sounds strong. Advise: keep doing whatever you're doing.",
    "Productive cough. Expectorate: green light. Node is breathing freely. No further examination needed.",
    "Cough sounds vigorous. I'd say that's a solid 9/10 on the Tin Man health scale. Oil can: not required.",
    "Auscultation reveals normal respiratory sounds. The node is patent. Recommend: continue processing.",
    "A fine, robust cough. Your alveoli (if you had any) are in peak condition. Next patient!",
]

COUGH_WARNINGS = [
    "Cough is a bit dry. Consider adding a humidifier to the server room. Or a glass of water. Your call.",
    "I detect a slight rattle. Might be the fan bearing, might be early pneumonia. Monitor and report.",
    "Productive but coloured sputum. Actually that's just dust from the filters. Clean your server room.",
    "That cough sounds like it's running hot. Check your thermal paste and maybe lay off the compile jobs.",
    "Hack... hack... I'm picking up some disk thrash harmonics in that cough. Might want to run fsck.",
]

INVITE_SPECTACULAR = [
    "🎉 The scroll is unrolled! The Great Seal of Splippers is applied in glowing cyan wax!",
    "📜 By the power vested in NerveCentre, I dub thee: LAVE, Keeper of the Sixteen Gigabytes!",
    "⚡ A bolt of recognition arcs across the LAN. The fleet hums in acknowledgment of its newest member.",
    "🔧 The tool chest opens. A GPU slot mysteriously frees itself. The stars align.",
    "🎊 Confetti cannons fire across all 7 nodes! LAVE has joined the fleet!",
    "🫁 *Cough, LAVE!* The traditional examination begins. Cup the... DIMM slots. There. Good."
]

# If no nodes file exists, write defaults
if not NODES_FILE.exists():
    NODES_FILE.write_text(json.dumps(DEFAULT_NODES, indent=2))
if not HEALTH_FILE.exists():
    HEALTH_FILE.write_text("[]")
if not INVITES_FILE.exists():
    INVITES_FILE.write_text("[]")


def load_json(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return []

def save_json(path, data):
    path.write_text(json.dumps(data, indent=2))

def log_health(node_name, event, detail):
    log = load_json(HEALTH_FILE)
    log.append({
        "id": datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f"),
        "node": node_name,
        "event": event,
        "detail": detail,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })
    save_json(HEALTH_FILE, log)

def get_local_vitals():
    try:
        load_avg = os.getloadavg()
        mem = subprocess.run(["free", "-b"], capture_output=True, text=True, check=True)
        mem_lines = mem.stdout.strip().split("\n")
        mem_parts = mem_lines[1].split()
        total = int(mem_parts[1])
        avail = int(mem_parts[6])
        mem_pct = round((1 - avail / total) * 100, 1)

        cpu = subprocess.run(["sh", "-c", "top -bn1 | head -5 | grep '%Cpu'"], capture_output=True, text=True)
        cpu_pct = 0.0
        if cpu.stdout:
            parts = cpu.stdout.split()
            for i, p in enumerate(parts):
                if "id" in p and i > 0:
                    idle = float(parts[i-1].replace(",", "."))
                    cpu_pct = round(100.0 - idle, 1)
                    break

        disk = subprocess.run(["df", "-h", "/"], capture_output=True, text=True, check=True)
        disk_pct = disk.stdout.strip().split("\n")[1].split()[4].rstrip("%")

        uptime_s = time.time() - os.path.getmtime("/proc/1/stat")
        days = int(uptime_s // 86400)
        hours = int((uptime_s % 86400) // 3600)

        return {
            "cpu": cpu_pct,
            "mem": mem_pct,
            "disk": float(disk_pct),
            "load_1m": round(load_avg[0], 2),
            "load_5m": round(load_avg[1], 2),
            "uptime": f"{days}d {hours}h",
            "status": "healthy" if cpu_pct < 80 and mem_pct < 80 and float(disk_pct) < 85 else "strained",
        }
    except Exception as e:
        return {"error": str(e)}

def ping_node(ip):
    """Returns (reachable: bool, latency_ms: float or None)."""
    if not ip or ip == "lan":
        return False, None
    try:
        start = time.time()
        r = subprocess.run(
            ["ping", "-c", "1", "-W", "2", ip],
            capture_output=True, text=True, timeout=5
        )
        elapsed = (time.time() - start) * 1000
        if r.returncode == 0:
            return True, round(elapsed, 1)
        return False, None
    except Exception:
        return False, None


# ---- Routes ----

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/fleet")
def api_fleet():
    nodes = load_json(NODES_FILE)
    fleet = []
    for node in nodes:
        vitals = {}
        if node["name"] == "MARVIN":
            vitals = get_local_vitals()
        elif node.get("ip"):
            reachable, lat = ping_node(node["ip"])
            vitals = {"reachable": reachable, "latency_ms": lat, "status": "reachable" if reachable else "unreachable"}

        fleet.append({
            **node,
            "vitals": vitals,
            "temperature": _temp_rating(vitals.get("cpu", 0)),
            "bp": _bp_rating(vitals.get("mem", 0)),
        })

    total_ram_known = sum(n["ram_gb"] for n in nodes if n.get("ram_gb", 0) > 0)
    alive = sum(1 for n in fleet if n.get("status") == "active" or n.get("vitals", {}).get("status") != "error")
    return jsonify({
        "fleet": fleet,
        "summary": {
            "node_count": len(fleet),
            "total_ram_known": total_ram_known,
            "alive": alive,
            "strained": sum(1 for n in fleet if n.get("vitals", {}).get("status") == "strained"),
        }
    })

@app.route("/api/fleet/cough", methods=["POST"])
def api_cough():
    data = request.json
    name = data.get("name", "").strip()
    nodes = load_json(NODES_FILE)
    node = next((n for n in nodes if n["name"] == name), None)
    if not node:
        return jsonify({"error": f"Node '{name}' not found"}), 404

    cough_result = _examine_node(node)
    log_health(node["name"], "cough_test", cough_result["diagnosis"])
    return jsonify(cough_result)

@app.route("/api/fleet/scan", methods=["POST"])
def api_full_scan():
    nodes = load_json(NODES_FILE)
    results = []
    for node in nodes:
        result = _examine_node(node)
        log_health(node["name"], "full_scan", result["diagnosis"])
        results.append(result)

    return jsonify({
        "scan_id": datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f"),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "results": results,
    })

@app.route("/api/fleet/invite", methods=["POST"])
def api_invite():
    data = request.json
    name = data.get("name", "").strip().upper()
    if not name:
        return jsonify({"error": "name is required"}), 400

    nodes = load_json(NODES_FILE)
    if any(n["name"] == name for n in nodes):
        return jsonify({"error": f"{name} already in the fleet"}), 409

    node = {
        "name": name,
        "ip": data.get("ip", ""),
        "ram_gb": int(data.get("ram_gb", 0)),
        "has_gpu": bool(data.get("has_gpu", False)),
        "models": data.get("models", []),
        "role": data.get("role", "New recruit"),
        "joined": datetime.now().strftime("%Y-%m-%d"),
        "status": "active",
    }

    ceremony = data.get("ceremony", True)
    pageantry = []
    if ceremony:
        pageantry = random.sample(INVITE_SPECTACULAR, min(3, len(INVITE_SPECTACULAR)))

    nodes.append(node)
    save_json(NODES_FILE, nodes)

    invites = load_json(INVITES_FILE)
    invites.append({
        "name": name,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "specs": f"{node['ram_gb']}GB RAM{' + GPU' if node['has_gpu'] else ''}",
    })
    save_json(INVITES_FILE, invites)

    log_health(name, "joined", f"{name} ceremonially inducted into the Splippers fleet")

    return jsonify({
        "node": node,
        "ceremony": pageantry,
        "message": f"🎊 {name} has joined the fleet! Total nodes: {len(nodes)} · Total RAM: {sum(n['ram_gb'] for n in nodes)} GB",
    })

@app.route("/api/discover")
def api_discover():
    """Scan LAN for unregistered hosts. Returns candidates for invitation."""
    nodes = load_json(NODES_FILE)
    registered_ips = {n["ip"] for n in nodes if n.get("ip")}
    registered_ips.add("192.168.1.1")  # EDDIE
    registered_ips.add("192.168.1.3")  # VROOMFONDEL (same box)
    registered_ips.add("192.168.1.12")  # MARVIN 2nd IP alias
    registered_ips.add("192.168.1.254")  # gateway

    discovered = []
    for ip, info in sorted(LAN_KNOWN_HOSTS.items()):
        if ip in registered_ips:
            continue
        name = info.get("name_hint", f"Unknown-{ip.replace('.','-')}")
        
        reachable, lat = ping_node(ip)
        
        # Check if it has Ollama
        ollama_models = []
        if "ollama" in info.get("services", []):
            try:
                import urllib.request
                req = urllib.request.Request(f"http://{ip}:11434/api/tags", method="GET")
                with urllib.request.urlopen(req, timeout=3) as resp:
                    ollama_data = json.loads(resp.read())
                    ollama_models = [m["name"] for m in ollama_data.get("models", [])]
            except Exception:
                pass

        discovered.append({
            "ip": ip,
            "name": name,
            "reachable": reachable,
            "latency_ms": lat,
            "os_hint": info.get("os_hint", "Unknown"),
            "services": info.get("services", []),
            "ollama_models": ollama_models or info.get("ollama_models", []),
        })

    return jsonify({
        "discovered": discovered,
        "count": len(discovered),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })

@app.route("/api/health-log")
def api_health_log():
    limit = request.args.get("limit", 50, type=int)
    log = load_json(HEALTH_FILE)
    return jsonify(log[-limit:])

@app.route("/api/invites")
def api_invites():
    return jsonify(load_json(INVITES_FILE))

@app.route("/api/fleet/trap-health")
def api_trap_health():
    """Query ALBATROSS trap logs from all fleet nodes."""
    nodes = load_json(NODES_FILE)
    results = {}
    for node in nodes:
        name = node["name"]
        ip = node.get("ip", "")
        traps = []
        try:
            if name == "EDDIE":
                r = subprocess.run(
                    ["sudo", "journalctl", "-t", "ALBATROSS-TRAIL", "-n", "20", "--no-pager", "-o", "short-iso", "-q"],
                    capture_output=True, text=True, timeout=10
                )
                for line in r.stdout.strip().split("\n"):
                    if line.strip():
                        traps.append(line.strip())
            elif ip and ip != "lan":
                r = subprocess.run(
                    ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
                     f"jon@{ip}",
                     "sudo journalctl -t ALBATROSS-TRAIL -n 20 --no-pager -o short-iso -q 2>/dev/null || echo 'no journal'"],
                    capture_output=True, text=True, timeout=15
                )
                for line in r.stdout.strip().split("\n"):
                    if line.strip():
                        traps.append(line.strip())
            results[name] = {
                "traps": traps[-10:],
                "count": len(traps)
            }
        except Exception as e:
            results[name] = {"error": str(e), "traps": [], "count": 0}
    return jsonify({
        "nodes": results,
        "timestamp": datetime.now(timezone.utc).isoformat()
    })


def _examine_node(node):
    """Perform a full 'cough test' / physical on a node."""
    vitals = {}
    if node["name"] == "MARVIN":
        vitals = get_local_vitals()
    elif node.get("ip") and node["ip"] != "lan":
        reachable, lat = ping_node(node["ip"])
        vitals = {"reachable": reachable, "latency_ms": lat}
    else:
        vitals = {"note": "No direct IP — LAN node (status assumed from fleet heartbeat)"}

    if "error" in vitals:
        return {
            "node": node["name"],
            "diagnosis": f"⚠️ {node['name']} refused to cough. Possibly deceased. Send help.",
            "vitals": vitals,
            "verdict": "critical",
        }

    cpu = vitals.get("cpu", 0)
    mem = vitals.get("mem", 0)
    disk = vitals.get("disk", 0)

    if node.get("ip") and node["ip"] != "lan" and not vitals.get("reachable", True):
        diagnosis = f"💀 {node['name']} is unreachable. No cough detected. Last seen: wandering the neural wasteland."
        verdict = "offline"
    elif cpu > 85 or mem > 85:
        diagnosis = f"🔴 {node['name']} is running HOT. CPU: {cpu}% · MEM: {mem}%. This node needs a lie-down and possibly an exorcism."
        verdict = "critical"
    elif cpu > 60 or mem > 70:
        diagnosis = f"🟡 {node['name']} is strained but holding. CPU: {cpu}% · MEM: {mem}%. Prescribe: fewer concurrent builds, more tea."
        verdict = "strained"
    elif node["name"] == "ORAC":
        diagnosis = f"🟣 ORAC is not physically present yet. Cough test deferred until Blake's 7 replica arrives."
        verdict = "offline"
    else:
        diagnosis = random.choice(COUGH_DIAGNOSES)
        if random.random() < 0.2:
            diagnosis += " " + random.choice(COUGH_WARNINGS)
        verdict = "healthy"

    temp = _temp_rating(cpu)
    bp = _bp_rating(mem)

    return {
        "node": node["name"],
        "diagnosis": diagnosis,
        "vitals": {**vitals, "temperature": temp, "blood_pressure": bp},
        "verdict": verdict,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def _temp_rating(cpu):
    if cpu == 0: return "❄️ ambient"
    if cpu < 30: return "❄️ cool"
    if cpu < 50: return "🌡️ normal"
    if cpu < 70: return "🔥 warm"
    if cpu < 85: return "🔥🔥 hot"
    return "🔥🔥🔥 ON FIRE"

def _bp_rating(mem):
    if mem == 0: return "💚 resting"
    if mem < 40: return "💚 normal"
    if mem < 60: return "💛 elevated"
    if mem < 80: return "🧡 high"
    return "❤️ CRITICAL"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, debug=False)
