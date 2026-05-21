#!/usr/bin/env python3
"""VPN Portal — WireGuard peer management for the Splippers LAN."""

import os
import re
import subprocess
import time
from pathlib import Path

import qrcode
from flask import (Flask, jsonify, redirect, render_template, request,
                   session, url_for)
from io import BytesIO
from base64 import b64encode
from ldap3 import Connection, Server, NTLM, ALL

app = Flask(__name__)

_PORTAL_SECRET = os.environ.get("PORTAL_SECRET", "")
if not _PORTAL_SECRET:
    raise RuntimeError("PORTAL_SECRET env var must be set — refusing to start without auth")

app.secret_key = _PORTAL_SECRET

_LDAP_URL  = os.environ.get("LDAP_URL", "ldap://192.168.1.1:389")
_LDAP_DOMAIN = os.environ.get("LDAP_DOMAIN", "CORP")

WG_CONTAINER = os.environ.get("WG_CONTAINER", "wireguard")
WG_CONF_PATH = os.environ.get("WG_CONF_PATH", "/home/jon/Projects/docker-wireguard/config")
WG_SUBNET = os.environ.get("WG_SUBNET", "10.13.13")
WG_ENDPOINT = os.environ.get("WG_ENDPOINT", "splippers.hopto.org:51820")
WG_SERVER_PUBKEY = os.environ.get("WG_SERVER_PUBKEY", "fYRDkIU2FeM254nZq8A6UVa4YMiahndPTOaRa6uFjA0=")
WG_DNS = os.environ.get("WG_DNS", "1.1.1.1")

CONF_DIR = Path(WG_CONF_PATH)

_SKIP_AUTH = {"/login"}


def _is_authed():
    if session.get("authed"):
        return True
    auth = request.headers.get("Authorization", "")
    return auth.removeprefix("Bearer ").strip() == _PORTAL_SECRET


@app.before_request
def _require_auth():
    if request.path in _SKIP_AUTH:
        return
    if not _is_authed():
        if request.accept_mimetypes.accept_html:
            return redirect(url_for("login", next=request.path))
        return jsonify({"error": "Unauthorized"}), 401


def _ldap_authenticate(username, password):
    """Return True if username+password are valid AD credentials."""
    try:
        server = Server(_LDAP_URL, get_info=ALL)
        conn = Connection(server, user=f"{_LDAP_DOMAIN}\\{username}",
                          password=password, authentication=NTLM, auto_bind=True)
        conn.unbind()
        return True
    except Exception:
        return False


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        if username and password and _ldap_authenticate(username, password):
            session["authed"] = True
            session["username"] = username
            session.permanent = True
            return redirect(request.args.get("next") or url_for("index"))
        error = "Invalid credentials."
    return render_template("login.html", error=error)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


def docker_exec(*args):
    return subprocess.run(
        ["docker", "exec", WG_CONTAINER, *args],
        capture_output=True, text=True, check=True
    )


def wg_show():
    result = subprocess.run(
        ["docker", "exec", WG_CONTAINER, "wg", "show", "wg0", "dump"],
        capture_output=True, text=True, check=True
    )
    lines = result.stdout.strip().split("\n")
    if not lines:
        return [], None

    header = lines[0].split("\t")
    interface = {
        "private_key": header[1],
        "public_key": header[2],
        "listen_port": header[3],
    }

    peers = []
    for line in lines[1:]:
        if not line.strip():
            continue
        parts = line.split("\t")
        peer = {
            "public_key": parts[0],
            "preshared_key": parts[1],
            "endpoint": parts[2],
            "allowed_ips": parts[3],
            "latest_handshake": int(parts[4]) if parts[4] else 0,
            "transfer_rx": int(parts[5]) if parts[5] else 0,
            "transfer_tx": int(parts[6]) if parts[6] else 0,
            "alive": False,
        }
        now = int(time.time())
        if peer["latest_handshake"] > 0:
            age = now - peer["latest_handshake"]
            peer["alive"] = age < 180
            peer["handshake_age"] = _fmt_duration(age)
        else:
            peer["handshake_age"] = "never"
        peers.append(peer)
    return peers, interface


def _fmt_duration(seconds):
    if seconds < 60:
        return f"{seconds}s"
    elif seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    elif seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
    else:
        return f"{seconds // 86400}d {(seconds % 86400) // 3600}h"


def get_used_ips():
    conf_path = CONF_DIR / "wg_confs" / "wg0.conf"
    if not conf_path.exists():
        return set()
    used = set()
    for m in re.finditer(rf"{WG_SUBNET}\.(\d+)", conf_path.read_text()):
        used.add(int(m.group(1)))
    return used


def get_next_ip():
    used = get_used_ips()
    for i in range(2, 255):
        if i not in used:
            return f"{WG_SUBNET}.{i}/32"
    return None


def peer_configs_on_disk():
    peers = []
    for d in sorted(CONF_DIR.iterdir()):
        if d.name.startswith("peer_") and d.is_dir():
            name = d.name[5:]
            pubkey_file = d / f"publickey-{d.name}"
            peers.append({
                "name": name,
                "dir": d.name,
                "has_pubkey": pubkey_file.exists(),
                "pubkey": pubkey_file.read_text().strip() if pubkey_file.exists() else "",
            })
    return peers


def add_peer_to_wg_conf(name, pubkey, psk, ip):
    conf_path = CONF_DIR / "wg_confs" / "wg0.conf"
    stanza = f"\n[Peer]\n# peer_{name}\nPublicKey = {pubkey}\nPresharedKey = {psk}\nAllowedIPs = {ip}\n"
    with open(conf_path, "a") as f:
        f.write(stanza)


def remove_peer_from_wg_conf(pubkey):
    conf_path = CONF_DIR / "wg_confs" / "wg0.conf"
    text = conf_path.read_text()
    lines = text.split("\n")
    new_lines = []
    skip = False
    for line in lines:
        if line.startswith("[Peer]"):
            skip = False
        if skip:
            continue
        if pubkey in line:
            skip = True
            continue
        new_lines.append(line)
    conf_path.write_text("\n".join(new_lines) + "\n")


def reload_wireguard():
    subprocess.run(
        ["docker", "exec", WG_CONTAINER, "sh", "-c",
         "wg syncconf wg0 <(wg-quick strip /etc/wireguard/wg0.conf)"],
        capture_output=True, text=True)


def refresh_wireguard():
    subprocess.run(["docker", "exec", WG_CONTAINER, "refresh"],
                   capture_output=True, text=True)


def gen_qr_b64(text):
    img = qrcode.make(text)
    buf = BytesIO()
    img.save(buf, format="PNG")
    return b64encode(buf.getvalue()).decode()


def wireguard_uri(client_conf, name):
    from urllib.parse import quote
    b64 = b64encode(client_conf.encode()).decode()
    return f"wireguard://import/{b64}#{quote(name)}"


def build_client_config(name, privkey, address, dns, endpoint, server_pubkey, psk):
    return (
        f"[Interface]\n"
        f"PrivateKey = {privkey}\n"
        f"Address = {address}\n"
        f"DNS = {dns}\n\n"
        f"[Peer]\n"
        f"PublicKey = {server_pubkey}\n"
        f"PresharedKey = {psk}\n"
        f"Endpoint = {endpoint}\n"
        f"AllowedIPs = 0.0.0.0/0\n"
        f"PersistentKeepalive = 25\n"
    )


# ---- Routes ----

@app.route("/")
def index():
    return render_template("index.html", endpoint=WG_ENDPOINT, subnet=WG_SUBNET)


@app.route("/api/peers")
def api_peers():
    wg_peers, iface = wg_show()
    disk_peers = peer_configs_on_disk()
    active_pubkeys = {p["public_key"] for p in wg_peers}

    enriched = []
    for dp in disk_peers:
        wg_info = next((wp for wp in wg_peers if wp["public_key"] == dp["pubkey"]), None)
        enriched.append({
            "name": dp["name"],
            "pubkey": dp["pubkey"],
            "in_wg_conf": dp["pubkey"] in active_pubkeys,
            "has_keys": dp["has_pubkey"],
            "alive": wg_info["alive"] if wg_info else False,
            "handshake_age": wg_info["handshake_age"] if wg_info else "never",
            "endpoint": wg_info["endpoint"] if wg_info else "-",
            "transfer_rx": _fmt_bytes(wg_info["transfer_rx"]) if wg_info else "0",
            "transfer_tx": _fmt_bytes(wg_info["transfer_tx"]) if wg_info else "0",
            "allowed_ips": wg_info["allowed_ips"] if wg_info else "-",
        })

    return jsonify({
        "peers": enriched,
        "server_pubkey": WG_SERVER_PUBKEY,
        "endpoint": WG_ENDPOINT,
    })


@app.route("/api/peers/create", methods=["POST"])
def api_create_peer():
    name = request.json.get("name", "").strip()
    if not name or not re.match(r"^[a-zA-Z0-9_-]+$", name):
        return jsonify({"error": "Invalid name (alphanumeric, hyphens, underscores only)"}), 400

    peer_dir = CONF_DIR / f"peer_{name}"
    if peer_dir.exists():
        return jsonify({"error": f"Peer '{name}' already exists"}), 409

    ip = get_next_ip()
    if not ip:
        return jsonify({"error": "No available IPs in subnet"}), 500

    peer_dir.mkdir(parents=True, exist_ok=True)

    privkey = docker_exec("wg", "genkey").stdout.strip()
    pubkey = subprocess.run(
        ["docker", "exec", "-i", WG_CONTAINER, "wg", "pubkey"],
        input=privkey, capture_output=True, text=True, check=True
    ).stdout.strip()
    psk = subprocess.run(
        ["docker", "exec", WG_CONTAINER, "wg", "genpsk"],
        capture_output=True, text=True, check=True
    ).stdout.strip()

    (peer_dir / f"privatekey-{peer_dir.name}").write_text(privkey + "\n")
    (peer_dir / f"publickey-{peer_dir.name}").write_text(pubkey + "\n")
    (peer_dir / f"presharedkey-{peer_dir.name}").write_text(psk + "\n")

    add_peer_to_wg_conf(name, pubkey, psk, ip)

    dns = WG_DNS if WG_DNS != "auto" else WG_SUBNET + ".1"
    client_conf = build_client_config(name, privkey, ip, dns, WG_ENDPOINT, WG_SERVER_PUBKEY, psk)
    (peer_dir / f"{name}.conf").write_text(client_conf)

    qr_b64 = gen_qr_b64(client_conf)
    (peer_dir / "qr.txt").write_text(qr_b64)

    refresh_wireguard()
    reload_wireguard()

    return jsonify({
        "name": name,
        "ip": ip,
        "pubkey": pubkey,
        "config_b64": b64encode(client_conf.encode()).decode(),
        "qr_b64": qr_b64,
        "config_text": client_conf,
        "wireguard_uri": wireguard_uri(client_conf, name),
    })


@app.route("/api/peers/<name>/config")
def api_peer_config(name):
    peer_dir = CONF_DIR / f"peer_{name}"
    if not peer_dir.exists():
        return jsonify({"error": "Peer not found"}), 404

    conf_file = peer_dir / f"{name}.conf"
    if not conf_file.exists():
        return jsonify({"error": "Config not found"}), 404

    client_conf = conf_file.read_text()
    return jsonify({
        "name": name,
        "config_text": client_conf,
        "qr_b64": gen_qr_b64(client_conf),
        "wireguard_uri": wireguard_uri(client_conf, name),
    })


@app.route("/api/peers/<name>/revoke", methods=["POST"])
def api_revoke_peer(name):
    peer_dir = CONF_DIR / f"peer_{name}"
    if not peer_dir.exists():
        return jsonify({"error": "Peer not found"}), 404

    pubkey_file = peer_dir / f"publickey-{peer_dir.name}"
    if pubkey_file.exists():
        remove_peer_from_wg_conf(pubkey_file.read_text().strip())

    import shutil
    trash_dir = CONF_DIR / "trash_peers"
    trash_dir.mkdir(exist_ok=True)
    shutil.move(str(peer_dir), str(trash_dir / f"peer_{name}_{int(time.time())}"))

    refresh_wireguard()
    reload_wireguard()

    return jsonify({"status": "revoked", "name": name})


def _fmt_bytes(b):
    if b < 1024:
        return f"{b} B"
    elif b < 1024**2:
        return f"{b/1024:.1f} KiB"
    elif b < 1024**3:
        return f"{b/1024**2:.1f} MiB"
    else:
        return f"{b/1024**3:.2f} GiB"


if __name__ == "__main__":
    port = int(os.environ.get("VPN_PORTAL_PORT", 8084))
    app.run(host="0.0.0.0", port=port, debug=False)
