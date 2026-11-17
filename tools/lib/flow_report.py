"""flow_report.py: a flow run's report, in the three shapes its readers need.

report.json is for code (jq), report.md is for a person or an agent that was blocked, and
the return block from templates/agent-brief.md ends stdout so a caller can grep it without
opening either. One line per run also goes to runs/index.jsonl. A review's findings are
rendered in the column layouts of agents/reviewer.md and agents/security.md.
"""

import json
import time

import flow_cost

VERDICT = {0: "PASS", 1: "FAIL", 3: "ERROR", 124: "TIMEOUT"}
MAX_CHANGED = 20
MAX_NEXT = 5  # findings named in the return block's `next`; the rest are in report.md
BLOCKING = ("BLOCKER", "CRITICAL", "HIGH")


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


def _short(text, limit=100):
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _review_next(bad):
    if bad["status"] == "ERROR":
        why = bad["reason"]
        return f"review gave no verdict ({why}): fall back to the reviewer and security agents ({bad['log']})"
    findings = bad["review"]["findings"]
    named = [f for f in findings if f["severity"] in BLOCKING] or findings
    listed = "; ".join(
        f"{f['severity']} {f['file']}:{f['line']} {_short(f['finding'])}"
        for f in named[:MAX_NEXT]
    )
    more = f" (+{len(named) - MAX_NEXT} more)" if len(named) > MAX_NEXT else ""
    return f"review asked for changes: {listed}{more}"


def _not_reviewed(results):
    review = next((r["review"] for r in results if r.get("review")), None)
    omitted = review["omitted"] if review else []
    return (
        f"not reviewed (over max_diff_bytes): {', '.join(omitted)}" if omitted else ""
    )


def _next_step(results, gates):
    bad = next((r for r in results if r["status"] not in ("PASS", "SKIP")), None)
    if bad is None:
        return _not_reviewed(results) or "none", "none: the flow is green"
    skipped = [r["name"] for r in results if r["status"] == "SKIP"]
    deviations = f"stopped at {bad['name']}" + (
        f"; skipped {', '.join(skipped)}" if skipped else ""
    )
    if bad["type"] == "review":
        return "; ".join(
            filter(None, [deviations, _not_reviewed(results)])
        ), _review_next(bad)
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


def _where(f):
    return f"{f['file']}:{f['line']}"


# area: (header, cells); the layouts of agents/reviewer.md and agents/security.md, with a
# severity column on Spec too, because code blocks on it.
AREA_TABLES = {
    "standards": (
        ("Severity", "file:line", "Finding", "Smallest fix"),
        lambda f: (f["severity"], _where(f), f["finding"], f["fix"]),
    ),
    "spec": (
        ("Severity", "Contract clause", "file:line", "Deviation", "Smallest fix"),
        lambda f: (
            f["severity"],
            f.get("clause", "-"),
            _where(f),
            f["finding"],
            f["fix"],
        ),
    ),
    "security": (
        ("Severity", "file:line", "Class", "What an attacker gets", "Smallest fix"),
        lambda f: (
            f["severity"],
            _where(f),
            f.get("class", "-"),
            f["finding"],
            f["fix"],
        ),
    ),
}


def _cost_md(cost):
    line, rows = flow_cost.describe(cost)
    return [
        "",
        "## Cost",
        "",
        line,
        *(["", *_table(flow_cost.HEADER, rows)] if rows else []),
    ]


def _review_md(review):
    lines = ["", "## Review", "", f"- Model: `{review['model']}`"]
    if review["status"] == "ERROR":
        return [
            *lines,
            f"- No verdict: {review['reason']}. Fall back to the reviewer and security agents.",
        ]
    lines += [
        f"- Verdict: **{review['verdict']}**",
        f"- Summary: {_cell(review['summary'])}",
        f"- Checked and clean: {_cell(review['checked'])}",
    ]
    for area, (header, cells) in AREA_TABLES.items():
        rows = [cells(f) for f in review["findings"] if f["area"] == area]
        lines += ["", f"**{area.title()}** ({len(rows)})", ""]
        lines += _table(header, rows) if rows else ["None."]
    return lines


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
    if report["review"]:
        lines += _review_md(report["review"]) + _cost_md(report["review"]["cost"])
    lines += ["", "## Return block", "", "```text", return_block(report), "```", ""]
    return "\n".join(lines)


def _review_of(results):
    """The review step's outcome for report.json, or None when it never ran."""
    ran = [r for r in results if r["type"] == "review" and r["status"] != "SKIP"]
    if not ran:
        return None
    r = ran[0]
    head = {"status": r["status"], "model": r["model"], "reason": r["reason"]}
    return {**head, "cost": r["cost"], **(r["review"] or {})}


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
                "reason",
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
        "review": _review_of(results),
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
