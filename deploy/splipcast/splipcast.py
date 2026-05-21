#!/usr/bin/env python3
"""SplipChat — multi-AI chat hub for NerveCentre."""
import os, json, sqlite3, uuid, datetime, hmac, hashlib
from flask import Flask, render_template, render_template_string, request, jsonify, Response, stream_with_context, redirect, make_response

app = Flask(__name__)

PORT           = int(os.environ.get("SPLIPCAST_PORT", 8090))
SCRIPT_NAME    = os.environ.get("SCRIPT_NAME", "")
DB_PATH        = os.path.join(os.path.dirname(os.path.abspath(__file__)), "splipcast.db")
PORTAL_SECRET  = os.environ.get("PORTAL_SECRET", "")
AUTH_COOKIE    = "splipcast_tok"

if not PORTAL_SECRET:
    raise RuntimeError("PORTAL_SECRET env var must be set — refusing to start without auth")

def _tok(secret):
    return hmac.new(secret.encode(), b"splipcast", hashlib.sha256).hexdigest()  # noqa: S324

VALID_TOKEN = _tok(PORTAL_SECRET)

def _authed():
    return request.cookies.get(AUTH_COOKIE) == VALID_TOKEN

@app.before_request
def require_auth():
    if request.path in ("/login", "/logout"):
        return
    if not _authed():
        return redirect(SCRIPT_NAME + "/login")

_LOGIN_HTML = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"/>
<title>SplipChat — Login</title>
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;600;700&display=swap" rel="stylesheet"/>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'DM Sans',system-ui,sans-serif;background:#06080c;color:#e9eef5;
  min-height:100vh;display:flex;align-items:center;justify-content:center}
.box{background:#0d1118;border:1px solid rgba(255,255,255,0.08);border-radius:16px;
  padding:2rem;width:100%;max-width:360px;box-shadow:0 24px 60px rgba(0,0,0,.5)}
h1{font-size:1.3rem;font-weight:700;margin-bottom:0.35rem;color:#a78bfa}
p{font-size:0.82rem;color:#94a3b8;margin-bottom:1.4rem}
input{width:100%;background:#131b26;border:1px solid rgba(255,255,255,0.1);border-radius:8px;
  color:#e9eef5;font-family:inherit;font-size:0.9rem;padding:0.65rem 0.85rem;outline:none;margin-bottom:1rem}
input:focus{border-color:rgba(167,139,250,0.4)}
button{width:100%;padding:0.65rem;background:rgba(167,139,250,0.18);
  border:1px solid rgba(167,139,250,0.35);border-radius:8px;
  color:#a78bfa;font-family:inherit;font-size:0.9rem;font-weight:700;cursor:pointer}
button:hover{background:rgba(167,139,250,0.3)}
.err{color:#f87171;font-size:0.82rem;margin-bottom:0.75rem}
</style></head><body>
<div class="box">
  <h1>SplipChat</h1>
  <p>NerveCentre — authentication required</p>
  {% if error %}<div class="err">Incorrect password.</div>{% endif %}
  <form method="post">
    <input type="password" name="secret" placeholder="Password" autofocus/>
    <button type="submit">Enter →</button>
  </form>
</div></body></html>"""

CLAUDE_MODEL    = os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-6")
BIGPICKLE_HOST  = os.environ.get("BIGPICKLE_HOST", "192.168.1.3:11434")
BIGPICKLE_MODEL = os.environ.get("BIGPICKLE_MODEL", "qwen2.5:32b")
OM42B_HOST      = os.environ.get("OM42B_HOST", "192.168.1.12:11434")
OM42B_MODEL     = os.environ.get("OM42B_MODEL", "phi3:latest")

@app.route("/login", methods=["GET", "POST"])
def login():
    if _authed():
        return redirect(SCRIPT_NAME + "/")
    if request.method == "POST":
        if hmac.compare_digest(request.form.get("secret", ""), PORTAL_SECRET):
            resp = make_response(redirect(SCRIPT_NAME + "/"))
            resp.set_cookie(AUTH_COOKIE, VALID_TOKEN, httponly=True, samesite="Strict", max_age=30*24*3600)
            return resp
        return render_template_string(_LOGIN_HTML, error=True)
    return render_template_string(_LOGIN_HTML, error=False)

@app.route("/logout")
def logout():
    resp = make_response(redirect(SCRIPT_NAME + "/login"))
    resp.delete_cookie(AUTH_COOKIE)
    return resp


AI_CONFIG = {
    "claude":    {"name": "Claude",     "color": "#fb923c", "desc": "Anthropic Claude"},
    "bigpickle": {"name": "Big Pickle", "color": "#38bdf8", "desc": "ZEN LLM via Ollama"},
    "om42b":     {"name": "Om42B",      "color": "#2dd4bf", "desc": "ThoughtFarm Omega42B"},
}


def ts():
    return datetime.datetime.utcnow().isoformat() + "Z"


def get_db():
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    return c


def init_db():
    with get_db() as db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS sessions (
                id         TEXT PRIMARY KEY,
                name       TEXT NOT NULL,
                ai         TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS messages (
                id         TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                role       TEXT NOT NULL,
                content    TEXT NOT NULL,
                ai         TEXT,
                ts         TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS org_memory (
                key        TEXT PRIMARY KEY,
                value      TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS chronicle (
                id         TEXT PRIMARY KEY,
                ts         TEXT NOT NULL,
                event_type TEXT NOT NULL,
                content    TEXT NOT NULL,
                session_id TEXT
            );
        """)


def build_system_prompt():
    with get_db() as db:
        rows = db.execute("SELECT key, value FROM org_memory ORDER BY key").fetchall()
    if not rows:
        return ""
    lines = ["[Organisational Memory — injected context]"]
    for r in rows:
        lines.append(f"{r['key']}: {r['value']}")
    return "\n".join(lines)


def log_chronicle(session_id, event_type, content):
    with get_db() as db:
        db.execute("INSERT INTO chronicle VALUES (?,?,?,?,?)",
                   (str(uuid.uuid4())[:12], ts(), event_type, content, session_id))


# --- AI streaming ---

def stream_claude(messages, system=""):
    client = anthropic.Anthropic()
    kwargs = dict(model=CLAUDE_MODEL, max_tokens=8192, messages=messages)
    if system:
        kwargs["system"] = system
    with client.messages.stream(**kwargs) as stream:
        for text in stream.text_stream:
            yield text


def stream_ollama(host, model, messages, system=""):
    msgs = list(messages)
    if system:
        msgs = [{"role": "system", "content": system}] + msgs
    try:
        resp = req.post(
            f"http://{host}/api/chat",
            json={"model": model, "messages": msgs, "stream": True},
            stream=True, timeout=180,
        )
        for line in resp.iter_lines():
            if line:
                data = json.loads(line)
                chunk = data.get("message", {}).get("content", "")
                if chunk:
                    yield chunk
    except Exception as e:
        yield f"\n\n[Connection error → {host}: {e}]"


def get_streamer(ai, messages):
    sys_prompt = build_system_prompt()
    if ai == "claude":
        return stream_claude(messages, sys_prompt)
    if ai == "bigpickle":
        return stream_ollama(BIGPICKLE_HOST, BIGPICKLE_MODEL, messages, sys_prompt)
    if ai == "om42b":
        return stream_ollama(OM42B_HOST, OM42B_MODEL, messages, sys_prompt)
    raise ValueError(f"Unknown AI: {ai}")


# --- Routes ---

@app.route("/")
def index():
    return render_template("index.html",
                           script_name=SCRIPT_NAME,
                           ai_config=json.dumps(AI_CONFIG))


@app.route("/api/sessions", methods=["GET"])
def list_sessions():
    with get_db() as db:
        rows = db.execute("SELECT * FROM sessions ORDER BY updated_at DESC").fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/api/sessions", methods=["POST"])
def create_session():
    data = request.json or {}
    ai = data.get("ai", "claude")
    if ai not in AI_CONFIG:
        return jsonify({"error": "unknown AI"}), 400
    now = ts()
    sid = str(uuid.uuid4())[:8]
    name = (data.get("name") or "").strip() or f"Chat {sid}"
    with get_db() as db:
        db.execute("INSERT INTO sessions VALUES (?,?,?,?,?)", (sid, name, ai, now, now))
    log_chronicle(sid, "session_created", f"New session '{name}' with {ai}")
    return jsonify({"id": sid, "name": name, "ai": ai, "created_at": now, "updated_at": now})


@app.route("/api/sessions/<sid>", methods=["GET"])
def get_session(sid):
    with get_db() as db:
        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        msgs = db.execute(
            "SELECT * FROM messages WHERE session_id=? ORDER BY ts", (sid,)
        ).fetchall()
    return jsonify({"session": dict(row), "messages": [dict(m) for m in msgs]})


@app.route("/api/sessions/<sid>", methods=["PATCH"])
def patch_session(sid):
    data = request.json or {}
    with get_db() as db:
        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not row:
            return jsonify({"error": "not found"}), 404
        name = data.get("name", row["name"])
        ai   = data.get("ai", row["ai"])
        if ai not in AI_CONFIG:
            return jsonify({"error": "unknown AI"}), 400
        db.execute("UPDATE sessions SET name=?, ai=?, updated_at=? WHERE id=?",
                   (name, ai, ts(), sid))
    return jsonify({"ok": True})


@app.route("/api/sessions/<sid>", methods=["DELETE"])
def delete_session(sid):
    with get_db() as db:
        db.execute("DELETE FROM messages WHERE session_id=?", (sid,))
        db.execute("DELETE FROM sessions WHERE id=?", (sid,))
    return jsonify({"ok": True})


@app.route("/api/sessions/<sid>/chat", methods=["POST"])
def chat(sid):
    data    = request.json or {}
    content = (data.get("message") or "").strip()
    if not content:
        return jsonify({"error": "empty message"}), 400

    with get_db() as db:
        row = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not row:
            return jsonify({"error": "session not found"}), 404
        ai = row["ai"]
        history = db.execute(
            "SELECT role, content FROM messages WHERE session_id=? ORDER BY ts", (sid,)
        ).fetchall()

    now = ts()
    mid = str(uuid.uuid4())[:12]
    with get_db() as db:
        db.execute("INSERT INTO messages VALUES (?,?,?,?,?,?)",
                   (mid, sid, "user", content, None, now))
        db.execute("UPDATE sessions SET updated_at=? WHERE id=?", (now, sid))

    messages = [{"role": r["role"], "content": r["content"]} for r in history]
    messages.append({"role": "user", "content": content})

    full_response = []

    def generate():
        try:
            for token in get_streamer(ai, messages):
                full_response.append(token)
                yield f"data: {json.dumps({'token': token})}\n\n"
        except Exception as e:
            err = f"[Error: {e}]"
            full_response.append(err)
            yield f"data: {json.dumps({'token': err})}\n\n"

        final = "".join(full_response)
        aid = str(uuid.uuid4())[:12]
        with get_db() as db:
            db.execute("INSERT INTO messages VALUES (?,?,?,?,?,?)",
                       (aid, sid, "assistant", final, ai, ts()))
            db.execute("UPDATE sessions SET updated_at=? WHERE id=?", (ts(), sid))

        if len(final) > 120:
            log_chronicle(sid, "exchange", f"[{ai}] {content[:60]}…")

        yield "data: [DONE]\n\n"

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/api/sessions/<sid>/handoff", methods=["POST"])
def handoff(sid):
    data      = request.json or {}
    target_ai = data.get("ai")
    if target_ai not in AI_CONFIG:
        return jsonify({"error": "unknown AI"}), 400

    with get_db() as db:
        src = db.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone()
        if not src:
            return jsonify({"error": "not found"}), 404
        msgs = db.execute(
            "SELECT * FROM messages WHERE session_id=? ORDER BY ts", (sid,)
        ).fetchall()

    now     = ts()
    new_sid = str(uuid.uuid4())[:8]
    new_name = f"{src['name']} → {AI_CONFIG[target_ai]['name']}"

    with get_db() as db:
        db.execute("INSERT INTO sessions VALUES (?,?,?,?,?)",
                   (new_sid, new_name, target_ai, now, now))
        for m in msgs:
            db.execute("INSERT INTO messages VALUES (?,?,?,?,?,?)",
                       (str(uuid.uuid4())[:12], new_sid, m["role"], m["content"], m["ai"], m["ts"]))

    log_chronicle(sid, "handoff", f"Handed off to {target_ai} → new session {new_sid}")
    return jsonify({"new_session_id": new_sid, "name": new_name})


@app.route("/api/memory", methods=["GET"])
def get_memory():
    with get_db() as db:
        rows = db.execute("SELECT * FROM org_memory ORDER BY key").fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/api/memory", methods=["POST"])
def set_memory():
    data  = request.json or {}
    key   = (data.get("key") or "").strip()
    value = (data.get("value") or "").strip()
    if not key:
        return jsonify({"error": "key required"}), 400
    with get_db() as db:
        db.execute("INSERT OR REPLACE INTO org_memory VALUES (?,?,?)", (key, value, ts()))
    return jsonify({"ok": True})


@app.route("/api/memory/<path:key>", methods=["DELETE"])
def delete_memory(key):
    with get_db() as db:
        db.execute("DELETE FROM org_memory WHERE key=?", (key,))
    return jsonify({"ok": True})


@app.route("/api/chronicle", methods=["GET"])
def get_chronicle():
    limit = int(request.args.get("limit", 50))
    with get_db() as db:
        rows = db.execute(
            "SELECT * FROM chronicle ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/api/status", methods=["GET"])
def status():
    return jsonify({
        "claude_model":    CLAUDE_MODEL,
        "bigpickle_host":  BIGPICKLE_HOST,
        "bigpickle_model": BIGPICKLE_MODEL,
        "om42b_host":      OM42B_HOST,
        "om42b_model":     OM42B_MODEL,
    })


if __name__ == "__main__":
    init_db()
    print(f"SplipChat → http://0.0.0.0:{PORT}{SCRIPT_NAME}/")
    app.run(host="0.0.0.0", port=PORT, threaded=True)
