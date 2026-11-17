#!/usr/bin/env bash
# route.sh: `devil route`, NVIDIA Switchyard run locally in Docker, so a project's Claude Code
# sessions send each call to Haiku, Sonnet or Opus by what the call needs.
#
# Usage: devil route build                 build the pinned image (network; slow the first time)
#        devil route start                 validate the routes, then run the proxy on 127.0.0.1
#        devil route stop [--force]        remove the proxy (refused while a project is routed)
#        devil route status                container, health, config and routed projects
#        devil route on [--judged] | off   route this project (.claude/settings.local.json)
#        devil route log [--session ID]    the last 100 routed calls, or one session's cost
#
# The routes live in ${XDG_STATE_HOME:-~/.local/state}/devil/switchyard/routes.toml, seeded
# once from templates/switchyard/routes.toml; edit it, then `devil route start` again. Every
# call forwards the caller's own Claude login (forward_auth), so no key is stored anywhere.
# Exit: 0 done, 1 refused or the proxy is down, 2 usage, a bad setting or an invalid file.
# Caveat: `on` applies from the next claude start, and a proxy that dies mid-session breaks
# that session; the next start finds it down and turns routing off (hooks.py route-guard).
# The log rotates at start only (one 50 MB generation kept). Switchyard forwards only the
# oauth-* betas, so `on` turns Claude Code's others off: a request needing one fails (HTTP
# 400). --judged needs an API key: a subscription login is refused the judge's calls (429).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$DIR/lib/common.sh"

KIT="$(cd "$DIR/.." && pwd)"
REPO="https://github.com/Univers42/Switchyard-nvidia.git"
REF="${DEVIL_SWITCHYARD_REF:-fcd2a4feeb6a2a0e36cbea00ee69a1469000221f}"
PORT="${DEVIL_SWITCHYARD_PORT:-4123}"
NAME="devil-switchyard"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/devil/switchyard"
CONF="$STATE/routes.toml"
LOG="$STATE/log/routing.jsonl"
URL="http://127.0.0.1:$PORT"

die() {
  echo "route: $2" >&2
  exit "$1"
}

# usage CODE: the usage lines of this header, on stdout for 0 and stderr otherwise.
usage() {
  sed -n '5,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&$((${1} ? 2 : 1))
  exit "$1"
}

if ! [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
  die 2 "DEVIL_SWITCHYARD_REF must be a full 40-character commit sha"
fi
if ! [[ "$PORT" =~ ^[0-9]{4,5}$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
  die 2 "DEVIL_SWITCHYARD_PORT must be a port from 1024 to 65535"
fi
IMG="$NAME:${REF:0:7}"

healthy() { curl -fsS --max-time 2 "$URL/health" >/dev/null 2>&1; }

need_docker() { have docker || die 2 "needs docker"; }

# --- the proxy ----------------------------------------------------------------

cmd_build() {
  need_docker
  echo "route: building $IMG from $REPO at $REF"
  "$DIR/watch.sh" --timeout 3600 --idle 900 -- \
    docker build -t "$IMG" --label "devil.switchyard.ref=$REF" "$REPO#$REF"
}

# The routes are the user's, outside every repo: they decide where the login is forwarded,
# so a cloned project must never supply them.
seed_routes() {
  local tpl="$KIT/templates/switchyard/routes.toml"
  mkdir -p "$STATE/log" || die 1 "cannot create $STATE"
  if [ ! -f "$CONF" ]; then
    cp "$tpl" "$CONF" || die 1 "cannot write $CONF"
    echo "route: seeded $CONF"
  elif ! cmp -s "$CONF" "$tpl"; then
    echo "route: $CONF differs from the kit template; yours is used"
  fi
}

wait_healthy() { for _ in $(seq 40); do healthy && return 0 || sleep 0.5; done && return 1; }

cmd_start() {
  local want running
  need_docker
  docker image inspect "$IMG" >/dev/null 2>&1 || die 1 "no image $IMG yet; run: devil route build"
  seed_routes
  docker run --rm --read-only --network none --user "$(id -u):$(id -g)" \
    -v "$CONF:/config/routes.toml:ro" "$IMG" --config /config/routes.toml --dry-run ||
    die 2 "$CONF is invalid (see above)"
  # The label pins image and routes: a container started from either older one is replaced.
  want="$IMG@$(cksum <"$CONF" | cut -d' ' -f1)"
  running="$(docker inspect -f '{{index .Config.Labels "devil.switchyard.run"}}' "$NAME" 2>/dev/null)"
  if [ "$running" = "$want" ] && healthy; then
    echo "route: already running at $URL"
    return 0
  fi
  docker rm -f "$NAME" >/dev/null 2>&1
  if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 52428800 ]; then mv -f "$LOG" "$LOG.1"; fi
  docker run -d --name "$NAME" --restart unless-stopped --label "devil.switchyard.run=$want" \
    -p "127.0.0.1:$PORT:4000" --read-only --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 256 --memory 512m --user "$(id -u):$(id -g)" --tmpfs /tmp \
    -v "$CONF:/config/routes.toml:ro" -v "$STATE/log:/log" \
    "$IMG" --config /config/routes.toml --routing-log-file /log/routing.jsonl >/dev/null ||
    die 1 "docker run failed"
  if ! wait_healthy; then
    docker logs --tail 50 "$NAME" >&2
    die 1 "the proxy did not become healthy at $URL within 20 s"
  fi
  echo "route: running at $URL; next: devil route on (in a project)"
}

# Projects whose settings still carry `on`'s record: the registry, re-checked each time.
routed_projects() {
  local p
  [ -f "$STATE/projects" ] || return 0
  while IFS= read -r p; do
    if grep -qs '"_devilRoute"' "$p/.claude/settings.local.json"; then echo "$p"; fi
  done <"$STATE/projects"
}

cmd_stop() {
  local p n=0
  case "${1:-}" in "" | --force) ;; *) usage 2 ;; esac
  if [ "${1:-}" != --force ]; then
    while IFS= read -r p; do
      echo "route: still on in $p: (cd '$p' && devil route off)" >&2
      n=$((n + 1))
    done < <(routed_projects)
    [ "$n" -eq 0 ] || die 1 "turn routing off there first (or: devil route stop --force)"
  fi
  need_docker
  if docker rm -f "$NAME" >/dev/null 2>&1; then echo "route: stopped"; else echo "route: not running"; fi
}

cmd_status() {
  local state="docker missing" rc=0
  if have docker; then
    state="$(docker inspect -f '{{.State.Status}} ({{.Config.Image}})' "$NAME" 2>/dev/null)" ||
      state="absent"
  fi
  echo "container: $state"
  if healthy; then echo "health:    ok at $URL; routes: $(route_ids | paste -sd' ' -)"; else
    echo "health:    down at $URL"
    rc=1
  fi
  echo "routes:    $CONF"
  echo "log:       $LOG"
  echo "routed:"
  routed_projects | sed 's/^/  /'
  return "$rc"
}

# --- one project's settings ---------------------------------------------------

# Claude Code keeps its own model IDs (the template's targets), so it knows each model's
# features and prices; modelOverrides puts a route's id on the wire in their place. $1 is the
# main loop's route; whatever asks for Opus or Haiku by name gets that model, unrouted.
set_values() {
  jq -n --arg url "$URL" --arg main "$1" '{
    env: {ANTHROPIC_BASE_URL: $url, CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
      ANTHROPIC_MODEL: "claude-sonnet-5-5", ANTHROPIC_DEFAULT_OPUS_MODEL: "claude-opus-5-5",
      ANTHROPIC_DEFAULT_SONNET_MODEL: "claude-sonnet-5-5",
      ANTHROPIC_DEFAULT_HAIKU_MODEL: "claude-haiku-5-5"},
    modelOverrides: {"claude-opus-5-5": "devil-review", "claude-sonnet-5-5": $main,
      "claude-haiku-5-5": "devil-fast"}}'
}

route_ids() { curl -fsS --max-time 2 "$URL/v1/models" | jq -r '.data[].id' 2>/dev/null; }

# write_json FILE JSON: a temp file beside FILE, then a rename, so a crash leaves old or new.
write_json() {
  local tmp
  tmp="$(mktemp "$(dirname "$1")/.settings.local.json.XXXXXX")" || die 1 "cannot write next to $1"
  if ! printf '%s\n' "$2" >"$tmp" || ! mv -f "$tmp" "$1"; then
    rm -f "$tmp"
    die 1 "could not write $1"
  fi
}

settings_file() {
  local root f
  have jq || die 2 "needs jq"
  root="$(repo_root)"
  f="$root/.claude/settings.local.json"
  [ ! -L "$f" ] || die 1 "$f is a symlink; edit its target by hand"
  if [ -f "$f" ] && ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    die 2 "$f is not a JSON object; fix it first"
  fi
  echo "$f"
}

register() {
  local tmp="$STATE/projects.$$"
  mkdir -p "$STATE" || die 1 "cannot create $STATE"
  {
    grep -vxF "$1" "$STATE/projects" 2>/dev/null
    [ -z "${2:-}" ] || echo "$1"
  } >"$tmp"
  mv -f "$tmp" "$STATE/projects"
}

cmd_on() {
  local f root cur new main=switchyard created=false
  case "${1:-}" in "") ;; --judged) main=switchyard-judged ;; *) usage 2 ;; esac
  f="$(settings_file)" || exit $?
  root="$(dirname "$(dirname "$f")")"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    ! git -C "$root" check-ignore -q "$f"; then
    die 1 "$f is not git-ignored; ignore it first, so the proxy settings stay on this machine"
  fi
  healthy || die 1 "the proxy at $URL is down; run: devil route start"
  [ "$(route_ids | grep -cxF -e "$main" -e devil-review -e devil-fast)" -eq 3 ] ||
    die 1 "the proxy lacks a route of: $main devil-review devil-fast; see $CONF"
  if [ -f "$f" ] && jq -e 'has("_devilRoute")' "$f" >/dev/null; then
    echo "route: already on in $root"
    return 0
  fi
  [ -f "$f" ] || created=true
  mkdir -p "$root/.claude" || die 1 "cannot create $root/.claude"
  cur="$(cat "$f" 2>/dev/null || echo '{}')"
  # Per section (env, modelOverrides): what on set, what it replaced, whether it existed.
  new="$(jq --argjson v "$(set_values "$main")" --argjson created "$created" '
    def take($k): (.[$k] // {}) as $cur
      | ._devilRoute[$k] = {set: $v[$k], existed: has($k),
          previous: ($cur | with_entries(select(.key as $n | $v[$k] | has($n))))}
      | .[$k] = ($cur + $v[$k]);
    ._devilRoute = {created: $created} | take("env") | take("modelOverrides")' <<<"$cur")" ||
    die 2 "$f: env or modelOverrides is not an object"
  write_json "$f" "$new"
  register "$root" add
  echo "route: on for $root (main loop: $main); restart claude to route through $URL"
}

cmd_off() {
  local f root edited new
  f="$(settings_file)" || exit $?
  root="$(dirname "$(dirname "$f")")"
  if ! [ -f "$f" ] || ! jq -e 'has("_devilRoute")' "$f" >/dev/null; then
    register "$root"
    echo "route: already off in $root"
    return 0
  fi
  edited="$(jq -r '. as $d | ("env", "modelOverrides") as $k | ($d._devilRoute[$k].set // {})
    | to_entries[] | select(.value != ($d[$k] // {})[.key]) | "\($k).\(.key)"' "$f")" ||
    die 2 "$f: unreadable _devilRoute record"
  if [ -n "$edited" ]; then
    die 1 "$f: changed since 'on': $(echo "$edited" | paste -sd, -); restore or drop _devilRoute by hand"
  fi
  new="$(jq 'def give($k): ._devilRoute[$k] as $r
      | .[$k] = ((.[$k] // {}) | with_entries(select(.key as $n | $r.set | has($n) | not))
          + $r.previous)
      | if ($r.existed | not) and .[$k] == {} then del(.[$k]) else . end;
    give("env") | give("modelOverrides") | del(._devilRoute)' "$f")" ||
    die 2 "$f: unreadable _devilRoute record"
  if jq -e '._devilRoute.created == true' "$f" >/dev/null && [ "$new" = "{}" ]; then
    rm -f "$f" || die 1 "could not remove $f"
  else
    write_json "$f" "$new"
  fi
  register "$root"
  echo "route: off for $root; restart claude to talk to Anthropic directly"
}

cmd_log() {
  local sid=""
  case "${1:-}" in
  "") ;;
  --session) sid="${2:-}" ;;
  *) usage 2 ;;
  esac
  have jq || die 2 "needs jq"
  if [ "${1:-}" = --session ]; then
    [[ "$sid" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || die 2 "--session needs an id of [A-Za-z0-9._:-]"
    healthy || die 1 "the proxy at $URL is down"
    curl -fsS --max-time 5 "$URL/v1/routing/session-stats?session_id=$sid" | jq . ||
      die 1 "no routing records for session $sid"
    return
  fi
  [ -s "$LOG" ] || die 1 "no routed calls yet ($LOG)"
  printf 'ts\troute\ttier\tmodel\tdelegated\trole\ttokens\tcost_usd\n'
  # Calls only: the log also holds a record per session outcome, with no route.
  tail -n 100 "$LOG" | jq -r 'select(has("route_id")) | [.ts, .route_id, .tier, .model,
    .delegated, .agent_role, .total_tokens, .cost.usd?]
    | map(if . == null or . == "" then "-" else tostring end) | @tsv'
}

case "${1:-}" in
build) cmd_build ;;
start) cmd_start ;;
stop) cmd_stop "${2:-}" ;;
status) cmd_status ;;
on) cmd_on "${2:-}" ;;
off) cmd_off ;;
log) cmd_log "${2:-}" "${3:-}" ;;
-h | --help) usage 0 ;;
*) usage 2 ;;
esac
