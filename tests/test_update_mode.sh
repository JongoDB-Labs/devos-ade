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
  LITELLM_CTR="/p-litellm-1 L1 2026-11-01T10:00:00Z"; OWUI_CTR="/p-open-webui-1 O1 2026-11-01T10:00:00Z"; PORTAL_ID=P1
  dc() { case "$*" in "ps -q litellm open-webui") printf 'c1\nc2\n' ;; esac; return 0; }
  docker() { case "$1 $2" in "inspect --format") printf '%s\n%s\n' "$LITELLM_CTR" "$OWUI_CTR" ;; *) echo "unexpected docker $*" >&2; return 1 ;; esac; }
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

test_the_models_recheck_and_a_setup_without_begin_note_nothing() {
  _um_setup; UPD_RECORD=0; UPD_NOW=''
  upd_gate keys "keys" "w" true
  assert_eq "$UPD_NOW" ""
}
