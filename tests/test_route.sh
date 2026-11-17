#!/usr/bin/env bash
# test_route.sh - `devil route`: the Switchyard template, the proxy's docker argv, and the
# per-project on/off that must restore settings.local.json exactly.
#
# `docker` and `curl` are fakes on PATH, so nothing builds, listens or reaches the network.
# HOME, XDG and git config are throwaway, so the developer's global gitignore cannot hide
# the "not git-ignored" refusal.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTE="$ROOT/tools/route.sh"
PASS=0
FAIL=0

ok() {
  echo "ok   - $1"
  PASS=$((PASS + 1))
}
no() {
  echo "FAIL - $1"
  FAIL=$((FAIL + 1))
}
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

TMP="$(mktemp -d)"
trap 'kill ${SRV:-} 2>/dev/null; rm -rf "$TMP"' EXIT
SECRET="sk-ant-planted-$$-never-print"
mkdir -p "$TMP/bin" "$TMP/home"
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" XDG_STATE_HOME="$TMP/state"
export GIT_CONFIG_GLOBAL="$TMP/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 ANTHROPIC_API_KEY="$SECRET"
export FAKE="$TMP" PATH="$TMP/bin:$PATH"
unset DEVIL_SWITCHYARD_REF DEVIL_SWITCHYARD_PORT

# docker: logs its argv; an image exists if $FAKE/image, a dry-run fails if $FAKE/badconf,
# and `run -d` makes the proxy healthy.
cat >"$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/docker.log"
case "$1 $2" in
"image inspect") [ -f "$FAKE/image" ] ;;
"inspect -f") exit 1 ;;
*)
  case " $* " in
  *" --dry-run "*) if [ -f "$FAKE/badconf" ]; then echo "invalid server config" >&2; exit 1; fi; echo "server OK" ;;
  *" -d "*) touch "$FAKE/healthy" ;;
  esac ;;
esac
SH
# curl: /health answers while $FAKE/healthy exists; session-stats answers for "s1" only;
# /v1/models lists the template's routes, less switchyard-judged if $FAKE/nojudged.
cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
*/health) [ -f "$FAKE/healthy" ] ;;
*/v1/models)
  judged='{"id":"switchyard-judged"},'
  [ ! -f "$FAKE/nojudged" ] || judged=""
  echo "{\"data\":[{\"id\":\"devil-fast\"},{\"id\":\"devil-review\"},$judged{\"id\":\"switchyard\"}]}" ;;
*session_id=s1) echo '{"session_id":"s1","cost":{"total_usd":0.5}}' ;;
*) exit 22 ;;
esac
SH
chmod +x "$TMP/bin/docker" "$TMP/bin/curl"

run() { (cd "${HOST:-$TMP}" && bash "$ROUTE" "$@") >>"$TMP/out" 2>&1; }

# --- the template ---------------------------------------------------------------
TPL="$ROOT/templates/switchyard/routes.toml"
check "template parses; one client, Anthropic only, forward_auth" "python3 -I -c '
import sys, tomllib
c = tomllib.load(open(sys.argv[1], \"rb\"))[\"llm_clients\"]
assert list(c) == [\"anthropic\"], c
assert c[\"anthropic\"][\"base_url\"] == \"https://api.anthropic.com\"
assert c[\"anthropic\"][\"forward_auth\"] is True' '$TPL'"
check "template holds no key and names no key variable" "! grep -qE 'api_key|sk-' '$TPL'"
check "the default main route makes no model call of its own (no judge)" "python3 -I -c '
import sys, tomllib
r = tomllib.load(open(sys.argv[1], \"rb\"))[\"routes\"][\"switchyard\"]
assert r[\"type\"] == \"stage_router\" and not {\"classifier\", \"subagents\"} & r.keys(), r' '$TPL'"

# --- usage and settings ---------------------------------------------------------
run
check "no subcommand is exit 2" "[ $? -eq 2 ]"
run --help
check "--help is exit 0" "[ $? -eq 0 ]"
DEVIL_SWITCHYARD_REF=main run status
check "a ref that is not a full sha is exit 2" "[ $? -eq 2 ]"
DEVIL_SWITCHYARD_PORT=80 run status
check "a privileged port is exit 2" "[ $? -eq 2 ]"

# --- the proxy ------------------------------------------------------------------
run build
check "build pins the full commit" "grep -q 'build -t devil-switchyard:fcd2a4f .*Switchyard-nvidia.git#fcd2a4feeb6a2a0e36cbea00ee69a1469000221f' '$TMP/docker.log'"
run start
check "start without the image is exit 1" "[ $? -eq 1 ]"
touch "$TMP/image" "$TMP/badconf"
run start
check "start with invalid routes is exit 2" "[ $? -eq 2 ]"
check "invalid routes never start a container" "! grep -q ' -d ' '$TMP/docker.log'"
check "start seeds the routes from the template" "cmp -s '$TPL' '$TMP/state/devil/switchyard/routes.toml'"
rm -f "$TMP/badconf"
: >"$TMP/docker.log"
run start
check "start is exit 0" "[ $? -eq 0 ]"
check "the dry-run comes before the container" "grep -n -e '--dry-run' -e ' -d ' '$TMP/docker.log' | head -1 | grep -q -e '--dry-run'"
RUNLINE="$(grep ' -d ' "$TMP/docker.log")"
for want in "-p 127.0.0.1:4123:4000" "--read-only" "--cap-drop ALL" \
  "--security-opt no-new-privileges" "/config/routes.toml:ro"; do
  if [[ "$RUNLINE" == *"$want"* ]]; then ok "run argv has $want"; else no "run argv has $want"; fi
done

# --- on / off in a project ------------------------------------------------------
HOST="$TMP/host"
SETTINGS="$HOST/.claude/settings.local.json"
mkdir -p "$HOST/.claude" && git -C "$HOST" init -q
printf '%s\n' '{"permissions":{"allow":["Bash(ls)"]},"env":{"FOO":"1","ANTHROPIC_MODEL":"opus"},
  "modelOverrides":{"claude-opus-5-5":"my-opus","claude-fable-5-2":"my-fable"}}' >"$SETTINGS"
cp "$SETTINGS" "$TMP/orig.json"
run on
check "on refuses a settings file git would commit (exit 1)" "[ $? -eq 1 ]"
check "a refused on leaves the file unchanged" "cmp -s '$SETTINGS' '$TMP/orig.json'"
echo ".claude/settings.local.json" >"$HOST/.gitignore"
rm -f "$TMP/healthy"
run on
check "on with the proxy down is exit 1" "[ $? -eq 1 ]"
check "on with the proxy down leaves the file unchanged" "cmp -s '$SETTINGS' '$TMP/orig.json'"
touch "$TMP/healthy"
run on
check "on is exit 0" "[ $? -eq 0 ]"
check "on points the project at the loopback proxy" "[ \"\$(jq -r .env.ANTHROPIC_BASE_URL '$SETTINGS')\" = http://127.0.0.1:4123 ]"
check "on keeps unrelated keys" "[ \"\$(jq -r '.env.FOO + .modelOverrides[\"claude-fable-5-2\"]' '$SETTINGS')\" = 1my-fable ]"
check "on turns off the betas Switchyard drops" "jq -e '.env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS == \"1\"' '$SETTINGS' >/dev/null"
check "on maps Claude Code's model IDs to the routes" "jq -e '.env.ANTHROPIC_MODEL == \"claude-sonnet-5-5\" and .modelOverrides == {\"claude-opus-5-5\": \"devil-review\", \"claude-sonnet-5-5\": \"switchyard\", \"claude-haiku-5-5\": \"devil-fast\", \"claude-fable-5-2\": \"my-fable\"}' '$SETTINGS' >/dev/null"
check "the IDs on maps are the template's targets" "python3 -I -c '
import json, sys, tomllib
t = {v[\"id\"] for v in tomllib.load(open(sys.argv[1], \"rb\"))[\"targets\"].values()}
m = json.load(open(sys.argv[2]))[\"_devilRoute\"][\"modelOverrides\"][\"set\"]
assert set(m) == t, (m, t)' '$TPL' '$SETTINGS'"
run stop
check "stop is refused while a project is routed (exit 1)" "[ $? -eq 1 ]"
check "the refusal names the project" "grep -q 'still on in $HOST' '$TMP/out'"
rm -f "$TMP/healthy"
run off
check "off works with the proxy down" "[ $? -eq 0 ]"
check "on then off restores the file exactly" "[ \"\$(jq -S . '$SETTINGS')\" = \"\$(jq -S . '$TMP/orig.json')\" ]"
touch "$TMP/healthy"
run on
jq '.env.ANTHROPIC_MODEL = "mine"' "$SETTINGS" >"$TMP/edited.json" && cp "$TMP/edited.json" "$SETTINGS"
run off
check "off refuses a key the user changed since on (exit 1)" "[ $? -eq 1 ]"
check "a refused off keeps the user's edit" "cmp -s '$SETTINGS' '$TMP/edited.json'"
jq '.env.ANTHROPIC_MODEL = "claude-sonnet-5-5" | .modelOverrides["claude-haiku-5-5"] = "x"' \
  "$TMP/edited.json" >"$SETTINGS"
run off
check "off refuses an override the user changed since on (exit 1)" "[ $? -eq 1 ] && grep -q 'modelOverrides.claude-haiku-5-5' '$TMP/out'"
cp "$TMP/orig.json" "$SETTINGS"
run on --judged
check "on --judged sends the main loop to switchyard-judged" "jq -e '.modelOverrides[\"claude-sonnet-5-5\"] == \"switchyard-judged\"' '$SETTINGS' >/dev/null"
run off
check "on --judged then off restores the file exactly" "[ \"\$(jq -S . '$SETTINGS')\" = \"\$(jq -S . '$TMP/orig.json')\" ]"
touch "$TMP/nojudged"
cp "$SETTINGS" "$TMP/before.json"
run on --judged
check "on refuses a route the proxy lacks (exit 1), file unchanged" "[ $? -eq 1 ] && cmp -s '$SETTINGS' '$TMP/before.json'"
rm -f "$TMP/nojudged"
run on --bogus
check "on with an unknown flag is exit 2" "[ $? -eq 2 ]"
rm -f "$SETTINGS"
run on
check "on creates a missing settings file" "jq -e ._devilRoute.created '$SETTINGS' >/dev/null"
run off
check "off deletes the file that on created" "[ ! -e '$SETTINGS' ]"
run stop
check "stop runs once no project is routed" "[ $? -eq 0 ]"
echo '{not json' >"$SETTINGS"
run on
check "on with invalid JSON is exit 2" "[ $? -eq 2 ]"
echo '{"modelOverrides":"x"}' >"$SETTINGS"
run on
check "on with a modelOverrides that is not an object is exit 2" "[ $? -eq 2 ] && [ \"\$(cat '$SETTINGS')\" = '{\"modelOverrides\":\"x\"}' ]"
rm -f "$SETTINGS"
run status
check "status lists the proxy's routes" "grep -q 'routes: devil-fast devil-review switchyard-judged switchyard' '$TMP/out'"

# --- log ------------------------------------------------------------------------
run log --session 'bad id'
check "log rejects a malformed session id (exit 2)" "[ $? -eq 2 ]"
run log --session s1
check "log --session prints the proxy's stats" "grep -q '\"total_usd\": 0.5' '$TMP/out'"
mkdir -p "$TMP/state/devil/switchyard/log"
{
  echo '{"ts":"t","route_id":"switchyard","tier":"capable","model":"claude-opus-5-5","delegated":false,"total_tokens":9,"cost":{"usd":0.25,"source":"estimated"}}'
  echo '{"session_id":"s1","outcome":{"resolved":true}}'
} >"$TMP/state/devil/switchyard/log/routing.jsonl"
rows="$(cd "$HOST" && bash "$ROUTE" log | tail -n +2)"
want=$'t\tswitchyard\tcapable\tclaude-opus-5-5\tfalse\t-\t9\t0.25'
if [ "$rows" = "$want" ]; then ok "log prints one TSV row per call, and no outcome rows"; else no "log rows: $rows"; fi

# --- the SessionStart guard -------------------------------------------------------
# hooks.py route-guard probes the real loopback port (no curl), so the port is a free one.
guard() {
  printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' |
    CLAUDE_PROJECT_DIR="$HOST" python3 "$ROOT/hooks/scripts/hooks.py" route-guard 2>&1 |
    tee -a "$TMP/out"
}
listening() { python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$1" 2>/dev/null; }
P="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
cp "$TMP/orig.json" "$SETTINGS"
if [ -z "$(guard)" ]; then ok "the guard is silent in a project that is not routed"; else no "the guard spoke in an unrouted project"; fi
DEVIL_SWITCHYARD_PORT="$P" run on
out="$(guard)"
case "$out" in
*'"systemMessage"'*"turned model routing off"*) ok "the guard turns routing off when the proxy is down" ;;
*) no "the guard on a dead port said: ${out:0:160}" ;;
esac
check "the guard restores the settings exactly" "[ \"\$(jq -S . '$SETTINGS')\" = \"\$(jq -S . '$TMP/orig.json')\" ]"
DEVIL_SWITCHYARD_PORT="$P" run on
# An exported kit (codex, copilot) ships hooks/ without tools/: it must stay silent.
mkdir -p "$TMP/kit" && cp -r "$ROOT/hooks" "$TMP/kit/"
out="$(printf '%s' '{"hook_event_name":"SessionStart","source":"startup"}' |
  CLAUDE_PROJECT_DIR="$HOST" python3 "$TMP/kit/hooks/scripts/hooks.py" route-guard 2>&1)"
if [ -z "$out" ] && jq -e ._devilRoute "$SETTINGS" >/dev/null; then
  ok "a kit without tools/ leaves the route alone and says nothing"
else
  no "a kit without tools/ said: ${out:0:160}"
fi
mkdir -p "$TMP/www" && touch "$TMP/www/health"
python3 -m http.server --bind 127.0.0.1 --directory "$TMP/www" "$P" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 50); do listening "$P" && break || sleep 0.1; done
if [ -z "$(guard)" ] && jq -e ._devilRoute "$SETTINGS" >/dev/null; then
  ok "the guard leaves a healthy route alone"
else
  no "the guard touched a healthy route"
fi
kill "$SRV" && wait "$SRV" 2>/dev/null
run off

# --- secrets ----------------------------------------------------------------------
check "the API key never reaches any output or docker argv" "! grep -qF '$SECRET' '$TMP/out' '$TMP/docker.log'"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
