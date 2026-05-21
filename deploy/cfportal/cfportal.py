#!/usr/bin/env python3
"""
Cloudflare Tunnel setup — fully self-contained via API token.

No cert.pem, no browser login, no external machine needed.
Everything uses Cloudflare's REST API + constructs proper
credentials.json from the tunnel token JWT for cloudflared tunnel run.
"""

import base64
import json
import os
import secrets
import subprocess
import string
from pathlib import Path

import requests
import yaml
from flask import Flask, jsonify, render_template, request

app = Flask(__name__)
app.secret_key = os.urandom(32)

_PORTAL_SECRET = os.environ.get("PORTAL_SECRET", "")
if not _PORTAL_SECRET:
    raise RuntimeError("PORTAL_SECRET env var must be set — refusing to start without auth")


@app.before_request
def _require_portal_secret():
    auth = request.headers.get("Authorization", "")
    token = auth.removeprefix("Bearer ").strip()
    if token != _PORTAL_SECRET:
        return jsonify({"error": "Unauthorized"}), 401


CF_API = "https://api.cloudflare.com/client/v4"
TUNNEL_DIR = Path("/etc/cloudflared")
STATE_DIR = Path("/tmp/cfportal-uploads")

TUNNEL_NAME = "nc-splippers"
HOSTNAME = "nc.splippers.com"
SVC_NAME = "cloudflared-nc-splippers"
CFPORTAL_USER = os.environ.get("CFPORTAL_USER", "jon")
CFPORTAL_PORT = int(os.environ.get("CFPORTAL_PORT", 8085))

STATE_DIR.mkdir(parents=True, exist_ok=True)
TUNNEL_DIR.mkdir(parents=True, exist_ok=True)

CLOUDFLARED_BIN = subprocess.run(
    ["which", "cloudflared"], capture_output=True, text=True
).stdout.strip() or "/usr/local/bin/cloudflared"


# ── helpers ─────────────────────────────────────────────────────────────────

def _r(key: str) -> str | None:
    p = STATE_DIR / key
    return p.read_text().strip() if p.exists() else None

def _w(key: str, val: str):
    (STATE_DIR / key).write_text(val)

def _marker(name: str) -> bool:
    return (STATE_DIR / f"step_{name}").exists()

def _set_marker(name: str):
    (STATE_DIR / f"step_{name}").touch()

def _token() -> str | None:
    return _r("api_token.txt")

def _head(token: str | None = None) -> dict:
    return {"Authorization": f"Bearer {token or _token()}", "Content-Type": "application/json"}

def _cf_get(path: str, token: str | None = None) -> dict | None:
    r = requests.get(f"{CF_API}/{path.lstrip('/')}", headers=_head(token), timeout=15)
    return r.json() if r.ok else None

def _cf_post(path: str, body: dict, token: str | None = None) -> dict | None:
    r = requests.post(f"{CF_API}/{path.lstrip('/')}", headers=_head(token), json=body, timeout=15)
    return r.json() if r.ok else None

def _jwt_decode(jwt: str) -> dict:
    try:
        b64 = jwt.split(".")[1]
        pad = 4 - len(b64) % 4
        if pad != 4: b64 += "=" * pad
        return json.loads(base64.urlsafe_b64decode(b64))
    except Exception:
        return {}

def _gen_cred_file(account_id: str, tunnel_id: str, tunnel_secret: str):
    creds = {
        "AccountTag": account_id,
        "TunnelID": tunnel_id,
        "TunnelName": TUNNEL_NAME,
        "TunnelSecret": tunnel_secret,
    }
    p = TUNNEL_DIR / "credentials.json"
    p.write_text(json.dumps(creds, indent=2))
    p.chmod(0o600)

def _write_config():
    cfg = {
        "tunnel": TUNNEL_NAME,
        "credentials-file": str(TUNNEL_DIR / "credentials.json"),
        "ingress": [
            {"hostname": HOSTNAME, "service": "https://localhost:443"},
            {"service": "http_status:404"},
        ],
    }
    (TUNNEL_DIR / "config.yml").write_text(yaml.dump(cfg, default_flow_style=False))

def _rand_suffix(n=6):
    return "".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(n))


# ── status ───────────────────────────────────────────────────────────────────

def get_tunnel_status():
    steps = {
        "token": {
            "title": "Paste API token",
            "done": bool(_token()),
            "label": "✓ Saved" if _token() else "Pending",
            "detail": f"{len(_token())} chars" if _token() else "",
        },
        "discover": {
            "title": "Discover account & zone",
            "done": bool(_r("account_id")),
            "label": "✓ Done" if _r("account_id") else "Pending",
            "detail": (f"Account: {_r('account_name')}  Zone: {_r('zone_name') or _r('zone_id')}"
                       if _r("account_id") else ""),
        },
        "tunnel": {
            "title": "Create Tunnel",
            "done": _marker("tunnel"),
            "label": "✓ Created" if _marker("tunnel") else "Pending",
            "detail": f"Tunnel {TUNNEL_NAME} registered" if _marker("tunnel") else
                      f"Registers tunnel {TUNNEL_NAME} with Cloudflare",
        },
        "dns": {
            "title": "DNS: nc.splippers.com",
            "done": _marker("dns"),
            "label": "✓ Configured" if _marker("dns") else "Pending",
            "detail": "CNAME record created" if _marker("dns") else "Creates CNAME → tunnel via CF API",
        },
        "service": {
            "title": "Install systemd service",
            "done": _marker("service"),
            "label": "✓ Installed" if _marker("service") else "Pending",
            "detail": "Runs tunnel daemon on boot",
        },
        "verify": {
            "title": "Verify",
            "done": False,
            "label": "Pending",
            "detail": "Check tunnel is running",
        },
    }

    if _marker("service"):
        s = subprocess.run(["systemctl", "is-active", SVC_NAME],
                           capture_output=True, text=True)
        if s.returncode == 0:
            steps["verify"]["done"] = True
            steps["verify"]["label"] = "✓ Running"
            steps["verify"]["detail"] = "systemd service is active"

    return steps


# ── routes ───────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html", steps=get_tunnel_status())


@app.route("/api/status")
def api_status():
    return jsonify(get_tunnel_status())


@app.route("/api/upload", methods=["POST"])
def api_upload():
    ftype = request.form.get("type", "")
    if ftype == "api_token":
        t = request.form.get("token", "").strip()
        if not t:
            return jsonify({"error": "Token is empty"}), 400
        _w("api_token.txt", t)
        return jsonify({"status": "ok", "message": "API token saved"})
    if ftype == "support_details":
        _w("support_details.txt", request.form.get("text", "").strip())
        return jsonify({"status": "ok", "message": "Support details saved"})
    if ftype == "zone_id":
        zid = request.form.get("zone_id", "").strip()
        if not zid:
            return jsonify({"error": "Zone ID is empty"}), 400
        _w("zone_id", zid)
        _w("zone_name", f"manual-{_rand_suffix()}")
        return jsonify({"status": "ok", "message": f"Zone ID saved: {zid}"})
    if ftype == "cert_pem":
        if "file" not in request.files:
            return jsonify({"error": "No file uploaded"}), 400
        request.files["file"].save(str(TUNNEL_DIR / "cert.pem"))
        return jsonify({"status": "ok", "message": "cert.pem saved"})
    return jsonify({"error": "Unknown upload type"}), 400


@app.route("/api/discover", methods=["POST"])
def api_discover():
    token = _token()
    if not token:
        return jsonify({"error": "No API token saved yet"}), 400

    ad = _cf_get("accounts", token)
    if not ad or not ad.get("success"):
        return jsonify({"error": "Token rejected. Needs Account:Read permission."}), 400
    accts = ad.get("result", [])
    if not accts:
        return jsonify({"error": "Token has no account access."}), 400

    aid = accts[0]["id"]
    aname = accts[0]["name"]
    _w("account_id", aid)
    _w("account_name", aname)

    # Discover zone
    zid = None
    zname = None
    for candidate in ["splippers.com", "project6x7.com"]:
        zd = _cf_get(f"zones?name={candidate}", token)
        if zd and zd.get("success") and zd.get("result"):
            zid = zd["result"][0]["id"]
            zname = candidate
            break
    if not zid:
        zd = _cf_get("zones?per_page=50", token)
        if zd and zd.get("success"):
            for z in zd.get("result", []):
                if "splippers" in z["name"] or "project6x7" in z["name"]:
                    zid, zname = z["id"], z["name"]
                    break

    msg = f"Account: {aname}"
    if zid:
        _w("zone_id", zid)
        _w("zone_name", zname or zid)
        msg += f"  Zone: {zname or zid}"
    else:
        _w("zone_id", "MANUAL")
        msg += "  Zone: not auto-discovered (provide zone_id in support box)"

    return jsonify({
        "status": "ok", "message": msg,
        "account_id": aid, "account_name": aname,
        "zone_id": zid, "zone_name": zname,
    })


@app.route("/api/run/<step>", methods=["POST"])
def api_run(step):
    token = _token()
    if not token:
        return jsonify({"error": "Save API token first"}), 400

    if step == "tunnel":
        acct = _r("account_id")
        if not acct:
            return jsonify({"error": "Discover account first"}), 400

        # Delete existing tunnel with same name (if any)
        existing = _cf_get(f"accounts/{acct}/cfd_tunnel?name={TUNNEL_NAME}", token)
        if existing and existing.get("success"):
            for t in existing.get("result", []):
                if t.get("name") == TUNNEL_NAME and not t.get("deleted"):
                    tid_old = t["id"]
                    requests.delete(
                        f"{CF_API}/accounts/{acct}/cfd_tunnel/{tid_old}",
                        headers=_head(token), timeout=15,
                    )

        r = _cf_post(f"accounts/{acct}/cfd_tunnel",
                     {"name": TUNNEL_NAME, "config_src": "local"}, token)
        if not r or not r.get("success"):
            msg = r.get("errors", [{}])[0].get("message", "API error") if r else "API unreachable"
            return jsonify({"error": f"Tunnel creation failed: {msg}"}), 500

        tid = r["result"]["id"]
        tok = r["result"]["token"]
        _w("tunnel_id", tid)
        _w("tunnel_token", tok)
        _set_marker("tunnel")

        # Decode JWT to extract tunnel secret
        payload = _jwt_decode(tok)
        secret = payload.get("t") or payload.get("tunnel_secret") or ""

        # Write credentials.json and config.yml
        _gen_cred_file(acct, tid, secret)
        _write_config()

        return jsonify({"status": "ok", "message": f"Tunnel {TUNNEL_NAME} created",
                        "tunnel_id": tid})

    if step == "dns":
        zone = _r("zone_id")
        if not zone or zone == "MANUAL":
            return jsonify({"error": "Zone ID unknown. Use support box to provide it."}), 400
        tid = _r("tunnel_id")
        if not tid:
            return jsonify({"error": "Create tunnel first"}), 400
        cname = f"{tid}.cfargotunnel.com"

        r = _cf_post(f"zones/{zone}/dns_records", {
            "type": "CNAME", "name": "nc", "content": cname,
            "ttl": 120, "proxied": True,
        }, token)
        if not r or not r.get("success"):
            msg = r.get("errors", [{}])[0].get("message", "API error") if r else "API unreachable"
            return jsonify({"error": f"DNS record failed: {msg}"}), 500

        _set_marker("dns")
        return jsonify({"status": "ok", "message": f"DNS CNAME nc.splippers.com → {cname}"})

    if step == "service":
        if not (TUNNEL_DIR / "credentials.json").exists():
            return jsonify({"error": "Create tunnel first (no credentials.json)"}), 400

        unit = f"""[Unit]
Description=Cloudflare Tunnel — {HOSTNAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={CFPORTAL_USER}
ExecStart={CLOUDFLARED_BIN} tunnel run --config {TUNNEL_DIR}/config.yml {TUNNEL_NAME}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""
        (Path("/etc/systemd/system") / f"{SVC_NAME}.service").write_text(unit)
        subprocess.run(["systemctl", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "enable", "--now", SVC_NAME], capture_output=True)
        _set_marker("service")

        # Also symlink config dir so root's ~/.cloudflared works
        root_cf = Path("/root/.cloudflared")
        if not root_cf.exists():
            root_cf.parent.mkdir(parents=True, exist_ok=True)
            root_cf.symlink_to(TUNNEL_DIR)

        return jsonify({"status": "ok", "message": "systemd service installed and started"})

    return jsonify({"error": f"Unknown step: {step}"}), 400


@app.route("/api/config")
def api_config():
    return jsonify({
        "account_id": _r("account_id"),
        "account_name": _r("account_name"),
        "zone_id": _r("zone_id"),
        "zone_name": _r("zone_name"),
        "tunnel_id": _r("tunnel_id"),
        "token_saved": bool(_token()),
        "support_details": _r("support_details.txt"),
        "steps": {k: _marker(k) for k in ("tunnel", "dns", "service")},
    })


@app.route("/api/retry/step", methods=["POST"])
def api_retry_step():
    """Clear a step marker so user can retry."""
    step = request.form.get("step", "")
    if step in ("tunnel", "dns", "service"):
        p = STATE_DIR / f"step_{step}"
        p.unlink(missing_ok=True)
        return jsonify({"status": "ok", "message": f"Step '{step}' reset"})
    return jsonify({"error": f"Unknown step: {step}"}), 400


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=CFPORTAL_PORT, debug=False)
