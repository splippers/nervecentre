#!/usr/bin/env python3
"""Survey Portal — add ideas, context, and notes to Projects."""

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

PROJECTS_ROOT = Path(os.environ.get("PROJECTS_ROOT", "/mnt/EDDIE-SANDIEGO/Projects"))
DATA_DIR = Path(os.environ.get("SURVEY_DATA_DIR", "/home/jon/.surveyportal"))
SURVEY_FILE = DATA_DIR / "surveys.json"
PORT = int(os.environ.get("SURVEY_PORTAL_PORT", 8086))

DATA_DIR.mkdir(parents=True, exist_ok=True)
if not SURVEY_FILE.exists():
    SURVEY_FILE.write_text("[]")

IGNORE_DIRS = {
    ".git", ".claude", "__pycache__", "node_modules", ".venv", "venv",
    "tmp", "workadventure", "scripts",
}

def load_projects():
    projects = []
    try:
        for entry in sorted(PROJECTS_ROOT.iterdir()):
            if not entry.is_dir():
                continue
            name = entry.name
            if name.startswith(".") or name in IGNORE_DIRS:
                continue
            status_file = entry / ".project-status"
            status = "unknown"
            if status_file.exists():
                try:
                    for line in status_file.read_text().splitlines():
                        if line.startswith("status:"):
                            status = line.split(":", 1)[1].strip()
                except Exception:
                    pass
            has_readme = (entry / "README.md").exists()
            is_git = (entry / ".git").exists()
            projects.append({
                "name": name,
                "status": status,
                "has_readme": has_readme,
                "is_git": is_git,
                "path": str(entry),
            })
    except Exception as e:
        return [], str(e)
    return projects, None

def load_surveys():
    try:
        return json.loads(SURVEY_FILE.read_text())
    except Exception:
        return []

def save_surveys(surveys):
    SURVEY_FILE.write_text(json.dumps(surveys, indent=2))

# ---- Routes ----

@app.route("/")
def index():
    projects, err = load_projects()
    surveys = load_surveys()
    survey_count = len(surveys)
    return render_template("index.html",
        projects=projects,
        survey_count=survey_count,
        error=err)

@app.route("/api/projects")
def api_projects():
    projects, err = load_projects()
    if err:
        return jsonify({"error": err}), 500
    return jsonify(projects)

@app.route("/api/surveys")
def api_surveys():
    return jsonify(load_surveys())

@app.route("/api/surveys", methods=["POST"])
def api_create_survey():
    data = request.json
    if not data or not data.get("project"):
        return jsonify({"error": "project is required"}), 400

    survey = {
        "id": datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f"),
        "project": data["project"],
        "ideas": data.get("ideas", ""),
        "context": data.get("context", ""),
        "pain_points": data.get("pain_points", ""),
        "desired_features": data.get("desired_features", ""),
        "priority": data.get("priority", "medium"),
        "author": data.get("author", "jon"),
        "created_at": datetime.now(timezone.utc).isoformat(),
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }

    surveys = load_surveys()
    surveys.append(survey)
    save_surveys(surveys)
    return jsonify(survey), 201

@app.route("/api/surveys/<survey_id>", methods=["PUT"])
def api_update_survey(survey_id):
    data = request.json
    if not data:
        return jsonify({"error": "no data"}), 400
    surveys = load_surveys()
    for s in surveys:
        if s["id"] == survey_id:
            for key in ("ideas", "context", "pain_points", "desired_features", "priority"):
                if key in data:
                    s[key] = data[key]
            s["updated_at"] = datetime.now(timezone.utc).isoformat()
            save_surveys(surveys)
            return jsonify(s)
    return jsonify({"error": "not found"}), 404

@app.route("/api/surveys/<survey_id>", methods=["DELETE"])
def api_delete_survey(survey_id):
    surveys = load_surveys()
    surveys = [s for s in surveys if s["id"] != survey_id]
    save_surveys(surveys)
    return jsonify({"status": "deleted"})

@app.route("/api/projects/<path:project>/surveys")
def api_project_surveys(project):
    surveys = load_surveys()
    return jsonify([s for s in surveys if s["project"] == project])

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, debug=False)
