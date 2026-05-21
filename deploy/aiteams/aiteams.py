#!/usr/bin/env python3
"""AI Teams Portal — manage AI teams, assign projects, track activity."""

import json
import os
import re
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


DATA_DIR = Path(os.environ.get("AITEAMS_DATA_DIR", "/home/jon/.aiteams"))
TEAMS_FILE = DATA_DIR / "teams.json"
ACTIVITY_FILE = DATA_DIR / "activity.json"
PORT = int(os.environ.get("AITEAMS_PORTAL_PORT", 8087))

DATA_DIR.mkdir(parents=True, exist_ok=True)
for f in (TEAMS_FILE, ACTIVITY_FILE):
    if not f.exists():
        f.write_text("[]")

# --- Data helpers ---

def load_json(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return []

def save_json(path, data):
    path.write_text(json.dumps(data, indent=2))

def load_teams():
    return load_json(TEAMS_FILE)

def save_teams(teams):
    save_json(TEAMS_FILE, teams)

def load_activity():
    return load_json(ACTIVITY_FILE)

def save_activity(activity):
    save_json(ACTIVITY_FILE, activity)

def log_activity(action, team, detail=""):
    activity = load_activity()
    activity.append({
        "id": datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f"),
        "action": action,
        "team": team,
        "detail": detail,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })
    save_activity(activity)

# ---- Routes ----

@app.route("/")
def index():
    teams = load_teams()
    activity = load_activity()
    return render_template("index.html",
        teams=teams,
        activity_count=len(activity))

# --- Teams CRUD ---

@app.route("/api/teams")
def api_teams():
    return jsonify(load_teams())

@app.route("/api/teams", methods=["POST"])
def api_create_team():
    data = request.json
    if not data or not data.get("name"):
        return jsonify({"error": "team name is required"}), 400
    teams = load_teams()
    team = {
        "id": datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f"),
        "name": data["name"],
        "description": data.get("description", ""),
        "members": data.get("members", []),
        "agent_type": data.get("agent_type", "opencode"),
        "model": data.get("model", "phi3:latest"),
        "assigned_projects": data.get("assigned_projects", []),
        "status": "idle",
        "created_at": datetime.now(timezone.utc).isoformat(),
    }
    teams.append(team)
    save_teams(teams)
    log_activity("created", team["name"], f"Team created with {len(team['members'])} members")
    return jsonify(team), 201

@app.route("/api/teams/<team_id>", methods=["PUT"])
def api_update_team(team_id):
    data = request.json
    if not data:
        return jsonify({"error": "no data"}), 400
    teams = load_teams()
    for t in teams:
        if t["id"] == team_id:
            for key in ("name", "description", "members", "agent_type", "model", "assigned_projects", "status"):
                if key in data:
                    t[key] = data[key]
            save_teams(teams)
            log_activity("updated", t["name"], "Team updated")
            return jsonify(t)
    return jsonify({"error": "not found"}), 404

@app.route("/api/teams/<team_id>", methods=["DELETE"])
def api_delete_team(team_id):
    teams = load_teams()
    team_name = "unknown"
    teams = [t for t in teams if t["id"] != team_id or (team_name := t["name"])]
    save_teams(teams)
    log_activity("deleted", team_name, "Team deleted")
    return jsonify({"status": "deleted"})

# --- Project assignment ---

@app.route("/api/teams/<team_id>/assign", methods=["POST"])
def api_assign_project(team_id):
    data = request.json
    if not data or not data.get("project"):
        return jsonify({"error": "project is required"}), 400
    teams = load_teams()
    for t in teams:
        if t["id"] == team_id:
            proj = data["project"]
            if proj not in t["assigned_projects"]:
                t["assigned_projects"].append(proj)
                save_teams(teams)
                log_activity("assigned", t["name"], f"Project '{proj}' assigned")
            return jsonify(t)
    return jsonify({"error": "not found"}), 404

@app.route("/api/teams/<team_id>/unassign", methods=["POST"])
def api_unassign_project(team_id):
    data = request.json
    if not data or not data.get("project"):
        return jsonify({"error": "project is required"}), 400
    teams = load_teams()
    for t in teams:
        if t["id"] == team_id:
            proj = data["project"]
            if proj in t["assigned_projects"]:
                t["assigned_projects"].remove(proj)
                save_teams(teams)
                log_activity("unassigned", t["name"], f"Project '{proj}' unassigned")
            return jsonify(t)
    return jsonify({"error": "not found"}), 404

# --- Activity ---

@app.route("/api/activity")
def api_activity():
    limit = request.args.get("limit", 50, type=int)
    activity = load_activity()
    return jsonify(activity[-limit:])

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, debug=False)
