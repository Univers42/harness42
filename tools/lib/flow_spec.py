"""flow_spec.py: find a flow file and check it before anything runs.

A flow is TOML: a `description` and one or more [[step]] tables of type run, assert or
review (at most one review, and it goes last). Every key is checked, an unknown one
included, because a typo such as `timout` would otherwise run the step with no limit. A
host file (<host>/.claude/flows/<name>.toml) wins over the kit's by name; a host flow is
untrusted, so a review's rubric must resolve to files inside the kit.

Caveat: check proves the shape and the shell syntax (bash -n), not that a step's commands
exist or end: a missing tool or an endless loop passes check and fails only when the step
runs (exit 1, or 124 under the watchdog). Use `devil flow run FLOW --dry-run` to read them.
"""

import os
import re
import subprocess
import tomllib
from pathlib import Path

NAME = re.compile(r"[a-z][a-z0-9-]{0,39}")
KIT = Path(os.environ.get("FLOW_KIT", Path(__file__).resolve().parents[2]))
ROOT = Path(os.environ.get("FLOW_ROOT", os.getcwd()))
MODEL = re.compile(r"[A-Za-z0-9._:\[\]-]{1,80}")
STEP_KEYS = {
    "run": {"name", "type", "run", "expect", "timeout", "idle"},
    "assert": {"name", "type", "run", "message", "timeout"},
    "review": {"name", "type", "model", "route", "budget_usd", "timeout"}
    | {"max_diff_bytes", "rubric"},
}
# key: (default, lowest, highest), per step type
LIMITS = {
    "run": {"timeout": (300, 1, 7200), "idle": (120, 0, 7200)},
    "assert": {"timeout": (30, 1, 600)},
    "review": {"timeout": (600, 60, 3600), "max_diff_bytes": (200000, 1000, 2000000)},
}
RUBRIC = ["agents/reviewer.md", "agents/security.md"]
MAX_RUBRIC_BYTES = 64000  # the rubric goes to claude as one argv string


class Invalid(Exception):
    """A usage error or an invalid flow: args[0] is the list of messages."""


def _int(raw, key, limits, errs):
    default, low, high = limits
    value = raw.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        value = None
    if value is None or not low <= value <= high:
        errs.append(f"{key} must be an integer in {low}..{high}, got {raw.get(key)!r}")
        return default
    return value


def _expect(raw, errs):
    value = raw.get("expect", 0)
    if (type(value) is int and value == 0) or value == "0":
        return "0"
    if value == "nonzero":
        return "nonzero"
    errs.append(f'expect must be 0 or "nonzero", got {value!r}')
    return "0"


def _syntax(body, errs):
    parsed = subprocess.run(["bash", "-n"], input=body, capture_output=True, text=True)
    if parsed.returncode:
        first = (parsed.stderr.strip().splitlines() or ["bash -n failed"])[0]
        errs.append(f"run is not valid bash: {first.removeprefix('bash: ')}")


def _rubric(raw, errs):
    """Kit-relative files only: a host flow is untrusted and must not send /etc/x."""
    paths = raw.get("rubric", RUBRIC)
    if not isinstance(paths, list) or not paths:
        errs.append("rubric must be a non-empty list of kit files")
        return []
    files, bad = [], []
    for path in paths:
        named = isinstance(path, str) and "\0" not in path
        found = (KIT / path).resolve() if named else None
        if found and found.is_relative_to(KIT.resolve()) and found.is_file():
            files.append(found)
        else:
            bad.append(path)
    if bad:
        errs.append(f"rubric must name files inside the kit, got {bad!r}")
        return []
    if sum(f.stat().st_size for f in files) > MAX_RUBRIC_BYTES:
        errs.append(f"rubric files exceed {MAX_RUBRIC_BYTES} bytes together")
    return [str(f) for f in files]


def _review(raw, step, errs):
    model, budget = raw.get("model", "opus"), raw.get("budget_usd", 3)
    route = raw.get("route", "devil-review")  # the model when routed (devil route on)
    for key, value in (("model", model), ("route", route)):
        if not isinstance(value, str) or not MODEL.fullmatch(value):
            errs.append(f"{key} must match {MODEL.pattern}, got {value!r}")
    ok = isinstance(budget, (int, float)) and not isinstance(budget, bool)
    if not ok or not 0.01 <= budget <= 50:
        errs.append(f"budget_usd must be a number in 0.01..50, got {budget!r}")
    step.update(model=model, route=route, budget_usd=budget, run="")
    step["rubric"] = _rubric(raw, errs)
    return step


def _step(raw, errs):
    """Normalise one [[step]] table; its problems go to errs, without a location."""
    kind = raw.get("type")
    if kind not in STEP_KEYS:
        errs.append(f"type must be one of {', '.join(STEP_KEYS)}, got {kind!r}")
        return None
    errs.extend(f"unknown key '{k}'" for k in sorted(raw.keys() - STEP_KEYS[kind]))
    step = {"name": raw.get("name"), "type": kind, "run": raw.get("run"), "idle": 0}
    for key, limits in LIMITS[kind].items():
        step[key] = _int(raw, key, limits, errs)
    step["expect"] = _expect(raw, errs) if kind == "run" else "0"
    if kind == "review":
        return _review(raw, step, errs)
    if not isinstance(raw.get("run"), str) or not raw["run"].strip():
        errs.append("run must be a non-empty shell string")
    else:
        _syntax(raw["run"], errs)
    if kind == "assert":
        step["message"] = raw.get("message")
        if not isinstance(step["message"], str) or not step["message"].strip():
            errs.append(
                "message is required: the caller reads it when the assert fails"
            )
    return step


def _steps(raw_steps, errs):
    steps, seen = [], set()
    for i, raw in enumerate(raw_steps, 1):
        if not isinstance(raw, dict):
            errs.append(f"step {i}: must be a table")
            continue
        name = raw.get("name")
        named = isinstance(name, str) and NAME.fullmatch(name)
        local = [] if named else [f"name must match {NAME.pattern}, got {name!r}"]
        if named and name in seen:
            local.append("duplicate name")
        seen.add(name if named else None)
        steps.append(_step(raw, local))
        if raw.get("type") == "review" and i != len(raw_steps):
            local.append("a review must be the last step: it judges what ran before")
        errs.extend(f"step {i} ({name if named else '?'}): {m}" for m in local)
    return steps


def validate(doc, stem):
    errs = [] if NAME.fullmatch(stem) else [f"file name must match {NAME.pattern}"]
    errs.extend(
        f"unknown key '{k}'" for k in sorted(doc.keys() - {"description", "step"})
    )
    description = doc.get("description")
    if not isinstance(description, str) or not description.strip():
        errs.append("description: a non-empty string is required")
    raw_steps = doc.get("step")
    if not isinstance(raw_steps, list) or not raw_steps:
        errs.append("step: at least one [[step]] is required")
        raw_steps = []
    steps = _steps(raw_steps, errs)
    if errs:
        raise Invalid(errs)
    return {"name": stem, "description": description.strip(), "steps": steps}


def locate(arg):
    if NAME.fullmatch(arg):
        for source, folder in (
            ("host", ROOT / ".claude" / "flows"),
            ("kit", KIT / "flows"),
        ):
            if (folder / f"{arg}.toml").is_file():
                return folder / f"{arg}.toml", source
        raise Invalid([f"no flow named '{arg}' (devil flow list shows them)"])
    path = Path(arg)
    if path.suffix == ".toml" and path.is_file():
        return path.resolve(), "path"
    raise Invalid([f"'{arg}' is neither a flow name nor a .toml file"])


def load(arg):
    path, source = locate(arg)
    try:
        flow = validate(tomllib.loads(path.read_text(encoding="utf-8")), path.stem)
    except (tomllib.TOMLDecodeError, UnicodeDecodeError, OSError) as err:
        raise Invalid([f"{path}: {err}"]) from err
    except Invalid as err:
        raise Invalid([f"{path}: {m}" for m in err.args[0]]) from err
    flow.update(path=str(path), source=source)
    return flow


def all_flows():
    """{name: source}; the host folder is read second, so its file wins."""
    found = {}
    for source, folder in (
        ("kit", KIT / "flows"),
        ("host", ROOT / ".claude" / "flows"),
    ):
        for path in sorted(folder.glob("*.toml")):
            found[path.stem] = source
    return found
