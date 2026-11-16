"""flow_verdict.py: the review step's reply, its JSON schema and what code makes of it.

The schema goes to `claude --json-schema`, and the reply is checked against the same
tables here, because a schema handed to a model is a request and this check is the
guarantee. The policy only ever makes the verdict stricter: a BLOCKER, CRITICAL or HIGH
finding is CHANGES_REQUESTED whatever the model concluded.

Caveat: the check proves the reply's shape, not its truth. A finding can cite a file:line
that does not exist, and the policy escalates only on the severity the model chose, so a
real defect it labelled MINOR, or never saw, still reaches APPROVE.
"""

import json

BLOCKING = ("BLOCKER", "CRITICAL", "HIGH")
SEVERITIES = ["BLOCKER", "MAJOR", "MINOR", "CRITICAL", "HIGH", "MEDIUM", "LOW"]
AREAS = ["standards", "spec", "security"]
VERDICTS = ["APPROVE", "CHANGES_REQUESTED"]
MAX_FINDINGS = 50
# Required finding keys and their JSON types; `clause` and `class` are optional strings.
FINDING = {"area": str, "severity": str, "file": str, "line": int}
FINDING |= {"finding": str, "fix": str}
OPTIONAL = ("clause", "class")
TOP = ("verdict", "summary", "checked", "findings")


def _schema():
    props = {
        k: {"type": "integer" if t is int else "string"} for k, t in FINDING.items()
    }
    props |= {k: {"type": "string"} for k in OPTIONAL}
    props |= {"area": {"enum": AREAS}, "severity": {"enum": SEVERITIES}}
    props["line"]["minimum"] = 0
    finding = {"type": "object", "additionalProperties": False, "properties": props}
    finding["required"] = list(FINDING)
    findings = {"type": "array", "maxItems": MAX_FINDINGS, "items": finding}
    top = {"verdict": {"enum": VERDICTS}, "findings": findings}
    top |= {"summary": {"type": "string"}, "checked": {"type": "string"}}
    return {
        "type": "object",
        "additionalProperties": False,
        "required": list(TOP),
        "properties": top,
    }


SCHEMA = _schema()


class ReviewError(Exception):
    """The review produced no verdict; args[0] says why."""


# --- the reply ---------------------------------------------------------------


def _finding_problems(i, item):
    if not isinstance(item, dict):
        return [f"findings[{i}] is not an object"]
    where = f"findings[{i}]"
    problems = [
        f"{where}.{k} is missing or not {t.__name__}"
        for k, t in FINDING.items()
        if type(item.get(k)) is not t
    ]
    problems += [
        f"{where}.{k} is not a string"
        for k in OPTIONAL
        if k in item and type(item[k]) is not str
    ]
    problems += [
        f"{where} has unknown key {k!r}"
        for k in item.keys() - FINDING.keys() - set(OPTIONAL)
    ]
    if item.get("area") not in AREAS or item.get("severity") not in SEVERITIES:
        problems.append(f"{where}: area or severity is not one the schema allows")
    return problems


def check(review):
    """Every way the reply breaks the schema; [] when it holds."""
    if not isinstance(review, dict):
        return ["structured_output is missing or not an object"]
    problems = [f"unknown key {k!r}" for k in review.keys() - set(TOP)]
    problems += [
        f"{k} is missing or not a string"
        for k in ("summary", "checked")
        if type(review.get(k)) is not str
    ]
    if review.get("verdict") not in VERDICTS:
        problems.append(f"verdict must be one of {VERDICTS}")
    findings = review.get("findings")
    if not isinstance(findings, list) or len(findings) > MAX_FINDINGS:
        return [*problems, f"findings must be a list of at most {MAX_FINDINGS}"]
    for i, item in enumerate(findings):
        problems += _finding_problems(i, item)
    return problems


def verdict_of(rc, out):
    """The checked review from claude's JSON reply; ReviewError naming why there is none."""
    if rc is None:
        raise ReviewError("claude ran past the step's timeout and was killed")
    try:
        reply = json.loads(out)
    except ValueError:
        reply = None
    if not isinstance(reply, dict):
        raise ReviewError(f"claude exited {rc} with no JSON reply (review/stderr.txt)")
    if reply.get("is_error") or reply.get("subtype") != "success":
        said = str(reply.get("result") or "")[:200]
        raise ReviewError(f"claude ended with {reply.get('subtype')!r}: {said}")
    problems = check(reply.get("structured_output"))
    if problems:
        raise ReviewError(f"the reply breaks the schema: {'; '.join(problems[:5])}")
    return reply["structured_output"]


def apply_policy(review, omitted):
    """Code has the last word, and it can only be stricter than the model."""
    if omitted:
        review["findings"].append(
            {
                "area": "standards",
                "severity": "MAJOR",
                "file": ", ".join(omitted),
                "line": 0,
                "finding": "not reviewed: the diff was over max_diff_bytes",
                "fix": "review these files by hand, or raise max_diff_bytes",
            }
        )
    if any(f["severity"] in BLOCKING for f in review["findings"]):
        review["verdict"] = "CHANGES_REQUESTED"
    review["omitted"] = omitted
    return review
