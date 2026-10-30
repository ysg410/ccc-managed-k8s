#!/usr/bin/env python3
"""Scoreboard for the TraderX hardening challenge (workshop/aks/game).

Reads ~/ccc-game/game.json (written by game-10-setup.sh), the Kyverno
PolicyReports for the game-* policies, the team Deployments and each team's
TraderX URL, and writes scoreboard/index.html, scores.json and history.csv.

Scoring, per team:
  - 10 points for every (starter Deployment, game policy) pair whose latest
    PolicyReport result passes, counted only while that Deployment has an
    available replica (breaking the app to pass a policy earns nothing);
  - 100 points while http://<team>.<zone>/ answers through the load balancer.
Ties go to the team that reached its score first.
"""
import argparse
import csv
import datetime
import html
import json
import os
import subprocess
import urllib.request
from collections import defaultdict

CHECK_POINTS = 10
APP_POINTS = 100
GAME_LABEL = "workshop.finos.org/game=format-a"
SHORT_NAMES = {
    "trusted-images": "Images",
    "restricted-workloads": "Restricted",
    "resource-bounds": "Resources",
    "governance-labels": "Labels",
    "nondefault-service-account": "Service account",
    "no-inline-credentials": "Secrets",
}


def kubectl_json(*args, optional=False):
    proc = subprocess.run(["kubectl", *args, "-o", "json"], capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        if optional:
            return {"items": []}
        raise RuntimeError(f"kubectl {' '.join(args)}: {proc.stderr.strip()}")
    return json.loads(proc.stdout)


def app_up(url):
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            return 200 <= resp.status < 400
    except Exception:
        return False


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def compute(game):
    teams, expected, zone = game["teams"], game["deployments"], game["zone"]
    vpols = {p["metadata"]["name"]: p for p in kubectl_json("get", "validatingpolicies.policies.kyverno.io", "-l", GAME_LABEL)["items"]}
    policies = [p for p in game["policies"] if p in vpols]
    deployments = {}
    for d in kubectl_json("get", "deployments", "--all-namespaces")["items"]:
        if d["metadata"]["namespace"] in teams:
            deployments[(d["metadata"]["namespace"], d["metadata"]["name"])] = d

    # Kyverno writes wgpolicyk8s.io PolicyReports by default, openreports.io Reports when enabled.
    reports = kubectl_json("get", "policyreports.wgpolicyk8s.io", "--all-namespaces", optional=True)["items"]
    reports += kubectl_json("get", "reports.openreports.io", "--all-namespaces", optional=True)["items"]
    results = defaultdict(list)  # (deployment uid, policy) -> [result, ...]
    for report in reports:
        scope = report.get("scope") or {}
        if scope.get("kind") != "Deployment":
            continue
        for r in report.get("results") or []:
            results[(scope.get("uid"), (r.get("policy") or "").split("/")[-1])].append(r.get("result"))

    rows = []
    for team in teams:
        earned = {p: 0 for p in policies}
        running = 0
        for name in expected:
            d = deployments.get((team, name))
            if not d:
                continue
            is_running = d["spec"].get("replicas", 1) >= 1 and d.get("status", {}).get("availableReplicas", 0) >= 1
            running += is_running
            for p in policies:
                rs = results.get((d["metadata"]["uid"], p))
                if is_running and rs and all(r in ("pass", "skip") for r in rs):
                    earned[p] += 1
        up = app_up(f"http://{team}.{zone}/")
        score = CHECK_POINTS * sum(earned.values()) + (APP_POINTS if up else 0)
        rows.append({"team": team, "score": score, "earned": earned, "running": running, "app_up": up})
    max_score = CHECK_POINTS * len(expected) * len(policies) + APP_POINTS
    return rows, policies, vpols, max_score


def rank(rows, state_path):
    state = {}
    if os.path.exists(state_path):
        with open(state_path) as f:
            state = json.load(f)
    t = now()
    for row in rows:
        prev = state.get(row["team"])
        if not prev or prev["score"] != row["score"]:
            state[row["team"]] = {"score": row["score"], "since": t}
        row["since"] = state[row["team"]]["since"]
    with open(state_path + ".tmp", "w") as f:
        json.dump(state, f)
    os.replace(state_path + ".tmp", state_path)
    rows.sort(key=lambda r: (-r["score"], r["since"]))
    return rows


def cell_class(n, total):
    if total and n == total:
        return "full"
    return "half" if total and n * 2 >= total else "low"


def render(game, rows, policies, vpols, max_score):
    total = len(game["deployments"])
    heads = []
    for p in policies:
        suffix = p.removeprefix("game-")
        ccc = vpols[p]["metadata"].get("annotations", {}).get("workshop.finos.org/ccc-requirements", "")
        ccc = ", ".join(c.removeprefix("CCC.K8S.") for c in ccc.split(",") if c)
        heads.append(f"<th>{html.escape(SHORT_NAMES.get(suffix, suffix))}<small>{html.escape(ccc)}</small></th>")
    body = []
    for i, r in enumerate(rows, 1):
        cells = "".join(
            f'<td class="{cell_class(r["earned"][p], total)}">{r["earned"][p]}/{total}</td>' for p in policies
        )
        pct = 100 * r["score"] / max_score if max_score else 0
        body.append(
            f'<tr class="{"leader" if i == 1 and r["score"] else ""}"><td class="rank">{i}</td>'
            f'<td class="team">{html.escape(r["team"])}</td>'
            f'<td class="score"><div class="bar"><span style="width:{pct:.1f}%"></span></div>{r["score"]}</td>'
            f'{cells}<td class="{cell_class(r["running"], total)}">{r["running"]}/{total}</td>'
            f'<td class="{"full" if r["app_up"] else "low"}">{"&#10003;" if r["app_up"] else "&#10007;"}</td>'
            f'<td class="since">{html.escape(r["since"][11:19])}</td></tr>'
        )
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><meta http-equiv="refresh" content="10">
<title>TraderX Hardening Challenge</title>
<style>
body {{ font-family: system-ui, sans-serif; background: #0d1117; color: #e6edf3; margin: 2rem; }}
h1 {{ margin: 0 0 .2rem; }} .sub {{ color: #8b949e; margin-bottom: 1.5rem; }}
table {{ border-collapse: collapse; width: 100%; font-size: 1.3rem; }}
th, td {{ padding: .6rem .8rem; text-align: center; border-bottom: 1px solid #30363d; }}
th {{ color: #8b949e; font-weight: 600; font-size: 1rem; }} th small {{ display: block; font-weight: 400; font-size: .75rem; }}
td.rank {{ font-size: 1.8rem; font-weight: 700; }} td.team {{ text-align: left; font-weight: 700; }}
td.score {{ font-size: 1.8rem; font-weight: 700; min-width: 14rem; text-align: right; }}
.bar {{ background: #30363d; height: .5rem; border-radius: .25rem; margin-bottom: .3rem; }}
.bar span {{ display: block; height: 100%; background: #58a6ff; border-radius: .25rem; }}
td.full {{ color: #3fb950; }} td.half {{ color: #d29922; }} td.low {{ color: #f85149; }}
tr.leader td.team::before {{ content: "\\1F3C6  "; }} td.since {{ color: #8b949e; font-size: 1rem; }}
.rules {{ color: #8b949e; margin-top: 1.5rem; font-size: .95rem; line-height: 1.5; }}
</style></head><body>
<h1>TraderX Hardening Challenge</h1>
<div class="sub">Started {html.escape(game["started"])} &middot; updated {now()} &middot; max score {max_score}</div>
<table><tr><th>#</th><th style="text-align:left">Team</th><th style="text-align:right">Score</th>{"".join(heads)}<th>Running</th><th>App</th><th>Since (UTC)</th></tr>
{"".join(body)}
</table>
<div class="rules">Each policy column counts the {total} TraderX Deployments that pass that Kyverno policy
<b>and</b> are running: {CHECK_POINTS} points each. The app answering on its load balancer adds {APP_POINTS}.
Ties go to the team that reached its score first. Column labels show the CCC.K8S requirement each policy checks.</div>
</body></html>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--game-dir", default=os.path.expanduser("~/ccc-game"))
    args = parser.parse_args()
    with open(os.path.join(args.game_dir, "game.json")) as f:
        game = json.load(f)
    out = os.path.join(args.game_dir, "scoreboard")
    os.makedirs(out, exist_ok=True)

    rows, policies, vpols, max_score = compute(game)
    rows = rank(rows, os.path.join(out, "state.json"))
    page = render(game, rows, policies, vpols, max_score)
    with open(os.path.join(out, "index.html.tmp"), "w") as f:
        f.write(page)
    os.replace(os.path.join(out, "index.html.tmp"), os.path.join(out, "index.html"))
    with open(os.path.join(out, "scores.json"), "w") as f:
        json.dump({"updated": now(), "max_score": max_score, "teams": rows}, f, indent=2)
    t = now()
    with open(os.path.join(out, "history.csv"), "a", newline="") as f:
        csv.writer(f).writerows([t, r["team"], r["score"]] for r in rows)
    print(t, "  ".join(f'{r["team"]} {r["score"]}' for r in rows), flush=True)


if __name__ == "__main__":
    main()
