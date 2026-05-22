#!/usr/bin/env python3
"""Sysload Portal — near-live HTOP-style metrics from all compatible LAN hosts."""

import json, os, subprocess, time
from datetime import datetime, timezone
from pathlib import Path
from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

_PORTAL_SECRET = os.environ.get("PORTAL_SECRET", "")
if not _PORTAL_SECRET:
    raise RuntimeError("PORTAL_SECRET env var must be set")

@app.before_request
def _require_portal_secret():
    auth = request.headers.get("Authorization", "")
    token = auth.removeprefix("Bearer ").strip()
    if token != _PORTAL_SECRET:
        return jsonify({"error": "Unauthorized"}), 401

PORT = int(os.environ.get("SYSLOAD_PORT", 8095))
CACHE_TTL = float(os.environ.get("SYSLOAD_CACHE_TTL", "2"))

_cache = {}
_cache_ts = 0.0

NODES = [
    {"name": "EDDIE", "ip": "192.168.1.1", "host": "jon@192.168.1.1"},
    {"name": "MARVIN", "ip": "192.168.1.2", "host": "jon@192.168.1.2"},
    {"name": "LAVE",  "ip": "192.168.1.65", "host": "jon@192.168.1.65"},
]

SSH_CMD = ("cat /proc/loadavg; echo '---'; "
           "free -b; echo '---'; "
           "head -5 /proc/stat; echo '---'; "
           "df -h / 2>/dev/null | tail -1; echo '---'; "
           "uptime -p 2>/dev/null; echo '---'; "
           "ps -eo pid,pcpu,pmem,rss,comm --sort=-pcpu 2>/dev/null | head -12")


def _ssh_collect(host):
    try:
        r = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
             "-o", "BatchMode=yes", "-o", "ControlMaster=auto",
             "-o", "ControlPath=/tmp/ssh-%r@%h:%p", "-o", "ControlPersist=30",
             host, SSH_CMD],
            capture_output=True, text=True, timeout=10
        )
        if r.returncode != 0:
            return {"error": r.stderr.strip() or f"exit code {r.returncode}"}
        return _parse_output(r.stdout)
    except subprocess.TimeoutExpired:
        return {"error": "SSH timeout (10s)"}
    except Exception as e:
        return {"error": str(e)}


def _parse_output(text):
    sections = text.strip().split("---")
    while len(sections) < 6:
        sections.append("")

    out = {}

    load_str = sections[0].strip()
    if load_str:
        parts = load_str.split()
        if len(parts) >= 3:
            out["load_1m"] = float(parts[0])
            out["load_5m"] = float(parts[1])
            out["load_15m"] = float(parts[2])
        if len(parts) >= 5:
            out["running"] = int(parts[3].split("/")[0])
            out["total_procs"] = int(parts[3].split("/")[1])

    mem_str = sections[1].strip()
    if mem_str:
        lines = mem_str.split("\n")
        if len(lines) >= 2:
            parts = lines[1].split()
            if len(parts) >= 7:
                total = int(parts[1])
                avail = int(parts[6])
                out["mem_total_gb"] = round(total / (1024**3), 1)
                out["mem_used_pct"] = round((1 - avail / total) * 100, 1)
                out["mem_used_gb"] = round((total - avail) / (1024**3), 1)
                out["mem_avail_gb"] = round(avail / (1024**3), 1)

            if len(lines) >= 3:
                sparts = lines[2].split()
                if len(sparts) >= 3:
                    out["swap_total_gb"] = round(int(sparts[1]) / (1024**3), 1)
                    out["swap_used_gb"] = round(int(sparts[2]) / (1024**3), 1)
                    out["swap_used_pct"] = round(
                        (int(sparts[2]) / int(sparts[1]) * 100) if int(sparts[1]) > 0 else 0, 1
                    )

    cpu_str = sections[2].strip()
    if cpu_str:
        total = user = nice = system = idle = 0
        lines = cpu_str.split("\n")
        for line in lines:
            if line.startswith("cpu "):
                parts = line.split()
                if len(parts) >= 5:
                    user = int(parts[1])
                    nice = int(parts[2])
                    system = int(parts[3])
                    idle = int(parts[4])
                    total = user + nice + system + idle + sum(int(x) for x in parts[5:8] if x.isdigit())
                break
        if total > 0:
            out["cpu_user_pct"] = round(user / total * 100, 1)
            out["cpu_sys_pct"] = round(system / total * 100, 1)
            out["cpu_idle_pct"] = round(idle / total * 100, 1)
            out["cpu_used_pct"] = round((1 - idle / total) * 100, 1)
            out["cpu_cores"] = len([l for l in cpu_str.split("\n") if l.startswith("cpu") and l[3].isdigit()])

    disk_str = sections[3].strip()
    if disk_str:
        parts = disk_str.split()
        if len(parts) >= 5:
            out["disk_used_pct"] = parts[4].rstrip("%")
            out["disk_total"] = parts[1]
            out["disk_used"] = parts[2]
            out["disk_avail"] = parts[3]
            out["disk_mount"] = parts[5] if len(parts) > 5 else "/"

    uptime_str = sections[4].strip()
    if uptime_str:
        out["uptime"] = uptime_str.replace("up ", "")

    procs_str = sections[5].strip()
    if procs_str:
        procs = []
        for line in procs_str.split("\n"):
            p = line.strip().split(None, 4)
            if len(p) == 5 and p[0].isdigit():
                try:
                    procs.append({
                        "pid": int(p[0]),
                        "cpu": float(p[1]),
                        "mem": float(p[2]),
                        "rss_mb": round(int(p[3]) / 1024, 1),
                        "cmd": p[4][:40],
                    })
                except (ValueError, IndexError):
                    pass
        out["top_procs"] = procs[:10]
    else:
        out["top_procs"] = []

    return out


def _collect_all():
    global _cache, _cache_ts
    now = time.time()
    if _cache and (now - _cache_ts) < CACHE_TTL:
        return _cache

    results = []
    for node in NODES:
        start = time.time()
        data = _ssh_collect(node["host"])
        elapsed = round((time.time() - start) * 1000)
        results.append({**node, "metrics": data, "fetch_ms": elapsed})
    _cache = {"nodes": results, "ts": datetime.now(timezone.utc).isoformat(), "fetched_ms": time.time() * 1000}
    _cache_ts = now
    return _cache


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/sysload")
def api_sysload():
    return jsonify(_collect_all())


@app.route("/api/sysload/refresh")
def api_sysload_refresh():
    global _cache, _cache_ts
    _cache = {}
    _cache_ts = 0
    return jsonify(_collect_all())


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, debug=False)
