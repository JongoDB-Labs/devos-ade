# shellcheck shell=bash
# JON-972 phase A: setup's update mode (lib/steps.sh upd_gate): a step runs only when its inputs changed since the last
# successful setup. Docker is stubbed: the containers' identity and the images' IDs come from $LITELLM_CTR, $OWUI_CTR, $PORTAL_ID.
. "$STACK_DIR/lib/commands.sh"

_um_setup() {
  STACK_DIR="$TMP/stack"; mkdir -p "$STACK_DIR/litellm" "$STACK_DIR/catalog" "$STACK_DIR/lib" "$STACK_DIR/stt" "$STACK_DIR/owui" "$STACK_DIR/searxng"
  CATALOG="$TMP/models.tsv"; printf 'big\tchat\tbedrock/x\t-\t-\n' > "$CATALOG"
  printf 'services:\n  litellm:\n    image: ghcr.io/berriai/litellm:1.105.0\n' > "$STACK_DIR/compose.yaml"
  printf 'big\n' > "$STACK_DIR/litellm/enabled-models.txt"; printf 'big\tchat\tENABLED\n' > "$STACK_DIR/litellm/probe-results.tsv"
  printf 'LITELLM_PORT=4000\nAWS_REGION_NAME=us-east-1\nPORTAL_PASSWORD=pw\nLITELLM_KEY_SETUP=sk-a\nLITELLM_KEY_CLAUDE_CODE=sk-b\nLITELLM_KEY_OPENWEBUI=sk-c\nOPENWEBUI_API_KEY=sk-d\nLITELLM_DB_ADMIN_READY=true\n' > "$ENV_FILE"
  PRICES_DIR="$TMP/prices"; mkdir -p "$PRICES_DIR"; : > "$PRICES_DIR/prices.meta.json"
  cp "$T_ROOT/tests/fixtures/prices.tsv" "$STACK_DIR/catalog/prices.tsv"; PRICES_CATALOG="$STACK_DIR/catalog/prices.tsv"; use_best_prices   # (as the prices step leaves them)
  LITELLM_CTR="/p-litellm-1 L1 2026-11-01T10:00:00Z"; OWUI_CTR="/p-open-webui-1 O1 2026-11-01T10:00:00Z"; PORTAL_ID=P1
  dc() { case "$*" in "ps -q litellm open-webui") printf 'c1\nc2\n' ;; esac; return 0; }
  PGDATA_AT=2026-10-01T09:00:00Z
  docker() { case "$1 $2" in "inspect --format") printf '%s\n%s\n' "$LITELLM_CTR" "$OWUI_CTR" ;; "volume inspect") echo "$PGDATA_AT" ;; *) echo "unexpected docker $*" >&2; return 1 ;; esac; }
  snapshot_refs() { printf '%s\t%s\n' "$PORTAL_ID" "$(project_name)/portal:local"; }
  remote_on() { return 1; }
  websearch_backend() { echo builtin; }
  _GATES="settings prices litellm_config voice stt_service keys searxng websearch gitserver codedefault gitafter signin syncs smoke"
}
# _um_run [update] — every gate once, in setup's order, each "running" by logging its name; the digests are committed at the end
_um_run() {
  local g; : > "$TMP/ran"; upd_begin; UPD_MODE=0; [ "${1:-}" != update ] || UPD_MODE=1
  for g in $_GATES; do upd_gate "$g" "step $g" "why" sh -c "echo $g >> '$TMP/ran'"; done
  upd_commit
  tr '\n' ' ' < "$TMP/ran" | sed 's/ $//'
}

test_an_update_with_nothing_changed_runs_none_of_the_gated_steps() {
  _um_setup
  assert_eq "$(_um_run)" "settings prices litellm_config voice stt_service keys searxng websearch gitserver codedefault gitafter signin syncs smoke"   # a setup run by itself: every step
  [ -s "$STATE_DIR/update/step-inputs.tsv" ] || { echo "no state written" >&2; return 1; }
  assert_not_contains "$(cat "$STATE_DIR/update/step-inputs.tsv")" "sk-a"            # (hashes: never a key)
  assert_eq "$(_um_run update)" ""
  assert_contains "$(_um_run update 2>&1; true)" ""
  # and again: the skipped steps' digests were kept
  assert_eq "$(_um_run update)" ""
}

test_a_skipped_step_is_said_with_its_reason_and_its_own_step_on_the_card() {
  _um_setup; _um_run > /dev/null
  upd_begin; UPD_MODE=1
  out="$(upd_gate keys "LiteLLM keys" "the keys did not change" echo RAN 2>&1)"
  assert_contains "$out" "LiteLLM keys: not run — the keys did not change"
  assert_contains "$out" "LiteLLM keys ready (skipped)"
  assert_not_contains "$out" "RAN"
}

test_each_input_changing_runs_exactly_its_steps() {
  _um_setup; _um_run > /dev/null
  # LiteLLM restarted or recreated: the search check and the smoke test
  LITELLM_CTR="/p-litellm-1 L2 2026-11-01T11:00:00Z"; assert_eq "$(_um_run update)" "websearch smoke"
  assert_eq "$(_um_run update)" ""
  # Open WebUI recreated (its banner lives in its memory): the sign-in and the syncs
  OWUI_CTR="/p-open-webui-1 O2 2026-11-01T11:00:00Z"; assert_eq "$(_um_run update)" "signin syncs"
  # the portal image rebuilt: prices (the updater runs in it), the sign-in, the git account
  PORTAL_ID=P2; assert_eq "$(_um_run update)" "prices gitafter signin"
  # Postgres's volume made again (it held LiteLLM's keys): the keys
  PGDATA_AT=2026-11-01T12:00:00Z; assert_eq "$(_um_run update)" "keys"
  # a model in the catalog: the config and the syncs
  printf 'small\tchat\tbedrock/y\t-\t-\n' >> "$CATALOG"; assert_eq "$(_um_run update)" "litellm_config syncs"
  # the models found
  printf 'big\nsmall\n' > "$STACK_DIR/litellm/enabled-models.txt"; assert_eq "$(_um_run update)" "litellm_config websearch syncs smoke"
  # the price file older than 12 hours: prices
  touch -t 202601010000 "$PRICES_DIR/prices.meta.json"; assert_eq "$(_um_run update)" "prices"
  assert_eq "$(_um_run update)" "prices"   # (still old: the updater could not refresh it — asked again next time)
  touch "$PRICES_DIR/prices.meta.json"; assert_eq "$(_um_run update)" "prices"; assert_eq "$(_um_run update)" ""
  # compose files (the images they pin): the services' steps, not the settings
  printf '    image: ghcr.io/berriai/litellm:1.106.0\n' >> "$STACK_DIR/compose.yaml"
  assert_eq "$(_um_run update)" "stt_service keys searxng gitserver gitafter smoke"
  # a key setup made: the keys, the sign-in, the syncs, the checks that use them
  sed -i.bak 's/^LITELLM_KEY_SETUP=.*/LITELLM_KEY_SETUP=sk-new/' "$ENV_FILE"
  assert_eq "$(_um_run update)" "keys websearch signin syncs smoke"
  # a setting in .env: every step that reads .env, not the prices
  sed -i.bak 's/us-east-1/eu-west-1/' "$ENV_FILE"
  assert_eq "$(_um_run update)" "settings litellm_config voice stt_service keys searxng websearch gitserver codedefault gitafter signin syncs smoke"
  # the step's own code (a release that changes it)
  upd_in_voice_before="$(declare -f stt_after_probe 2>/dev/null)"; stt_after_probe() { echo changed; }
  assert_contains "$(_um_run update)" "voice"
}

test_a_failed_setup_leaves_no_state_and_the_next_update_runs_every_step() {
  _um_setup; _um_run > /dev/null
  upd_begin   # a setup that begins and does not get to the end
  [ ! -e "$STATE_DIR/update/step-inputs.tsv" ] || { echo "the old state stayed while setup ran" >&2; return 1; }
  assert_eq "$(_um_run update)" "settings prices litellm_config voice stt_service keys searxng websearch gitserver codedefault gitafter signin syncs smoke"
  # a step that fails is not noted: its digest is not written even when setup went on
  upd_begin; UPD_MODE=0; upd_gate keys "keys" "w" false || true; upd_commit
  assert_not_contains "$(cat "$STATE_DIR/update/step-inputs.tsv")" "keys"
}

test_force_and_a_plain_setup_run_every_step() {
  _um_setup; _um_run > /dev/null
  all="settings prices litellm_config voice stt_service keys searxng websearch gitserver codedefault gitafter signin syncs smoke"
  assert_eq "$(_um_run)" "$all"                       # ./stack setup by itself and ./stack update --force: no --update-mode
  # cmd_setup turns the mode on only for the flag the update passes
  assert_contains "$(sed -n '/^cmd_setup() {/,/^}/p' "$T_ROOT/lib/commands.sh")" "--update-mode) UPD_MODE=1"
  assert_contains "$(sed -n '/^cmd_update() {/,/^}/p' "$T_ROOT/lib/commands.sh")" "setupargs=(--update-mode)"
}

test_remote_access_on_always_runs_the_settings_step() {
  _um_setup; _um_run > /dev/null
  remote_on() { return 0; }; _um_run > /dev/null
  assert_contains "$(_um_run update)" "settings"
}

# The trace (DEVOS_ADE_UPD_TRACE=1 or .state/update/trace-on: the e2e upgrade test): what made a step run, never a key's value
test_the_trace_says_which_input_changed_and_never_writes_a_value() {
  _um_setup; _um_run > /dev/null
  [ ! -e "$STATE_DIR/update/trace" ] || { echo "a trace without the switch" >&2; return 1; }
  mkdir -p "$STATE_DIR/update"; : > "$STATE_DIR/update/trace-on"
  _um_run > /dev/null
  [ -s "$STATE_DIR/update/trace/signin.note" ] || { echo "no trace written" >&2; return 1; }
  all="$(cat "$STATE_DIR"/update/trace/*)"
  assert_not_contains "$all" "sk-a"; assert_not_contains "$all" "sk-d"; assert_not_contains "$all" "=pw"
  assert_contains "$all" "LITELLM_KEY_SETUP="
  OWUI_CTR="/p-open-webui-1 O2 2026-11-01T11:00:00Z"; assert_eq "$(_um_run update)" "signin syncs"
  d="$(diff "$STATE_DIR/update/trace.prev/signin.note" "$STATE_DIR/update/trace/signin.same" || true)"   # (diff: 1 when they differ)
  assert_contains "$d" "< /p-open-webui-1 O1"; assert_contains "$d" "> /p-open-webui-1 O2"
  assert_eq "$(printf '%s\n' "$d" | grep -c '^[<>]')" "2"
  # (a skipped step's digest: .same only)
  [ -s "$STATE_DIR/update/trace/keys.same" ] && [ ! -e "$STATE_DIR/update/trace/keys.note" ] || { echo "skipped step traced wrong" >&2; return 1; }
  [ "$(stat -c %a "$STATE_DIR/update/trace" 2>/dev/null || stat -f %Lp "$STATE_DIR/update/trace")" = 700 ] || { echo "trace folder not private" >&2; return 1; }
}

test_the_call_profile_times_each_docker_curl_and_sleep_by_its_callers_and_keeps_no_argument() {
  _um_setup
  curl() { return 7; }; sleep() { :; }   # (the stubs stay what is called: the profile only times them)
  upd_begin
  [ ! -e "$STATE_DIR/update/trace/calls.tsv" ] || { echo "a profile without the switch" >&2; return 1; }
  mkdir -p "$STATE_DIR/update"; : > "$STATE_DIR/update/trace-on"
  upd_begin; upd_begin   # (a second begin wraps nothing twice)
  um_starts() { docker compose -p proj-x -f "$STACK_DIR/compose.yaml" --profile p up -d portal 2> /dev/null; }
  assert_eq "$(docker inspect --format '{{.Name}}' c1 c2)" "$(printf '%s\n%s' "$LITELLM_CTR" "$OWUI_CTR")"
  rc=0; um_starts || rc=$?; assert_eq "$rc" "1"
  rc=0; curl -H "Authorization: Bearer sk-secret" http://x/ || rc=$?; assert_eq "$rc" "7"
  sleep 2
  phase_start "Images"; phase_line "Images" 3 > /dev/null   # (a step's start and end: lines of their own)
  p="$(cat "$STATE_DIR/update/trace/calls.tsv")"
  assert_eq "$(printf '%s\n' "$p" | wc -l | tr -d ' ')" "6"
  assert_contains "$p" "	docker inspect	"; assert_contains "$p" "	docker compose.up	um_starts<"; assert_contains "$p" "	curl	"; assert_contains "$p" "	sleep	"
  assert_contains "$p" "0	step	begin Images	"; assert_contains "$p" "0	step	end Images	"
  for v in sk-secret Authorization proj-x compose.yaml portal '{{' c1 http; do assert_not_contains "$p" "$v"; done
  # (milliseconds, and when each started: since the setup began, in order)
  printf '%s\n' "$p" | awk -F '\t' 'NF != 4 || $1 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $4 < last { bad = 1 } { last = $4 } END { exit bad }' ||
    { echo "a time that is not milliseconds, or out of order: $p" >&2; return 1; }
  [ "$(stat -c %a "$STATE_DIR/update/trace/calls.tsv" 2>/dev/null || stat -f %Lp "$STATE_DIR/update/trace/calls.tsv")" = 600 ] || { echo "profile not private" >&2; return 1; }
}

test_the_models_recheck_and_a_setup_without_begin_note_nothing() {
  _um_setup; UPD_RECORD=0; UPD_NOW=''
  upd_gate keys "keys" "w" true
  assert_eq "$UPD_NOW" ""
}

# The start: an update whose settings, keys and voice did not change starts the services with ONE compose up; otherwise the
# phases in their order (Postgres + RustFS, then LiteLLM). Compose's depends_on keeps Postgres before the LiteLLM migrations.
_um_bringup() { # _um_bringup [update] -> the calls setup_bringup_and_probe made
  _um_setup
  local en="$STACK_DIR/litellm/enabled-models.txt"
  ensure_prices_dir() { :; }; setup_build_images() { :; }; _setup_prices() { :; }; render_config() { echo RENDER >> "$TMP/calls"; }
  _setup_downloads() { :; }; _setup_owui_image() { :; }; _setup_websearch_render() { :; }; ensure_portal_reachable() { :; }
  probe_reusable() { echo "1 min"; }; ensure_virtual_key() { echo "KEY $2" >> "$TMP/calls"; }
  run_phase() { echo "PHASE $1" >> "$TMP/calls"; "${@:3}" > /dev/null 2>&1 || true; }
  up_front() { echo "UP $*" >> "$TMP/calls"; }; up_services() { echo "UPSVC $*" >> "$TMP/calls"; }; _up_data_services() { echo DATA >> "$TMP/calls"; }
  websearch_builtin_on() { return 1; }; localgit_on() { return 1; }
  _GATES="$_GATES setupkey"; _um_run > /dev/null   # (a setup that ran every step: the digests the update compares with; the stubs are part of them)
  [ -z "${2:-}" ] || printf '%s\n' "$2" >> "$ENV_FILE"
  : > "$TMP/calls"; : > "$TMP/ran"
  upd_begin; UPD_MODE=0; [ "${1:-}" != update ] || { UPD_MODE=1; UPD_SETTINGS_SKIPPED=1; }
  setup_bringup_and_probe 2> "$TMP/err"; : "$en"
  tr '\n' ';' < "$TMP/calls"
}
test_an_update_with_nothing_changed_starts_the_services_with_one_compose_up() {
  out="$(_um_bringup update)"
  assert_contains "$out" "UP postgres rustfs litellm open-webui shared-mcp portal caddy;"
  assert_eq "$(printf '%s' "$out" | grep -o 'UP ' | wc -l | tr -d ' ')" "1"
  assert_not_contains "$out" "PHASE Postgres + RustFS"
  assert_not_contains "$out" "UPSVC"
  assert_not_contains "$out" "RENDER"                     # the config was not rendered again either
  assert_not_contains "$out" "KEY setup"                  # nor the setup key checked
  assert_contains "$(cat "$TMP/err")" "LiteLLM setup key: not run"
}
test_setup_by_itself_and_an_update_with_a_changed_key_start_the_services_in_phases() {
  out="$(_um_bringup)"
  assert_contains "$out" "PHASE Postgres + RustFS"; assert_not_contains "$out" "UP postgres"
  # a changed budget (the keys' inputs): the phases, so the key is made before Open WebUI starts with it
  out="$(_um_bringup update BUDGET_SETUP=9)"
  assert_not_contains "$out" "UP postgres"
}
