"""flow_report.py: a flow run's report, in the three shapes its readers need.

report.json is for code (jq), report.md is for a person or an agent that was blocked, and
the return block from templates/agent-brief.md ends stdout so a caller can grep it without
opening either. One line per run also goes to runs/index.jsonl.
"""

import json
import time

VERDICT = {0: "PASS", 1: "FAIL", 124: "TIMEOUT"}
MAX_CHANGED = 20


def read_gates(run_dir):
    """Rows of quality/results.tsv, written by a step running `devil quality --logs`."""
    tsv = run_dir / "quality" / "results.tsv"
    if not tsv.is_file():
        return []
    rows = [line.split("\t") for line in tsv.read_text().splitlines()[1:] if line]
    return [
        dict(zip(("status", "gate", "category", "log"), row))
        for row in rows
        if len(row) == 4
    ]


def _next_step(results, gates):
    bad = next((r for r in results if r["status"] in ("FAIL", "TIMEOUT")), None)
    if bad is None:
        return "none", "none: the flow is green"
    skipped = [r["name"] for r in results if r["status"] == "SKIP"]
    deviations = f"stopped at {bad['name']}" + (
        f"; skipped {', '.join(skipped)}" if skipped else ""
    )
    if bad["status"] == "TIMEOUT":
        return (
            deviations,
            f"{bad['name']} hit its watchdog: find the hang ({bad['log']})",
        )
    if bad.get("message"):
        return deviations, f"{bad['message']} ({bad['log']})"
    failed = [g["gate"] for g in gates if g["status"] == "FAIL"]
    detail = f": {', '.join(failed)} failed" if failed else f" (exit {bad['rc']})"
    return deviations, f"fix {bad['name']}{detail} ({bad['log']})"


def brief(run_dir, results, gates, code):
    changed_txt = run_dir / "out" / "changed.txt"
    changed = (
        [p for p in changed_txt.read_text().splitlines() if p]
        if changed_txt.is_file()
        else []
    )
    deviations, next_step = _next_step(results, gates)
    return {
        "status": "done" if code == 0 else "blocked",
        "gates": [
            f"{r['name']} → {'skipped' if r['rc'] is None else r['rc']}"
            for r in results
        ],
        "changed": changed,
        "deviations": deviations,
        "next": next_step,
    }


def return_block(report):
    b = report["brief"]
    changed = ", ".join(b["changed"][:MAX_CHANGED]) or "none"
    if len(b["changed"]) > MAX_CHANGED:
        changed += f" (+{len(b['changed']) - MAX_CHANGED} more)"
    lines = [f"status: {b['status']}", "gates:", *(f"- {g}" for g in b["gates"])]
    lines += [
        f"changed: {changed}",
        f"deviations: {b['deviations']}",
        f"next: {b['next']}",
    ]
    return "\n".join([*lines, f"report: {report['report_md']}"])


def _cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def _table(header, rows):
    out = [f"| {' | '.join(header)} |", f"| {' | '.join('---' for _ in header)} |"]
    return out + [f"| {' | '.join(_cell(c) for c in row)} |" for row in rows]


def markdown(report, run_dir):
    def rel(path):
        return path.replace(f"{run_dir}/", "") if path else "-"

    meta = report["meta"]
    lines = [
        f"# Flow `{report['flow']}`: {VERDICT.get(report['exit'], report['exit'])}",
        "",
    ]
    lines += [
        f"- Run: `{meta['run_id']}`, exit {report['exit']}, {report['seconds']} s",
        f"- Flow: `{report['flow_file']}` ({report['source']})",
        f"- Base: `{meta['base'] or 'default'}`; spec: `{meta['spec'] or 'none'}`",
        "",
        "## Steps",
        "",
    ]
    rows = [
        (
            r["name"],
            r["type"],
            r["status"],
            "-" if r["rc"] is None else r["rc"],
            r["expect"],
            f"{r['seconds']} s",
            rel(r["log"]),
        )
        for r in report["steps"]
    ]
    lines += _table(("Step", "Type", "Result", "Exit", "Expect", "Time", "Log"), rows)
    if report["gates"]:
        gate_rows = [
            (g["status"], g["gate"], g["category"], rel(g["log"]))
            for g in report["gates"]
        ]
        lines += [
            "",
            "## Gates",
            "",
            *_table(("Result", "Gate", "Category", "Log"), gate_rows),
        ]
    lines += ["", "## Return block", "", "```text", return_block(report), "```", ""]
    return "\n".join(lines)


def write(run_dir, flow, meta, results, code):
    """Write report.json, report.md and the index line; return the report."""
    gates = read_gates(run_dir)
    steps = [
        {
            k: r.get(k)
            for k in (
                "name",
                "type",
                "status",
                "rc",
                "expect",
                "seconds",
                "log",
                "message",
            )
        }
        for r in results
    ]
    report = {
        "flow": flow["name"],
        "flow_file": flow["path"],
        "source": flow["source"],
        "exit": code,
        "seconds": round(time.time() - meta["started"]),
        "meta": meta,
        "steps": steps,
        "gates": gates,
        "report_md": str(run_dir / "report.md"),
        "brief": brief(run_dir, results, gates, code),
    }
    (run_dir / "report.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    )
    (run_dir / "report.md").write_text(markdown(report, run_dir))
    summary = [r.get("line") or f"SKIP {r['name']}" for r in results]
    (run_dir / "summary.txt").write_text("\n".join(summary) + "\n")
    index = {k: report[k] for k in ("flow", "exit", "seconds", "report_md")}
    with open(run_dir.parent / "index.jsonl", "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"run_id": meta["run_id"], **index}) + "\n")
    return report
