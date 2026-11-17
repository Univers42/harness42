"""flow_cost.py: what a flow's review cost, and through what.

A project routed with `devil route on` sends the review through the local Switchyard: pinned
to the step's `route` (default devil-review), and tagged with a per-run session id, so the cost comes from Switchyard's own
routing log (/v1/routing/session-stats), per served model. Otherwise it is the CLI's
client-side estimate (total_cost_usd). Neither is a bill.

Caveat: Switchyard prices a call from the provider's reported charge, else from its bundled
rates, and a model with no rate leaves the total unknown: the report then says so and shows
the priced subtotal as a subtotal. A route the proxy does not serve fails the review before
any call (exit 3), which falls back to the agents.
"""

import sys
import time

from flow_spec import KIT
from flow_verdict import ReviewError

# routing.py ships with the hooks, which exported kits carry without tools/lib.
sys.path.append(str(KIT / "hooks" / "scripts"))
import routing  # noqa: E402

ORIGIN = "devil-flow"
HEADER = ("Model", "Calls", "Prompt tokens", "Completion tokens", "USD")
# Switchyard appends a call's record once its stream drains, which can be just after the
# client has read the last byte: ask a few times before taking the client's figure.
TRIES, PAUSE = 5, 0.4


def route(root, name):
    """The proxy the project at root is routed through, or "". Routed and down, or with
    no route `name`, is an error: the review would only fail there, and say less why."""
    url = routing.routed_url(root)
    if not url:
        return ""
    if not routing.healthy(url):
        raise ReviewError(
            f"this project routes through Switchyard at {url}, which is down: "
            "devil route start, or devil route off"
        )
    listed = routing.get_json(url + "/v1/models")
    data = listed.get("data") if isinstance(listed, dict) else None
    data = data if isinstance(data, list) else []
    if name not in {m.get("id") for m in data if isinstance(m, dict)}:
        raise ReviewError(
            f"Switchyard at {url} serves no route {name}: "
            "devil route status lists them; set the review step's route to one"
        )
    return url


def session_id(run_dir):
    return f"devil-flow-{run_dir.name}"


def routed_env(env, url, session):
    """env for a claude call through url, tagged so its records are this run's alone."""
    kept = env.get("ANTHROPIC_CUSTOM_HEADERS", "").splitlines()
    kept = [h for h in kept if h and not h.lower().startswith("x-switchyard-")]
    tags = [f"x-switchyard-session-id: {session}", f"x-switchyard-origin: {ORIGIN}"]
    # Switchyard forwards only the oauth-* betas, so a request that needs another fails
    # (HTTP 400): turn them off here, since --bare skips the settings `devil route on` wrote.
    return dict(
        env,
        ANTHROPIC_BASE_URL=url,
        ANTHROPIC_CUSTOM_HEADERS="\n".join(kept + tags),
        CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS="1",
    )


def _num(value):
    ok = isinstance(value, (int, float)) and not isinstance(value, bool)
    return value if ok else None


def _int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def _totals(cost):
    return cost if isinstance(cost, dict) else {}


def from_stats(stats, session):
    """The report's cost from a session-stats answer, every field typed: it is another
    process's JSON, rendered into report.md."""
    models = stats.get("models") if isinstance(stats.get("models"), dict) else {}
    rows = []
    for model, m in sorted(models.items()):
        m = m if isinstance(m, dict) else {}
        rows.append(
            {
                "model": str(model),
                "calls": _int(m.get("calls")),
                "prompt_tokens": _int(m.get("prompt_tokens")),
                "completion_tokens": _int(m.get("completion_tokens")),
                "usd": _num(_totals(m.get("cost")).get("total_usd")),
            }
        )
    cost = _totals(stats.get("cost"))
    return {
        "source": "switchyard",
        "session": session,
        "usd": _num(cost.get("total_usd")),
        "known_usd": _num(cost.get("known_usd")) or 0,
        "unknown_calls": _int(cost.get("unknown_calls")),
        "models": rows,
    }


def measure(client_usd, url, session):
    """The review's cost: Switchyard's when routed and it has the session, else the
    client's estimate (with a note when Switchyard had no record)."""
    if not url:
        return {"source": "client", "usd": client_usd}
    query = f"{url}/v1/routing/session-stats?session_id={session}"
    for attempt in range(TRIES):
        stats = routing.get_json(query)
        if isinstance(stats, dict):
            return from_stats(stats, session)
        if attempt + 1 < TRIES:
            time.sleep(PAUSE)
    note = f"Switchyard at {url} has no record of session {session}"
    return {"source": "client", "usd": client_usd, "note": note}


def _usd(value, missing):
    return missing if value is None else f"${value:.4f}"


def describe(cost):
    """(one line, table rows) for report.md; rows only for Switchyard's figures."""
    if cost["source"] != "switchyard":
        line = f"{_usd(cost['usd'], 'unknown')}, the CLI's client-side estimate (not a bill)."
        return (f"{line} {cost['note']}." if cost.get("note") else line), []
    rows = [
        (
            m["model"],
            m["calls"],
            m["prompt_tokens"],
            m["completion_tokens"],
            _usd(m["usd"], "unpriced"),
        )
        for m in cost["models"]
    ]
    total = _usd(cost["usd"], "")
    if not total:
        total = (
            f"unknown, {cost['unknown_calls']} call(s) unpriced "
            f"(priced subtotal ${cost['known_usd']:.4f})"
        )
    return (
        f"Total {total}, from Switchyard's routing log for session `{cost['session']}`: "
        "the provider's reported charge where it gave one, else Switchyard's bundled "
        "rates (not a bill).",
        rows,
    )
