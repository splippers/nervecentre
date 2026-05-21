#!/usr/bin/env python3
"""Hardware Resources Portal — fleet inventory, load monitoring, bottleneck view."""

import json
import os
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


DATA_DIR = Path(os.environ.get("HW_DATA_DIR", "/home/jon/.hardwareportal"))
NODES_FILE = DATA_DIR / "nodes.json"
ALLOCS_FILE = DATA_DIR / "allocations.json"
PORT = int(os.environ.get("HW_PORTAL_PORT", 8088))

DATA_DIR.mkdir(parents=True, exist_ok=True)

# Default fleet spec from UNIVERSE_UNDERSTANDING
DEFAULT_NODES = [
    {"name": "MARVIN", "ip": "192.168.1.2", "ram_gb": 32, "has_gpu": True, "models": ["Qwen2.5-32B", "DeepSeek-Coder", "Mixtral"], "role": "Heavy inference + NFS/SMB hub"},
    {"name": "HP-ProDesk-16G-1", "ip": "lan", "ram_gb": 16, "has_gpu": False, "models": ["Llama-3.1-8B", "Qwen2.5-14B"], "role": "Medium models"},
    {"name": "HP-ProDesk-16G-2", "ip": "lan", "ram_gb": 16, "has_gpu": False, "models": ["Llama-3.1-8B", "Qwen2.5-14B"], "role": "Medium models"},
    {"name": "HP-ProDesk-12G-1", "ip": "lan", "ram_gb": 12, "has_gpu": False, "models": ["Llama-3.2-3B", "Mistral-7B", "Phi-3"], "role": "Small/fast models"},
    {"name": "HP-ProDesk-12G-2", "ip": "lan", "ram_gb": 12, "has_gpu": False, "models": ["Llama-3.2-3B", "Mistral-7B", "Phi-3"], "role": "Small/fast models"},
    {"name": "HP-ProDesk-12G-3", "ip": "lan", "ram_gb": 12, "has_gpu": False, "models": ["Llama-3.2-3B", "Mistral-7B", "Phi-3"], "role": "Small/fast models"},
    {"name": "EDDIE", "ip": "192.168.1.1", "ram_gb": 32, "has_gpu": False, "models": ["Host", "Control plane"], "role": "NerveCentre host - LAN control plane"},
]

NODE_WEIGHTS = {
    "MARVIN": 5, "HP-ProDesk-16G-1": 3, "HP-ProDesk-16G-2": 3,
    "HP-ProDesk-12G-1": 2, "HP-ProDesk-12G-2": 2, "HP-ProDesk-12G-3": 2,
    "ORAC": 1,
}

if not NODES_FILE.exists():
    NODES_FILE.write_text(json.dumps(DEFAULT_NODES, indent=2))
if not ALLOCS_FILE.exists():
    ALLOCS_FILE.write_text("[]")

# ---- Data helpers ----

def load_json(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return []

def save_json(path, data):
    path.write_text(json.dumps(data, indent=2))

def get_local_load():
    """Get local system load metrics."""
    try:
        load_avg = os.getloadavg()
        mem = subprocess.run(
            ["free", "-b"], capture_output=True, text=True, check=True
        )
        mem_lines = mem.stdout.strip().split("\n")
        mem_parts = mem_lines[1].split()
        total = int(mem_parts[1])
        avail = int(mem_parts[6])
        mem_used_pct = round((1 - avail / total) * 100, 1)

        cpu_line = subprocess.run(
            ["sh", "-c", "top -bn1 | head -5 | grep '%Cpu'"],
            capture_output=True, text=True
        )
        cpu_pct = 0.0
        if cpu_line.stdout:
            parts = cpu_line.stdout.split()
            for i, p in enumerate(parts):
                if "id" in p and i > 0:
                    idle = float(parts[i-1].replace(",", "."))
                    cpu_pct = round(100.0 - idle, 1)
                    break

        disk = subprocess.run(
            ["df", "-h", "/"], capture_output=True, text=True, check=True
        )
        disk_pct = disk.stdout.strip().split("\n")[1].split()[4].rstrip("%")

        return {
            "load_1m": round(load_avg[0], 2),
            "load_5m": round(load_avg[1], 2),
            "load_15m": round(load_avg[2], 2),
            "mem_used_pct": mem_used_pct,
            "cpu_used_pct": cpu_pct,
            "disk_used_pct": disk_pct,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
    except Exception as e:
        return {"error": str(e)}

def compute_bottleneck_score(node, load=None):
    """Heuristic: 0-100 where higher = more bottlenecked."""
    if load is None:
        load = {}
    score = 0
    if load.get("cpu_used_pct", 0) > 80:
        score += 30
    elif load.get("cpu_used_pct", 0) > 60:
        score += 15
    if load.get("mem_used_pct", 0) > 80:
        score += 30
    elif load.get("mem_used_pct", 0) > 60:
        score += 15
    if load.get("disk_used_pct", 0) and float(load["disk_used_pct"].rstrip("%")) > 80:
        score += 20
    if load.get("load_1m", 0) > node.get("ram_gb", 8) * 0.5:
        score += 20
    return score

# ---- Routes ----

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/api/nodes")
def api_nodes():
    nodes = load_json(NODES_FILE)
    results = []
    for node in nodes:
        load = {}
        if node["name"] == "MARVIN" or node.get("ip") == "127.0.0.1":
            load = get_local_load()
        else:
            load = {"note": f"Remote node — local load only available on this host"}
        score = compute_bottleneck_score(node, load)
        results.append({**node, "load": load, "bottleneck_score": score})
    return jsonify(results)

@app.route("/api/nodes", methods=["POST"])
def api_add_node():
    data = request.json
    if not data or not data.get("name"):
        return jsonify({"error": "name is required"}), 400
    nodes = load_json(NODES_FILE)
    if any(n["name"] == data["name"] for n in nodes):
        return jsonify({"error": "node already exists"}), 409
    node = {
        "name": data["name"],
        "ip": data.get("ip", "lan"),
        "ram_gb": int(data.get("ram_gb", 8)),
        "has_gpu": bool(data.get("has_gpu", False)),
        "models": data.get("models", []),
        "role": data.get("role", ""),
    }
    nodes.append(node)
    save_json(NODES_FILE, nodes)
    return jsonify(node), 201

@app.route("/api/nodes/<name>", methods=["PUT"])
def api_update_node(name):
    data = request.json
    if not data:
        return jsonify({"error": "no data"}), 400
    nodes = load_json(NODES_FILE)
    for n in nodes:
        if n["name"] == name:
            for key in ("ip", "ram_gb", "has_gpu", "models", "role"):
                if key in data:
                    n[key] = data[key]
            save_json(NODES_FILE, nodes)
            return jsonify(n)
    return jsonify({"error": "not found"}), 404

@app.route("/api/nodes/<name>", methods=["DELETE"])
def api_delete_node(name):
    nodes = load_json(NODES_FILE)
    nodes = [n for n in nodes if n["name"] != name]
    save_json(NODES_FILE, nodes)
    return jsonify({"status": "deleted"})

@app.route("/api/allocations")
def api_allocations():
    return jsonify(load_json(ALLOCS_FILE))

@app.route("/api/allocations", methods=["POST"])
def api_create_allocation():
    data = request.json
    if not data or not data.get("project") or not data.get("node"):
        return jsonify({"error": "project and node are required"}), 400
    allocs = load_json(ALLOCS_FILE)
    alloc = {
        "id": datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f"),
        "project": data["project"],
        "node": data["node"],
        "model": data.get("model", ""),
        "workload": data.get("workload", "inference"),
        "status": "active",
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    allocs.append(alloc)
    save_json(ALLOCS_FILE, allocs)
    return jsonify(alloc), 201

@app.route("/api/allocations/<alloc_id>", methods=["DELETE"])
def api_delete_allocation(alloc_id):
    allocs = load_json(ALLOCS_FILE)
    allocs = [a for a in allocs if a["id"] != alloc_id]
    save_json(ALLOCS_FILE, allocs)
    return jsonify({"status": "deleted"})

@app.route("/api/rebalance")
def api_rebalance():
    """Suggest workload redistribution based on load and capacity."""
    nodes = load_json(NODES_FILE)
    allocs = load_json(ALLOCS_FILE)
    suggestions = []

    for node in nodes:
        load = {}
        if node["name"] == "MARVIN":
            load = get_local_load()
        if not load:
            continue
        score = compute_bottleneck_score(node, load)
        if score >= 30:
            node_allocs = [a for a in allocs if a["node"] == node["name"] and a["status"] == "active"]
            underused = [n for n in nodes if n["name"] != node["name"] and n["ram_gb"] >= node["ram_gb"] * 0.7 and compute_bottleneck_score(n, {}) < 20]
            suggestions.append({
                "bottlenecked_node": node["name"],
                "bottleneck_score": score,
                "load": load,
                "active_allocations": len(node_allocs),
                "suggested_targets": [n["name"] for n in underused[:3]],
                "reason": f"CPU {load.get('cpu_used_pct', '?')}% / MEM {load.get('mem_used_pct', '?')}% — move workloads to less loaded nodes",
            })

    return jsonify({
        "nodes": len(nodes),
        "active_allocations": len([a for a in allocs if a["status"] == "active"]),
        "bottlenecks": len(suggestions),
        "suggestions": suggestions,
    })

@app.route("/api/load")
def api_local_load():
    return jsonify(get_local_load())

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, debug=False)
