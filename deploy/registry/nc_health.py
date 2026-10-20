#!/usr/bin/env python3
"""Probe every registry service and write health.json. usage: nc_health.py services.toml OUT/health.json [LOCALHOSTKEY]
Run from a host that can reach the targets (Eddie). 200-399 and 401/403 count as alive."""
import json, sys, time, tomllib, urllib.error, urllib.request
hosts, svcs = None, None
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f); hosts, svcs = d["hosts"], d["service"]
res = {}
for s in svcs:
    if s.get("state") == "down":
        res[s["id"]] = {"ok": False, "fw": False, "note": "not running"}; continue
    ip = "127.0.0.1" if len(sys.argv) > 3 and s["host"] == sys.argv[3] else hosts[s["host"]]
    url = f"http://{ip}:{s['port']}{s.get('health', '/')}" if s.get("mode") != "link" else f"http://127.0.0.1{s['health']}"
    try:
        code = urllib.request.urlopen(url, timeout=3).status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception:
        code = 0
    ok = code in range(200, 400) or code in (401, 403)
    note = f"up ({code})" if ok else ("blocked by firewall?" if s.get("fw_blocked") else "unreachable")
    res[s["id"]] = {"ok": ok, "fw": (not ok) and bool(s.get("fw_blocked")), "note": note}
json.dump({"checked": time.strftime("%Y-%m-%d %H:%M:%S"), "services": res}, open(sys.argv[2], "w"), indent=1)
print(sum(v["ok"] for v in res.values()), "of", len(res), "up")
