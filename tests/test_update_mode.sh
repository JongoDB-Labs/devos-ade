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
  CODE_CTR=''; FORGEJO_CTR=f1
  dc() { case "$*" in "ps -q litellm open-webui") printf 'c1\nc2\n' ;; "ps -q code terminal") [ -z "$CODE_CTR" ] || printf '%s\n' $CODE_CTR ;; "ps -q forgejo") printf '%s\n' "$FORGEJO_CTR" ;; esac; return 0; }
  PGDATA_AT=2026-10-01T09:00:00Z
  docker() { case "$1 $2" in "inspect --format") printf '%s\n%s\n' "$LITELLM_CTR" "$OWUI_CTR" ;; "volume inspect") echo "$PGDATA_AT" ;; *) echo "unexpected docker $*" >&2; return 1 ;; esac; }
  snapshot_refs() { [ -z "$PORTAL_ID" ] || printf '%s\t%s\n' "$PORTAL_ID" "$(project_name)/portal:local"; }
  # the sources the Prices and Git server account steps read (JON-972): the updater and what it imports, the image's recipe,
  # the catalog files the container reads, the code container's importer; and a file of the portal neither reads
  mkdir -p "$STACK_DIR/portal/portal/static" "$STACK_DIR/code/server"
  for f in portal/Dockerfile portal/requirements.txt portal/portal/__init__.py portal/portal/prices.py portal/portal/brand.py \
    portal/portal/static/settings.js code/server/import-host.mjs catalog/models.tsv catalog/aws-price-map.tsv; do echo "v1 $f" > "$STACK_DIR/$f"; done
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
  # the portal image rebuilt: the sign-in (it logs in to the portal). Not the prices or the git account: they read only
  # the updater's sources and the code container (test_the_prices_and_git_account_steps_follow_only_what_they_read)
  PORTAL_ID=P2; assert_eq "$(_um_run update)" "signin"
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
  # a setting in .env: every step that reads .env, not the prices (which read only the region and PRICE_UPDATES)
  sed -i.bak 's/^LITELLM_PORT=4000/LITELLM_PORT=4001/' "$ENV_FILE"
  assert_eq "$(_um_run update)" "settings litellm_config voice stt_service keys searxng websearch gitserver codedefault gitafter signin syncs smoke"
  # the step's own code (a release that changes it)
  upd_in_voice_before="$(declare -f stt_after_probe 2>/dev/null)"; stt_after_probe() { echo changed; }
  assert_contains "$(_um_run update)" "voice"
}

# JON-972: Prices runs the updater (portal/portal/prices.py, which imports brand.py) in a throwaway portal container and reads
# the catalog's models.tsv, prices.tsv and aws-price-map.tsv from a mount; the Git server account runs the forgejo CLI and
# the code container's server/import-host.mjs. Neither reads the rest of the portal image (a Settings page's script).
test_the_prices_and_git_account_steps_follow_only_what_they_read() {
  _um_setup; _um_run > /dev/null
  echo "v2" >> "$STACK_DIR/portal/portal/static/settings.js"; PORTAL_ID=P2
  assert_eq "$(_um_run update)" "signin"                            # an unrelated portal file, or the image's ID: neither step
  local f
  for f in portal/portal/prices.py portal/portal/brand.py portal/portal/__init__.py portal/requirements.txt portal/Dockerfile \
    catalog/models.tsv catalog/aws-price-map.tsv; do
    echo "changed" >> "$STACK_DIR/$f"; assert_eq "$(_um_run update)" "prices"; assert_eq "$(_um_run update)" ""
  done
  # the region: the updater's catalog digest and the AWS prices it asks for depend on it
  sed -i.bak 's/us-east-1/eu-west-1/' "$ENV_FILE"; assert_contains "$(_um_run update)" "prices"; assert_eq "$(_um_run update)" ""
  # PRICE_UPDATES on to off
  printf 'PRICE_UPDATES=false\n' >> "$ENV_FILE"; assert_contains "$(_um_run update)" "prices"; assert_eq "$(_um_run update)" ""
  # the git account's own safety net (a restored backup, a new git container, a lost search token, a new or switched-on Code page)
  printf 'LOCALGIT_READ_TOKEN=tok-1\n' >> "$ENV_FILE"; assert_eq "$(_um_run update)" "gitafter"; assert_eq "$(_um_run update)" ""
  sed -i.bak 's/^LOCALGIT_READ_TOKEN=.*/LOCALGIT_READ_TOKEN=/' "$ENV_FILE"; assert_eq "$(_um_run update)" "gitafter"; assert_eq "$(_um_run update)" ""
  FORGEJO_CTR=f2; assert_eq "$(_um_run update)" "gitafter"; assert_eq "$(_um_run update)" ""
  CODE_CTR="k1 t1"; assert_eq "$(_um_run update)" "gitafter"; assert_eq "$(_um_run update)" ""   # the Code page switched on
  CODE_CTR="k2 t1"; assert_eq "$(_um_run update)" "gitafter"; assert_eq "$(_um_run update)" ""   # a new code container
  CODE_CTR=''; assert_eq "$(_um_run update)" "gitafter"; assert_eq "$(_um_run update)" ""        # switched off
  # the catalog's prices as the container reads them (catalog/prices.tsv), whatever PRICES_CATALOG says
  PRICES_CATALOG="$TMP/other-prices.tsv"; cp "$STACK_DIR/catalog/prices.tsv" "$PRICES_CATALOG"; _um_run update >/dev/null
  echo "# changed" >> "$STACK_DIR/catalog/prices.tsv"; assert_contains "$(_um_run update)" "prices"; assert_eq "$(_um_run update)" ""
  echo "changed" >> "$STACK_DIR/code/server/import-host.mjs"; assert_eq "$(_um_run update)" "gitafter"
  # the portal image gone (pruned): the updater has nothing to run in
  PORTAL_ID=''; assert_eq "$(_um_run update)" "prices signin"
  PORTAL_ID=P3; assert_eq "$(_um_run update)" "prices signin"
  assert_eq "$(_um_run update)" ""
}

# The git server's search token (JON-979) is written by the git account step, after the steps before it kept .env: as an
# input of theirs it ran each of them again on the next update (jfast10: settings, keys, sign-in and syncs, and the services
# then started in phases). The account step makes it again when the server refuses it, and recreates the portal itself.
test_the_git_search_token_setup_writes_late_runs_no_step_again() {
  _um_setup; _um_run > /dev/null
  # (only the git account step reads whether there is one, not which: a token made again is no input)
  printf 'LOCALGIT_READ_TOKEN=tok-1\n' >> "$ENV_FILE"; assert_eq "$(_um_run update)" "gitafter"
  sed -i.bak 's/^LOCALGIT_READ_TOKEN=.*/LOCALGIT_READ_TOKEN=tok-2/' "$ENV_FILE"; assert_eq "$(_um_run update)" ""
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

# The AWS key check (2 s: a container asks AWS who the key is): again for another key, secret, region or shell key, and at
# least once a day; its time is the one it last passed
test_the_aws_key_check_runs_for_another_key_or_region_and_once_a_day() {
  _um_setup
  printf 'AWS_ACCESS_KEY_ID=AKIA-T\nAWS_SECRET_ACCESS_KEY=s1\n' >> "$ENV_FILE"
  setup_aws_creds() { echo aws >> "$TMP/ran"; }
  local rs
  _aws_run() { : > "$TMP/ran"; upd_begin; UPD_MODE="${1:-1}"; upd_gate aws "AWS key check" "why" _setup_aws_check >/dev/null; upd_commit; tr -d '\n' < "$TMP/ran"; }
  assert_eq "$(_aws_run 0)" aws; assert_eq "$(_aws_run)" ""; assert_eq "$(_aws_run)" ""
  assert_not_contains "$(cat "$STATE_DIR/update/step-inputs.tsv")" "s1"
  sed -i.bak 's/^AWS_SECRET_ACCESS_KEY=.*/AWS_SECRET_ACCESS_KEY=s2/' "$ENV_FILE"; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  sed -i.bak 's/us-east-1/eu-west-1/' "$ENV_FILE"; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  export AWS_ACCESS_KEY_ID=AKIA-SHELL; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  unset AWS_ACCESS_KEY_ID; assert_eq "$(_aws_run)" aws
  # a day after the check passed: again (and a check that failed leaves its time as it was)
  touch -t 202601010000 "$STATE_DIR/update/aws-checked"; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  touch -t 202601010000 "$STATE_DIR/update/aws-checked"
  setup_aws_creds() { echo aws >> "$TMP/ran"; return 1; }
  _aws_run >/dev/null || true; rs="$(find "$STATE_DIR/update/aws-checked" -mmin -1440)"; assert_eq "$rs" ""
  # setup gates it
  assert_contains "$(sed -n '/^cmd_setup() {/,/^}/p' "$T_ROOT/lib/commands.sh")" 'upd_gate aws "AWS key check"'
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

test_the_call_profile_times_each_digest_by_its_step_and_role_and_keeps_no_input() {
  _um_setup
  upd_begin; UPD_MODE=1
  upd_gate keys "step keys" "why" true   # (no profile: no file)
  [ ! -e "$STATE_DIR/update/trace/calls.tsv" ] || { echo "a profile without the switch" >&2; return 1; }
  mkdir -p "$STATE_DIR/update"; : > "$STATE_DIR/update/trace-on"
  upd_begin; UPD_MODE=1; UPD_PREV="$(printf 'keys\tx\n')"
  upd_gate keys "step keys" "why" true   # (compared before, noted after it ran: two digests)
  p="$(cat "$STATE_DIR/update/trace/calls.tsv")"
  assert_contains "$p" "	digest	keys<same	"; assert_contains "$p" "	digest	keys<note	"
  assert_eq "$(printf '%s\n' "$p" | grep -c '	digest	')" "2"
  for v in sk-a sk-b LITELLM_KEY 4000 us-east-1; do assert_not_contains "$p" "$v"; done
  printf '%s\n' "$p" | awk -F '\t' 'NF != 4 || $1 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' ||
    { echo "a digest line that is not MS digest NAME<ROLE START: $p" >&2; return 1; }
}

test_the_digest_helpers_read_files_folders_and_keys_in_one_go_with_the_lines_of_one_call_each() {
  _um_setup
  local d="$TMP/in"; mkdir -p "$d/sp ace" "$d/empty"; echo a > "$d/sp ace/f 1"; echo bb > "$d/sp ace/.h"; echo c > "$d/u"; chmod 000 "$d/u"
  local a; a="$(cksum < "$d/sp ace/f 1" | awk '{ print $1 "-" $2 }')"
  # (in the order given, again for a name given twice; "-" for one that is not there; nothing for one that cannot be read)
  assert_eq "$(_upd_files "$d/sp ace/f 1" "$d/nope" "$d/u" "$d/sp ace/f 1")" "$(printf '%s %s\n%s -\n%s \n%s %s' "$d/sp ace/f 1" "$a" "$d/nope" "$d/u" "$d/sp ace/f 1" "$a")"
  assert_eq "$(_upd_files)" ""
  assert_eq "$(_upd_tree "$d/sp ace" "$d/empty" "$d/nope")" "$(printf './.h %s\n./f 1 %s\n%s -' "$(cksum < "$d/sp ace/.h" | awk '{ print $1 "-" $2 }')" "$a" "$d/nope")"
  chmod 600 "$d/u"
  # (the keys as get_env reads them: the last line of a name; none without a .env)
  printf 'LITELLM_KEY_SETUP=a\nLITELLM_KEY_SETUP=b=c d\nXLITELLM_KEY_OPENWEBUI=no\n' > "$ENV_FILE"
  assert_eq "$(_upd_keys)" "$(printf 'LITELLM_KEY_CLAUDE_CODE=\nLITELLM_KEY_OPENWEBUI=\nLITELLM_KEY_SETUP=b=c d\nOPENWEBUI_API_KEY=\nLITELLM_DB_ADMIN_READY=')"
  rm -f "$ENV_FILE"
  assert_eq "$(_upd_keys)" "$(printf 'LITELLM_KEY_CLAUDE_CODE=\nLITELLM_KEY_OPENWEBUI=\nLITELLM_KEY_SETUP=\nOPENWEBUI_API_KEY=\nLITELLM_DB_ADMIN_READY=')"
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
  [ -n "${UM_PROBE_AGE:-}" ] || probe_reusable() { echo "1 min"; }
  _setup_model_check() { echo PROBE >> "$TMP/calls"; }; on_exit() { :; }; timed_step() { shift; "$@"; }
  ensure_virtual_key() { echo "KEY $2" >> "$TMP/calls"; }
  run_phase() { echo "PHASE $1" >> "$TMP/calls"; "${@:3}" > /dev/null 2>&1 || true; }
  up_front() { echo "UP $*" >> "$TMP/calls"; }; up_services() { echo "UPSVC $*" >> "$TMP/calls"; }; _up_data_services() { echo DATA >> "$TMP/calls"; }
  websearch_builtin_on() { return 1; }; localgit_on() { return 1; }
  _GATES="$_GATES setupkey"; _um_run > /dev/null   # (a setup that ran every step: the digests the update compares with; the stubs are part of them)
  [ -z "${2:-}" ] || printf '%s\n' "$2" >> "$ENV_FILE"
  : > "$TMP/calls"; : > "$TMP/ran"
  upd_begin; UPD_MODE=0; [ "${1:-}" != update ] || { UPD_MODE=1; UPD_SETTINGS_SKIPPED=1; }
  # (UM_PROBE_AGE: the real probe_reusable, over a mark written that many seconds ago with today's fingerprint)
  if [ -n "${UM_PROBE_AGE:-}" ]; then
    probe_mark; printf 'fingerprint=%s\nat=%s\n' "$(sed -n 's/^fingerprint=//p' "$(probe_mark_file)")" "$(( $(date +%s) - UM_PROBE_AGE ))" > "$(probe_mark_file)"
    [ -z "${UM_NO_RESULTS:-}" ] || rm -f "$STACK_DIR/litellm/probe-results.tsv"
    [ -z "${UM_PROBE_CHANGE:-}" ] || printf 'AWS_REGION_NAME=eu-west-1\n' >> "$ENV_FILE"
  fi
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

# JON-972: an update keeps a model check whose fingerprint holds at any age; setup and --recheck still ask the age limit / probe
test_an_update_keeps_a_model_check_older_than_a_week_and_says_so() {
  out="$(UM_PROBE_AGE=$((9 * 86400)) _um_bringup update)"
  assert_not_contains "$out" "PROBE"
  assert_not_contains "$out" "PHASE LiteLLM (full catalog"
  assert_not_contains "$out" "UPSVC"
  assert_contains "$(cat "$TMP/err")" "Model check kept from"
  assert_contains "$(cat "$TMP/err")" "Settings › Models your key can use › Re-check models, or ./stack models --recheck"
}
test_an_update_keeping_a_young_model_check_prints_no_old_check_line() {
  out="$(UM_PROBE_AGE=3600 _um_bringup update)"
  assert_not_contains "$out" "PROBE"
  assert_not_contains "$(cat "$TMP/err")" "Model check kept from"
}
test_setup_outside_update_mode_does_not_keep_a_model_check_older_than_a_week() {
  out="$(UM_PROBE_AGE=$((9 * 86400)) _um_bringup)"
  assert_contains "$out" "PROBE"
  assert_not_contains "$(cat "$TMP/err")" "Model check kept from"
}
test_an_update_with_a_changed_fingerprint_still_runs_the_model_check() {
  out="$(UM_PROBE_AGE=$((9 * 86400)) UM_PROBE_CHANGE=1 _um_bringup update)"
  assert_contains "$out" "PROBE"
}
test_models_recheck_runs_the_model_check_in_update_mode() {
  out="$(UM_PROBE_AGE=3600 SETUP_REPROBE=1 _um_bringup update)"
  assert_contains "$out" "PROBE"
}
test_an_update_with_a_model_check_older_than_thirty_days_runs_it_again() {
  out="$(UM_PROBE_AGE=$((31 * 86400)) _um_bringup update)"
  assert_contains "$out" "PROBE"
  out="$(UM_PROBE_AGE=$((29 * 86400)) _um_bringup update)"
  assert_not_contains "$out" "PROBE"
}
test_an_update_without_the_results_files_runs_the_model_check() {
  out="$(UM_PROBE_AGE=3600 UM_NO_RESULTS=1 _um_bringup update)"
  assert_contains "$out" "PROBE"
}
