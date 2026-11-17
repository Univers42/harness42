"""flow.py: run a flow, a workflow written once as TOML and run by code.

Called through tools/flow.sh (`devil flow`), which sets FLOW_KIT, FLOW_ROOT and FLOW_CACHE.

  list                                        the flows this host can run
  check [FLOW...]                             validate flows (none named: every flow)
  show [RUN_ID|FLOW]                          print a run's report.md (default: newest)
  run FLOW [--base REF] [--spec FILE] [--dry-run]

FLOW is a name, looked up in <host>/.claude/flows/ then <kit>/flows/, or a path to a .toml
file. Each run or assert step becomes steps/<name>.sh, run by tools/orch/gate.sh under
tools/watch.sh, from the host root, with stdin closed; a review step is one headless claude
call (flow_review.py). The first failure stops the flow and the steps after it are SKIP, so
a review only ever judges a green run. Steps hand data on as files in $FLOW_OUT.

Exit: 0 green, 1 a step failed or the review asked for changes, 2 usage or an invalid flow,
3 the review gave no verdict (fall back to the reviewer agents), 124 a step hit its watchdog.

Caveat: a step that exits 124 by itself (its own `timeout`, say) is reported as a watchdog
TIMEOUT, and liveness is output-based (watch.sh): a step silent for longer than its `idle`
is killed even when it is working, so a silent long step needs `idle = 0`.
"""

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True  # keep the kit free of __pycache__, as hooks.py does
sys.path.insert(0, str(Path(__file__).resolve().parent))  # -I drops the script dir
import flow_cost  # noqa: E402
import flow_report  # noqa: E402
import flow_review  # noqa: E402
from flow_spec import KIT, ROOT, Invalid, all_flows, load  # noqa: E402

RUNS = Path(os.environ.get("FLOW_CACHE", ROOT / ".claude" / "cache")) / "runs"
RUN_ID = re.compile(r"\d{8}-\d{6}-[a-z][a-z0-9-]*-\d+")
GATE_LINE = re.compile(r"(PASS|FAIL) +(\S+) +exit=(\d+) +expect=(\S+) +(\d+)s")
KEEP_RUNS = 20
STOP_CODE = {"TIMEOUT": 124, "ERROR": 3}


# --- running -----------------------------------------------------------------


def resolve_base(ref):
    if ref is None:
        return ""
    probe = [
        "git",
        "rev-parse",
        "--verify",
        "-q",
        "--end-of-options",
        f"{ref}^{{commit}}",
    ]
    found = None
    if not ref.startswith("-"):
        found = subprocess.run(probe, cwd=ROOT, capture_output=True, text=True)
    if found is None or found.returncode:
        raise Invalid([f"--base '{ref}' is not a commit"])
    return found.stdout.strip()


def step_env(run_dir, base, spec):
    return dict(
        os.environ,
        FLOW_RUN_ID=run_dir.name,
        FLOW_RUN_DIR=str(run_dir),
        FLOW_OUT=str(run_dir / "out"),
        FLOW_BASE=base,
        FLOW_ROOT=str(ROOT),
        FLOW_SPEC=spec,
        DEVIL_FLOW_CHILD="1",
        PATH=f"{KIT / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}",
    )


def write_step(flow, step, steps_dir):
    """steps/<name>.sh holds the body; steps/<name>.row is the gate.sh row running it."""
    script = steps_dir / f"{step['name']}.sh"
    head = f"# flow {flow['name']}, step {step['name']}, from {flow['path']}"
    body = step["run"].rstrip()
    script.write_text(f"#!/usr/bin/env bash\n{head}\nset -eo pipefail\n{body}\n")
    watch = shlex.quote(str(KIT / "tools" / "watch.sh"))
    limits = f"--timeout {step['timeout']} --idle {step['idle']}"
    cmd = f"bash {watch} {limits} -- bash {shlex.quote(str(script))}"
    row = steps_dir / f"{step['name']}.row"
    row.write_text(f"{step['name']}|{step['expect']}|{cmd}\n")
    return row


def run_step(flow, step, run_dir, env):
    steps_dir = run_dir / "steps"
    gate = [
        KIT / "tools" / "orch" / "gate.sh",
        steps_dir,
        write_step(flow, step, steps_dir),
    ]
    proc = subprocess.run(
        ["bash", *map(str, gate)],
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    summary = steps_dir / "summary.txt"
    line = summary.read_text().strip() if summary.is_file() else ""
    summary.unlink(missing_ok=True)
    match = GATE_LINE.fullmatch(line)
    if not match:
        why = proc.stderr.strip() or repr(line)
        raise RuntimeError(f"gate.sh gave no result for {step['name']}: {why}")
    rc = int(match.group(3))
    # A killed step proved nothing, whatever it was expected to return.
    status = "TIMEOUT" if rc == 124 else match.group(1)
    log = str(steps_dir / f"{step['name']}.log")
    return dict(
        step, status=status, rc=rc, seconds=int(match.group(5)), log=log, line=line
    )


def new_run_dir(flow):
    RUNS.mkdir(parents=True, exist_ok=True)
    run_dir = RUNS / f"{time.strftime('%Y%m%d-%H%M%S')}-{flow['name']}-{os.getpid()}"
    if "\n" in str(run_dir) or "\n" in str(KIT):
        raise Invalid(["a newline in the kit or cache path cannot go into a gate row"])
    (run_dir / "steps").mkdir(parents=True)
    (run_dir / "out").mkdir()
    return run_dir


def run_steps(flow, run_dir, env):
    results, stopped, total = [], None, len(flow["steps"])
    for i, step in enumerate(flow["steps"], 1):
        if stopped:
            results.append(dict(step, status="SKIP", rc=None, seconds=0, log=""))
            continue
        print(f"flow: [{i}/{total}] {step['name']} ...", file=sys.stderr, flush=True)
        if step["type"] == "review":
            result = flow_review.run(step, run_dir, env)
        else:
            result = run_step(flow, step, run_dir, env)
        print(f"flow: {result['line']}", file=sys.stderr, flush=True)
        results.append(result)
        stopped = None if result["status"] == "PASS" else result
    code = 0 if stopped is None else STOP_CODE.get(stopped["status"], 1)
    return results, code


def run_flow(flow, base, spec):
    run_dir = new_run_dir(flow)
    spec_copy = str(run_dir / "spec.md") if spec else ""
    if spec:
        shutil.copyfile(spec, spec_copy)
    meta = {
        "run_id": run_dir.name,
        "base": base,
        "spec": spec_copy,
        "started": time.time(),
    }
    results, code = run_steps(flow, run_dir, step_env(run_dir, base, spec_copy))
    report = flow_report.write(run_dir, flow, meta, results, code)
    prune()
    print(flow_report.return_block(report), flush=True)
    return code


def prune(keep=KEEP_RUNS):
    """Keep the newest runs. Only a real folder named like a run id is ever removed."""
    with os.scandir(RUNS) as entries:
        runs = sorted(
            e.name
            for e in entries
            if RUN_ID.fullmatch(e.name) and e.is_dir(follow_symlinks=False)
        )
    for name in runs[:-keep]:
        shutil.rmtree(RUNS / name)


def _plan(step):
    """What a step will do, for --dry-run."""
    if step["type"] != "review":
        limits = f"idle {step['idle']}s, expect {step['expect']}"
        return [limits, *step["run"].strip().splitlines()]
    rubric = ", ".join(os.path.relpath(r, KIT) for r in step["rubric"])
    url = flow_cost.routing.routed_url(ROOT)
    model = f"{step['route']} (Switchyard at {url})" if url else step["model"]
    return [
        f"claude -p --model {model}, budget ${step['budget_usd']}, no tools",
        f"diff cut at {step['max_diff_bytes']} bytes; rubric: {rubric}",
    ]


def dry_run(flow, base, spec):
    print(f"flow {flow['name']} ({flow['source']}: {flow['path']})")
    print(
        f"  {flow['description']}\n  base: {base or 'default'}, spec: {spec or 'none'}"
    )
    for i, step in enumerate(flow["steps"], 1):
        print(f"  {i}. {step['name']} [{step['type']}] timeout {step['timeout']}s")
        print("\n".join(f"       {line}" for line in _plan(step)))
    print("dry run: nothing was executed")
    return 0


# --- commands ----------------------------------------------------------------


def cmd_list(_args):
    for name, source in sorted(all_flows().items()):
        try:
            description = load(name)["description"]
        except Invalid:
            description = f"INVALID (devil flow check {name})"
        print(f"{name:<16} {source:<4}  {description}")
    return 0


def cmd_check(args):
    code = 0
    for arg in args.flows or sorted(all_flows()):
        try:
            flow = load(arg)
            print(f"ok   {flow['name']} ({flow['source']}, {len(flow['steps'])} steps)")
        except Invalid as err:
            code = 2
            print("\n".join(f"flow: {m}" for m in err.args[0]), file=sys.stderr)
    return code


def cmd_show(args):
    runs = sorted(p.name for p in RUNS.glob("*") if RUN_ID.fullmatch(p.name))
    if args.target and RUN_ID.fullmatch(args.target):
        runs = [r for r in runs if r == args.target]
    elif args.target:
        runs = [r for r in runs if r.split("-", 2)[2].rsplit("-", 1)[0] == args.target]
    report = RUNS / runs[-1] / "report.md" if runs else None
    if report is None or not report.is_file():
        raise Invalid([f"no finished run for '{args.target or 'any flow'}'"])
    print(report.read_text(), end="")
    return 0


def cmd_run(args):
    flow = load(args.flow)
    base = resolve_base(args.base)
    if args.spec and not Path(args.spec).is_file():
        raise Invalid([f"--spec '{args.spec}' is not a file"])
    if args.dry_run:
        return dry_run(flow, base, args.spec)
    return run_flow(flow, base, args.spec)


def parse(argv):
    parser = argparse.ArgumentParser(
        prog="devil flow", description=__doc__.split("\n")[0]
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(func=cmd_list)
    check = sub.add_parser("check")
    check.add_argument("flows", nargs="*")
    check.set_defaults(func=cmd_check)
    show = sub.add_parser("show")
    show.add_argument("target", nargs="?")
    show.set_defaults(func=cmd_show)
    run = sub.add_parser("run")
    run.add_argument("flow")
    run.add_argument("--base")
    run.add_argument("--spec")
    run.add_argument("--dry-run", action="store_true")
    run.set_defaults(func=cmd_run)
    return parser.parse_args(argv)


def main(argv):
    args = parse(argv)
    try:
        return args.func(args)
    except Invalid as err:
        print("\n".join(f"flow: {m}" for m in err.args[0]), file=sys.stderr)
        return 2
    except (RuntimeError, OSError) as err:
        print(f"flow: {err}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
