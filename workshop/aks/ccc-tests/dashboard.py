#!/usr/bin/env python3
"""Builds a one-page CCC compliance dashboard from a behavioural test run.

Reads the OCSF findings the CCC runner writes (<results>/ocsf/*.ocsf.json),
groups scenarios by assessment requirement (AR) and control, adds titles from
the CCC catalogs and writes <results>/dashboard.html plus a text summary.

    python3 dashboard.py --results DIR [--catalogs DIR] [--config FILE]

Python 3 standard library only; PyYAML (present on Ubuntu, cloud-init needs it)
is used when available for catalog titles and run details.
"""
import argparse
import glob
import html
import json
import os
import re
import sys
from collections import OrderedDict
from datetime import datetime, timezone

try:
    import yaml
except ImportError:  # titles and run details are optional
    yaml = None

AR_ID = re.compile(r"^(CCC\.[A-Za-z0-9]+)\.(CN\d+)\.(AR\d+)$")

# Shown next to a failing or skipped requirement when the workshop's low-cost
# settings explain it. Keyed by control (CCC.<catalog>.CNxx) or AR id.
WORKSHOP_NOTES = {
    "CCC.Core.CN04": "Audit logs are not sent to Log Analytics: aks_monitoring_enabled = false in "
                     "landing-zone/workshop.auto.tfvars.json. Set it to true (billed per GB ingested), "
                     "apply the landing zone and the example, wait ~15 minutes, then rerun.",
    "CCC.K8S.CN14": "Audit logs are not sent to Log Analytics: aks_monitoring_enabled = false in "
                    "landing-zone/workshop.auto.tfvars.json. Set it to true (billed per GB ingested), "
                    "apply the landing zone and the example, wait ~15 minutes, then rerun.",
    "CCC.K8S.CN11.AR01": "Counts every namespace without a pod-security.kubernetes.io/enforce label "
                         "(default, traderx-1..N, kyverno, ...) as uncovered. The Azure Policy add-on is off "
                         "(aks_azure_policy_enabled = false).",
}
LOCAL_REACHABILITY_NOTE = ("The untrusted-network probe ran on the jumpbox, which is inside the approved "
                           "network, so it reaches the private API. Run 55-run-ccc-tests-from-laptop.sh "
                           "to probe from your laptop instead.")

RANK = {"FAIL": 3, "PENDING": 2, "SKIP": 2, "PASS": 1}
LABEL = {"PASS": "Pass", "FAIL": "Fail", "SKIP": "Not run", "PENDING": "Not run"}


def load_findings(results):
    files = sorted(glob.glob(os.path.join(results, "ocsf", "*.ocsf.json")))
    combined = [f for f in files if f.endswith("combined.ocsf.json")]
    findings = []
    for path in combined or files:
        with open(path) as fh:
            findings.extend(json.load(fh))
    return findings


def load_catalogs(catalog_dir, versions):
    """Returns {control id: title}, {AR id: text}, {catalog: [AR ids]}."""
    controls, ars, by_catalog = {}, {}, {}
    if not (yaml and catalog_dir and os.path.isdir(catalog_dir)):
        return controls, ars, by_catalog
    for catalog, version in versions.items():
        path = os.path.join(catalog_dir, "%s_%s-controls.yaml" % (catalog, version))
        if not os.path.exists(path):
            continue
        with open(path) as fh:
            doc = yaml.safe_load(fh) or {}
        for control in doc.get("controls") or []:
            controls[control.get("id")] = control.get("title", "")
            for ar in control.get("assessment-requirements") or []:
                ars[ar.get("id")] = " ".join(str(ar.get("text", "")).split())
                by_catalog.setdefault(catalog, []).append(ar.get("id"))
    return controls, ars, by_catalog


def load_vars(config):
    if not (yaml and config and os.path.exists(config)):
        return {}
    with open(config) as fh:
        doc = yaml.safe_load(fh) or {}
    for service in (doc.get("services") or {}).values():
        return service.get("vars") or {}
    return {}


def first_error(detail):
    for line in (detail or "").splitlines():
        if line.startswith("\u2717"):  # ✗ failed step
            return line[1:].strip()
    return ""


def worst(statuses):
    return max(statuses, key=lambda s: RANK.get(s, 2)) if statuses else "SKIP"


def note_for(ar_id, local_reachability):
    control = ar_id.rsplit(".", 1)[0]
    if local_reachability and control == "CCC.K8S.CN01":
        return LOCAL_REACHABILITY_NOTE
    return WORKSHOP_NOTES.get(ar_id) or WORKSHOP_NOTES.get(control, "")


def build(findings, controls, ars, local_reachability):
    """Returns OrderedDict control id -> {ars: OrderedDict AR id -> row}."""
    by_ar = {}
    for f in findings:
        refs = (f.get("unmapped") or {}).get("compliance", {}).get("CCC") or []
        ar_id = refs[0] if refs else ""
        if not AR_ID.match(ar_id):
            continue
        by_ar.setdefault(ar_id, []).append({
            "name": f.get("message", ""),
            "status": f.get("status_code", "SKIP"),
            "error": first_error(f.get("status_detail")),
        })
    result = OrderedDict()
    for ar_id in sorted(by_ar, key=lambda a: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", a)]):
        control_id = ar_id.rsplit(".", 1)[0]
        scenarios = by_ar[ar_id]
        status = worst([s["status"] for s in scenarios])
        status = "SKIP" if status == "PENDING" else status
        entry = result.setdefault(control_id, {"title": controls.get(control_id, ""), "ars": OrderedDict()})
        entry["ars"][ar_id] = {
            "text": ars.get(ar_id, ""),
            "status": status,
            "scenarios": scenarios,
            "note": note_for(ar_id, local_reachability) if status != "PASS" else "",
        }
    for entry in result.values():
        entry["status"] = worst([a["status"] for a in entry["ars"].values()])
    return result


def counts(rows):
    c = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    for row in rows:
        c[row["status"] if row["status"] in c else "SKIP"] += 1
    return c


def pct(passed, evaluated):
    return round(100.0 * passed / evaluated) if evaluated else 0


def render(report, run, untested, out_path):
    e = html.escape
    all_ars = [a for c in report.values() for a in c["ars"].values()]
    ar_counts = counts(all_ars)
    ctl_counts = counts(report.values())
    evaluated = ar_counts["PASS"] + ar_counts["FAIL"]
    scen = counts([s for a in all_ars for s in a["scenarios"]])

    catalogs = OrderedDict()
    for control_id, c in report.items():
        catalogs.setdefault(control_id.split(".")[1], []).extend(c["ars"].values())

    def badge(status):
        return '<span class="b %s">%s</span>' % (status.lower(), LABEL.get(status, status))

    def tile(label, value, sub=""):
        return '<div class="tile"><div class="v">%s</div><div class="l">%s</div><div class="s">%s</div></div>' % (
            value, e(label), e(sub))

    rows = []
    for control_id, c in report.items():
        rows.append('<tr class="ctl"><td>%s</td><td colspan="2"><b>%s</b></td><td>%s</td></tr>' % (
            e(control_id), e(c["title"]), badge(c["status"])))
        for ar_id, a in c["ars"].items():
            scen_html = "".join(
                '<li>%s %s%s</li>' % (badge(s["status"]), e(s["name"]),
                                      '<div class="err">%s</div>' % e(s["error"]) if s["error"] else "")
                for s in a["scenarios"])
            note = '<div class="note">Workshop note: %s</div>' % e(a["note"]) if a["note"] else ""
            rows.append('<tr><td class="ar">%s</td><td>%s<ul>%s</ul>%s</td><td>%d</td><td>%s</td></tr>' % (
                e(ar_id), e(a["text"]), scen_html, note, len(a["scenarios"]), badge(a["status"])))

    catalog_rows = "".join(
        '<tr><td>CCC.%s</td><td>%d</td><td>%d</td><td>%d</td><td>%d%%</td></tr>' % (
            e(name), counts(items)["PASS"], counts(items)["FAIL"], counts(items)["SKIP"],
            pct(counts(items)["PASS"], counts(items)["PASS"] + counts(items)["FAIL"]))
        for name, items in catalogs.items())

    untested_html = ""
    if untested:
        untested_html = ('<h2>CCC.K8S requirements without a behavioural test (%d)</h2><p class="muted">'
                         'Present in the catalog but not exercised by this run; assess them another way.</p>'
                         '<p class="muted">%s</p>') % (len(untested), e(", ".join(untested)))

    links = " · ".join('<a href="%s">%s</a>' % (e(rel), e(label)) for label, rel in run["links"])
    meta = " · ".join("%s: <b>%s</b>" % (e(k), e(str(v))) for k, v in run["meta"] if v)

    page = """<!doctype html><html><head><meta charset="utf-8">
<title>CCC compliance - {cluster}</title>
<style>
body{{font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:24px;color:#1f2328;background:#f6f8fa}}
h1{{margin:0 0 4px}} h2{{margin-top:28px}} .muted{{color:#57606a;font-size:13px}}
.tiles{{display:flex;gap:12px;flex-wrap:wrap;margin:16px 0}}
.tile{{background:#fff;border:1px solid #d0d7de;border-radius:8px;padding:12px 16px;min-width:140px}}
.tile .v{{font-size:28px;font-weight:600}} .tile .l{{font-size:13px;color:#57606a}} .tile .s{{font-size:12px;color:#57606a}}
.bar{{display:flex;height:12px;border-radius:6px;overflow:hidden;background:#d0d7de;max-width:720px}}
.bar .pass{{background:#1a7f37}} .bar .fail{{background:#cf222e}} .bar .skip{{background:#9a6700}}
table{{border-collapse:collapse;width:100%;background:#fff;border:1px solid #d0d7de}}
td,th{{border-top:1px solid #d0d7de;padding:8px;vertical-align:top;text-align:left;font-size:14px}}
th{{background:#f6f8fa}} tr.ctl td{{background:#eaeef2}} td.ar{{white-space:nowrap;font-family:monospace}}
ul{{margin:6px 0 0;padding-left:18px}} li{{margin:2px 0}}
.b{{display:inline-block;border-radius:10px;padding:1px 8px;font-size:12px;font-weight:600;color:#fff}}
.b.pass{{background:#1a7f37}} .b.fail{{background:#cf222e}} .b.skip,.b.pending{{background:#9a6700}}
.err{{font-family:monospace;font-size:12px;color:#cf222e;white-space:pre-wrap;word-break:break-word}}
.note{{margin-top:6px;font-size:13px;background:#fff8c5;border:1px solid #d4a72c;border-radius:6px;padding:6px}}
.catalogs{{max-width:720px}}
</style></head><body>
<h1>CCC compliance: {cluster}</h1>
<div class="muted">{meta}</div>
<div class="tiles">
{t1}{t2}{t3}{t4}
</div>
<div class="bar"><div class="pass" style="flex:{p}"></div><div class="fail" style="flex:{f}"></div><div class="skip" style="flex:{s}"></div></div>
<p class="muted">Requirement status is the worst of its scenarios. Compliance = passed / (passed + failed) requirements; "Not run" (skipped or pending) is excluded.</p>
<h2>By catalog</h2>
<table class="catalogs"><tr><th>Catalog</th><th>Pass</th><th>Fail</th><th>Not run</th><th>Compliance</th></tr>{catalog_rows}</table>
<h2>Controls and assessment requirements</h2>
<table><tr><th>ID</th><th>Requirement and scenarios</th><th>Scenarios</th><th>Status</th></tr>
{rows}
</table>
{untested}
<p class="muted">Detailed reports: {links}</p>
</body></html>""".format(
        cluster=e(run["cluster"]), meta=meta,
        t1=tile("Compliance", "%d%%" % pct(ar_counts["PASS"], evaluated),
                "%d of %d requirements evaluated" % (ar_counts["PASS"], evaluated)),
        t2=tile("Requirements", len(all_ars), "%d pass · %d fail · %d not run" % (
            ar_counts["PASS"], ar_counts["FAIL"], ar_counts["SKIP"])),
        t3=tile("Controls", len(report), "%d pass · %d fail · %d not run" % (
            ctl_counts["PASS"], ctl_counts["FAIL"], ctl_counts["SKIP"])),
        t4=tile("Scenarios", sum(scen.values()), "%d pass · %d fail · %d not run" % (
            scen["PASS"], scen["FAIL"], scen["SKIP"])),
        p=ar_counts["PASS"], f=ar_counts["FAIL"], s=ar_counts["SKIP"],
        catalog_rows=catalog_rows, rows="\n".join(rows), untested=untested_html, links=links)
    with open(out_path, "w") as fh:
        fh.write(page)
    return ar_counts, ctl_counts, scen, evaluated


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--results", required=True, help="run output directory (contains ocsf/ and html/)")
    parser.add_argument("--catalogs", help="directory with CCC.<id>_<version>-controls.yaml")
    parser.add_argument("--config", help="rendered Privateer config used for the run")
    parser.add_argument("--out", help="output HTML (default <results>/dashboard.html)")
    parser.add_argument("--no-workshop-notes", action="store_true",
                        help="omit the notes about the hardened workshop's low-cost settings")
    args = parser.parse_args()
    if args.no_workshop_notes:
        WORKSHOP_NOTES.clear()

    findings = load_findings(args.results)
    if not findings:
        sys.exit("No OCSF findings under %s/ocsf; did the run start?" % args.results)
    variables = load_vars(args.config)
    versions = variables.get("catalog-versions") or {"CCC.K8S": "DEV", "CCC.Core": "v2025.10"}
    controls, ars, by_catalog = load_catalogs(args.catalogs, versions)
    local_reachability = str(variables.get("reachability-probe-mode", "local")).lower() != "remote"

    report = build(findings, controls, ars, local_reachability)
    tested = {a for c in report.values() for a in c["ars"]}
    untested = [a for a in by_catalog.get("CCC.K8S", []) if a not in tested]

    links = [("summary", "html/summary.html")]
    links += [(os.path.basename(p)[:-5], os.path.relpath(p, args.results))
              for p in sorted(glob.glob(os.path.join(args.results, "html", "*.html")))
              if not p.endswith("summary.html")]
    links.append(("OCSF findings", "ocsf/combined.ocsf.json"))
    run = {
        "cluster": variables.get("kubernetes-cluster-name") or os.path.basename(os.path.abspath(args.results)),
        "meta": [
            ("Generated", datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")),
            ("Resource group", variables.get("azure-resource-group")),
            ("Region", variables.get("region")),
            ("Catalogs", ", ".join("%s %s" % kv for kv in versions.items())),
            ("Untrusted probe", "laptop (remote)" if not local_reachability else "jumpbox (local)"),
        ],
        "links": links,
    }
    out = args.out or os.path.join(args.results, "dashboard.html")
    ar_counts, ctl_counts, scen, evaluated = render(report, run, untested, out)

    print("\nCCC compliance summary: %s" % run["cluster"])
    print("  Compliance:   %d%% (%d of %d evaluated requirements pass)" % (
        pct(ar_counts["PASS"], evaluated), ar_counts["PASS"], evaluated))
    print("  Requirements: %d pass, %d fail, %d not run" % (ar_counts["PASS"], ar_counts["FAIL"], ar_counts["SKIP"]))
    print("  Controls:     %d pass, %d fail, %d not run" % (ctl_counts["PASS"], ctl_counts["FAIL"], ctl_counts["SKIP"]))
    print("  Scenarios:    %d pass, %d fail, %d not run" % (scen["PASS"], scen["FAIL"], scen["SKIP"]))
    for control_id, c in report.items():
        for ar_id, a in c["ars"].items():
            if a["status"] != "PASS":
                print("  %-5s %s %s" % (LABEL[a["status"]].upper().replace(" ", ""), ar_id, c["title"]))
    print("  Dashboard:    %s" % out)


if __name__ == "__main__":
    main()
