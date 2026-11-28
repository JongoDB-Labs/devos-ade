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
  # (a shell key id alone is not one setup takes: both are needed, _env_aws_creds_chosen)
  export AWS_ACCESS_KEY_ID=AKIA-SHELL; assert_eq "$(_aws_run)" ""
  export AWS_SECRET_ACCESS_KEY=s-shell; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; assert_eq "$(_aws_run)" aws
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

test_the_call_profile_goes_to_the_file_it_is_given() {
  # (./stack update's own steps: a file of their own, beside the setup's, which stays as it was)
  _um_setup
  local f="$STATE_DIR/update/job-trace/calls-old.tsv" p
  curl() { return 0; }
  upd_prof_begin "$f"
  [ ! -e "$f" ] || { echo "a profile without the switch" >&2; return 1; }
  mkdir -p "$STATE_DIR/update"; : > "$STATE_DIR/update/trace-on"
  upd_prof_begin "$f"
  curl -H "Authorization: Bearer sk-secret" http://x/
  phase_start "Backup"; phase_line "Backup" 1 > /dev/null
  p="$(cat "$f")"
  assert_contains "$p" "	curl	"; assert_contains "$p" "0	step	begin Backup	"; assert_contains "$p" "0	step	end Backup	"
  assert_not_contains "$p" "sk-secret"
  [ ! -e "$STATE_DIR/update/trace/calls.tsv" ] || { echo "the setup's file was written too" >&2; return 1; }
  [ "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" = 600 ] || { echo "profile not private" >&2; return 1; }
  [ "$(stat -c %a "${f%/*}" 2>/dev/null || stat -f %Lp "${f%/*}")" = 700 ] || { echo "its folder not private" >&2; return 1; }
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

test_the_shell_profile_needs_its_switch_the_trace_and_bash_5() {
  _um_setup
  mkdir -p "$STATE_DIR/update"
  # (the switch without the trace, or the trace without the switch: no DEBUG trap, no profile)
  : > "$STATE_DIR/update/profile-on"; upd_begin
  assert_eq "$(trap -p DEBUG)" ""; upd_commit; [ ! -e "$STATE_DIR/update/trace/profile.tsv" ] || { echo "a profile without the trace" >&2; return 1; }
  rm -f "$STATE_DIR/update/profile-on"; : > "$STATE_DIR/update/trace-on"; upd_begin
  assert_eq "$(trap -p DEBUG)" ""; upd_commit; [ ! -e "$STATE_DIR/update/trace/profile.tsv" ] || { echo "a profile without the switch" >&2; return 1; }
  # (both, on a bash without EPOCHREALTIME — macOS's 3.2: none)
  if [ -z "${EPOCHREALTIME:-}" ]; then
    : > "$STATE_DIR/update/profile-on"; upd_begin
    assert_eq "$(trap -p DEBUG)" ""; upd_commit; [ ! -e "$STATE_DIR/update/trace/profile.tsv" ] || { echo "a profile on bash ${BASH_VERSION}" >&2; return 1; }
  fi
  case $- in *T*) echo "set -T left on" >&2; return 1 ;; esac
}

test_the_shell_profile_times_each_line_and_keeps_no_text() {
  [ -n "${EPOCHREALTIME:-}" ] || { echo "bash ${BASH_VERSION%%(*}: no EPOCHREALTIME" >&2; return 77; }
  _um_setup
  mkdir -p "$STATE_DIR/update"; : > "$STATE_DIR/update/trace-on"; : > "$STATE_DIR/update/profile-on"
  um_slow() { local secret="sk-profile-secret"; command sleep 0.3; [ -n "$secret" ]; }
  um_sub() { local v; v="$(command sleep 0.2; echo x)"; [ "$v" = x ]; }
  upd_begin
  [ -n "$(trap -p DEBUG)" ] || { echo "no DEBUG trap" >&2; return 1; }
  [ ! -e "$STATE_DIR/update/profile-on" ] || { echo "the switch was not used up" >&2; return 1; }
  um_slow; um_sub
  # ($? of the command before is kept; || works as without it)
  local rc=0; false || rc=$?; assert_eq "$rc" 1
  rc=0; (exit 3) || rc=$?; assert_eq "$rc" 3
  upd_commit
  assert_eq "$(trap -p DEBUG)" ""; case $- in *T*) echo "set -T left on" >&2; return 1 ;; esac
  [ ! -e "$STATE_DIR/update/trace/profile.raw" ] || { echo "the raw records were kept after a success" >&2; return 1; }
  local p; p="$(cat "$STATE_DIR/update/trace/profile.tsv")"
  # (MS COUNT DEPTH FUNCTION@FILE:LINE, biggest first; the sleep in um_slow on its line; um_sub's subshell on the line
  # that started it, and the sleep inside it at depth 1)
  printf '%s\n' "$p" | awk -F '\t' 'NF != 4 || $1 !~ /^-?[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[A-Za-z_][A-Za-z0-9_]*@[^:]*:[0-9]+$/ { bad = 1 }
    NR > 1 && $1 > last { bad = 1 } { last = $1 } END { exit bad }' || { echo "not MS COUNT DEPTH FUNCTION@FILE:LINE, biggest first: $p" >&2; return 1; }
  [ "$(printf '%s\n' "$p" | awk -F '\t' '$3 == 0 && $4 ~ /^um_slow@/ { s += $1 } END { print (s >= 250) }')" = 1 ] || { echo "um_slow's sleep not there: $p" >&2; return 1; }
  [ "$(printf '%s\n' "$p" | awk -F '\t' '$3 == 0 && $4 ~ /^um_sub@/ { s += $1 } END { print (s >= 150) }')" = 1 ] || { echo "um_sub's subshell not on its line: $p" >&2; return 1; }
  [ "$(printf '%s\n' "$p" | awk -F '\t' '$3 >= 1 && $4 ~ /^um_sub@/ { s += $1 } END { print (s >= 150) }')" = 1 ] || { echo "the sleep inside um_sub's subshell not there: $p" >&2; return 1; }
  for v in sk-profile-secret sleep secret '$('; do assert_not_contains "$p" "$v"; done
  [ "$(stat -c %a "$STATE_DIR/update/trace/profile.tsv" 2>/dev/null || stat -f %Lp "$STATE_DIR/update/trace/profile.tsv")" = 600 ] || { echo "profile not private" >&2; return 1; }
}

test_the_shell_profile_ends_with_a_second_begin_and_leaves_errexit_and_nounset_as_they_were() {
  [ -n "${EPOCHREALTIME:-}" ] || { echo "bash ${BASH_VERSION%%(*}: no EPOCHREALTIME" >&2; return 77; }
  _um_setup
  mkdir -p "$STATE_DIR/update"; : > "$STATE_DIR/update/trace-on"; : > "$STATE_DIR/update/profile-on"
  # (a second begin without the switch — used up by the first: no trap left, and its commit writes no profile)
  upd_begin; [ -n "$(trap -p DEBUG)" ] || { echo "no DEBUG trap" >&2; return 1; }
  upd_begin; assert_eq "$(trap -p DEBUG)" ""; case $- in *T*) echo "set -T left on" >&2; return 1 ;; esac
  upd_commit; [ ! -e "$STATE_DIR/update/trace/profile.tsv" ] || { echo "a profile from a begin without the switch" >&2; return 1; }
  # (the stack's own options: set -euo pipefail, at the top level and in functions, through $( ), a pipe, || and if; and
  # the trace folder gone halfway, so each write fails)
  # (set +e here, set -e inside: the left of a || would turn errexit off inside too, and test nothing)
  : > "$STATE_DIR/update/profile-on"
  local out rc
  set +e
  out="$(set -euo pipefail
    um_f() { local v; v="$(false || echo z)"; [ "$v" = z ]; printf 'a\nb\n' | grep -c b > /dev/null; if false; then :; fi; }
    upd_begin; um_f; false || true; x="$(exit 0)"; um_f
    rm -rf "$STATE_DIR/update/trace"; um_f
    upd_commit; echo "survived $x"; trap -p DEBUG)"; rc=$?
  set -e
  assert_eq "$rc" 0; assert_eq "$out" "survived "
  # (and errexit still ends it at a failure of its own, in a function too)
  set +e
  ( set -euo pipefail; : > "$STATE_DIR/update/profile-on"; mkdir -p "$STATE_DIR/update/trace"; upd_begin
    um_g() { false; echo "not here"; }; um_g; echo "nor here" ) > "$TMP/o" 2>&1; rc=$?
  set -e
  assert_eq "$rc" 1; assert_not_contains "$(cat "$TMP/o")" "here"
}

test_the_digest_helpers_read_files_folders_and_keys_in_one_go_with_the_lines_of_one_call_each() {
  _um_setup
  local d="$TMP/in" a rc u=1; mkdir -p "$d/sp ace" "$d/empty"; echo a > "$d/sp ace/f 1"; echo bb > "$d/sp ace/.h"; echo c > "$d/u"; chmod 000 "$d/u"
  [ "$(id -u)" != 0 ] || u=0   # (root reads a file of mode 000: no unreadable file then)
  a="$(cksum < "$d/sp ace/f 1" | awk '{ print $1 "-" $2 }')"
  # (in the order given, again for a name given twice; "-" for one that is not there; nothing for one that cannot be read)
  if [ "$u" = 1 ]; then
    assert_eq "$(_upd_files "$d/sp ace/f 1" "$d/nope" "$d/u" "$d/sp ace/f 1")" "$(printf '%s %s\n%s -\n%s \n%s %s' "$d/sp ace/f 1" "$a" "$d/nope" "$d/u" "$d/sp ace/f 1" "$a")"
    rc=0; _upd_files "$d/u" > /dev/null || rc=$?; assert_eq "$rc" 0   # (status 0, as before, also then)
  fi
  assert_eq "$(_upd_files)" ""
  # (a name that starts with "-" is a name; one with a newline in it, and fewer sums than files, take one cksum each)
  mkdir -p "$d/dash"; ( cd "$d/dash" && cp "../sp ace/f 1" ./-f && assert_eq "$(_upd_files -f)" "-f $a" ) || return 1
  printf 'a\n' > "$d/dash/n
l"; assert_eq "$(_upd_files "$d/dash/n
l" "$d/sp ace/f 1")" "$(printf '%s %s\n%s %s' "$d/dash/n
l" "$a" "$d/sp ace/f 1" "$a")"
  cksum() { if [ $# -gt 0 ]; then command cksum "$@" | sed 1d; else command cksum; fi; }   # (a file gone meanwhile)
  assert_eq "$(_upd_files "$d/sp ace/f 1" "$d/sp ace/.h")" "$(printf '%s %s\n%s %s' "$d/sp ace/f 1" "$a" "$d/sp ace/.h" "$(command cksum < "$d/sp ace/.h" | awk '{ print $1 "-" $2 }')")"
  unset -f cksum
  assert_eq "$(_upd_tree "$d/sp ace" "$d/empty" "$d/nope")" "$(printf './.h %s\n./f 1 %s\n%s -' "$(cksum < "$d/sp ace/.h" | awk '{ print $1 "-" $2 }')" "$a" "$d/nope")"
  chmod 600 "$d/u"
  # (the keys as get_env reads them: the last line of a name; none without a .env)
  printf 'LITELLM_KEY_SETUP=a\nLITELLM_KEY_SETUP=b=c d\nXLITELLM_KEY_OPENWEBUI=no\n' > "$ENV_FILE"
  assert_eq "$(_upd_keys)" "$(printf 'LITELLM_KEY_CLAUDE_CODE=\nLITELLM_KEY_OPENWEBUI=\nLITELLM_KEY_SETUP=b=c d\nOPENWEBUI_API_KEY=\nLITELLM_DB_ADMIN_READY=')"
  if [ "$u" = 1 ]; then chmod 000 "$ENV_FILE"; assert_eq "$(_upd_keys)" "$(printf 'LITELLM_KEY_CLAUDE_CODE=\nLITELLM_KEY_OPENWEBUI=\nLITELLM_KEY_SETUP=\nOPENWEBUI_API_KEY=\nLITELLM_DB_ADMIN_READY=')"; chmod 600 "$ENV_FILE"; fi
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

# JON-1419: the Code page default (and the terminal's and the Code page's hooks after it) write these keys late in a new
# install's first setup, after the steps before them noted their digests. As an input of theirs, the first Update now ran each
# of them again (41 s instead of 26 s on the test host). The steps from the Code page default on are noted after the keys are
# written, and keep them as inputs.
_um_code_late_keys() {
  mkdir -p "$TMP/ws"
  printf 'CODE_ENABLED=true\nCODE_CHAT_KEY=ck\nCODE_PROXY_SECRET=cp\nPREVIEW_DOMAIN=p.localhost\nPREVIEW_PROXY_SECRET=pp\nTERMINAL_ENABLED=true\nTERMINAL_GID=20\nTERMINAL_PROXY_SECRET=tp\nTERMINAL_UID=501\nTERMINAL_WORKSPACE=%s\nLITELLM_KEY_TERMINAL=sk-t\n' "$TMP/ws" >> "$ENV_FILE"
}
# a first setup: every gate runs; the Code page default's writes the keys, as code_default_on and its hooks do
_um_first_setup_with_code_default() {
  local g; : > "$TMP/ran"; upd_begin; UPD_MODE=0
  localgit_tls_ensure   # (the git server step made its certificate: what localgit_start does)
  for g in $_GATES; do
    if [ "$g" = codedefault ]; then upd_gate "$g" "step $g" why _um_code_late_keys; else upd_gate "$g" "step $g" why sh -c "echo $g >> '$TMP/ran'"; fi
  done
  upd_commit
}
test_the_keys_the_code_page_default_writes_late_run_no_earlier_step_again() {
  _um_setup; _um_first_setup_with_code_default
  assert_contains "$(cat "$ENV_FILE")" "TERMINAL_ENABLED=true"
  assert_eq "$(_um_run update)" ""
  assert_eq "$(_um_run update)" ""
}
test_a_key_an_early_step_reads_still_runs_it_after_the_code_page_default() {
  _um_setup; _um_first_setup_with_code_default; _um_run update >/dev/null
  # a key the steps before it do read, one of the keys that are not written late
  printf 'TERMINAL_EGRESS=off\n' >> "$ENV_FILE"
  assert_eq "$(_um_run update)" "settings litellm_config voice stt_service keys searxng websearch gitserver codedefault gitafter signin syncs smoke"
  # a key it reads, as setup's settings step does
  sed -i.bak 's/^LITELLM_PORT=4000/LITELLM_PORT=4001/' "$ENV_FILE"
  assert_eq "$(_um_run update)" "settings litellm_config voice stt_service keys searxng websearch gitserver codedefault gitafter signin syncs smoke"
  # the services' own files (a compose file of the terminal, a pinned image): the steps that start a service of their own
  echo "# changed" >> "$STACK_DIR/compose.yaml"
  assert_eq "$(_um_run update)" "stt_service keys searxng gitserver gitafter smoke"
  printf 'x: 1\n' > "$STACK_DIR/compose.terminal.yaml"; _um_run update >/dev/null
  echo "# changed" >> "$STACK_DIR/compose.terminal.yaml"
  assert_eq "$(_um_run update)" "stt_service keys searxng gitserver gitafter smoke"
}
# the steps from the Code page default on read the keys: a Code page or terminal turned off or on, a new secret
test_a_change_of_the_code_page_keys_runs_the_code_page_default_step_and_the_ones_after_it() {
  _um_setup; _um_first_setup_with_code_default; _um_run update >/dev/null
  local k
  for k in CODE_ENABLED TERMINAL_ENABLED CODE_PROXY_SECRET CODE_CHAT_KEY PREVIEW_PROXY_SECRET TERMINAL_PROXY_SECRET TERMINAL_UID TERMINAL_GID; do
    sed -i.bak "s/^$k=.*/$k=changed-$k/" "$ENV_FILE"
    assert_eq "$(_um_run update)" "codedefault gitafter smoke"; assert_eq "$(_um_run update)" ""
  done
}

# JON-1480: a new install's setup runs in a terminal (AWS_* in the shell), the first Update now in the update helper (none).
# The shell's keys are an input only when setup would use something other than what .env holds: keys that differ from .env's,
# a session token with them, or a region that differs.
test_the_aws_check_ignores_shell_keys_equal_to_envs_and_follows_any_other() {
  _um_setup
  printf 'AWS_ACCESS_KEY_ID=AKIA-T\nAWS_SECRET_ACCESS_KEY=s1\n' >> "$ENV_FILE"
  setup_aws_creds() { echo aws >> "$TMP/ran"; }
  _aws_run() { : > "$TMP/ran"; upd_begin; UPD_MODE="${1:-1}"; upd_gate aws "AWS key check" "why" _setup_aws_check >/dev/null; upd_commit; tr -d '\n' < "$TMP/ran"; }
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION_NAME AWS_REGION
  # setup in a terminal whose keys and region are .env's own; the update helper has none
  export AWS_ACCESS_KEY_ID=AKIA-T AWS_SECRET_ACCESS_KEY=s1 AWS_REGION_NAME=us-east-1
  assert_eq "$(_aws_run 0)" aws
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION_NAME
  assert_eq "$(_aws_run)" ""
  # the region only in AWS_REGION, the same as .env's
  export AWS_REGION=us-east-1; assert_eq "$(_aws_run)" ""; unset AWS_REGION
  # a different key or secret: setup would take it, so the check runs; and once with it noted, without it again
  export AWS_ACCESS_KEY_ID=AKIA-NEW AWS_SECRET_ACCESS_KEY=s1; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  export AWS_ACCESS_KEY_ID=AKIA-T AWS_SECRET_ACCESS_KEY=s9; assert_eq "$(_aws_run)" aws
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  # the same keys with a session token (setup refuses temporary keys), and a different region
  export AWS_ACCESS_KEY_ID=AKIA-T AWS_SECRET_ACCESS_KEY=s1 AWS_SESSION_TOKEN=tok; assert_eq "$(_aws_run)" aws
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  export AWS_REGION_NAME=eu-west-1; assert_eq "$(_aws_run)" aws
  unset AWS_REGION_NAME; assert_eq "$(_aws_run)" aws; assert_eq "$(_aws_run)" ""
  export AWS_REGION=eu-west-1; assert_eq "$(_aws_run)" aws
  unset AWS_REGION; assert_eq "$(_aws_run)" aws
  assert_not_contains "$(cat "$STATE_DIR/update/step-inputs.tsv")" "s9"
}

# JON-1480: the keys the steps after them write (LiteLLM's keys and admin mark by the keys step; Chat's API key by the sign-in
# step) are inputs of the steps before only when those steps read them. Setup's own order is used here.
_um_new_install_gates() { _GATES="settings voice searxng websearch gitserver keys stt_service codedefault gitafter signin syncs smoke"; }
_um_new_install_setup() {   # a first setup: .env has none of the late keys until the step that writes them has run
  _um_setup; _um_new_install_gates
  sed -i.bak '/^LITELLM_KEY_CLAUDE_CODE=/d;/^LITELLM_KEY_OPENWEBUI=/d;/^OPENWEBUI_API_KEY=/d;/^LITELLM_DB_ADMIN_READY=/d' "$ENV_FILE"
  _um_writes_keys() { printf 'LITELLM_KEY_CLAUDE_CODE=sk-b\nLITELLM_KEY_OPENWEBUI=sk-c\nLITELLM_DB_ADMIN_READY=true\n' >> "$ENV_FILE"; }
  _um_writes_owui_key() { printf 'OPENWEBUI_API_KEY=sk-d\n' >> "$ENV_FILE"; }
  local g; upd_begin; UPD_MODE=0; : > "$TMP/ran"
  for g in $_GATES; do
    case "$g" in
      keys) upd_gate "$g" "step $g" why _um_writes_keys ;;
      signin) upd_gate "$g" "step $g" why _um_writes_owui_key ;;
      *) upd_gate "$g" "step $g" why sh -c "echo $g >> '$TMP/ran'" ;;
    esac
  done
  upd_commit
}
test_the_keys_the_keys_and_sign_in_steps_write_run_no_earlier_step_again() {
  _um_new_install_setup
  assert_eq "$(_um_run update)" ""
  assert_eq "$(_um_run update)" ""
}
test_a_key_a_step_reads_still_runs_it() {
  _um_new_install_setup; _um_run update >/dev/null
  # Chat's API key: the sign-in, the syncs and the smoke test use it; the keys step and the search check do not
  sed -i.bak 's/^OPENWEBUI_API_KEY=.*/OPENWEBUI_API_KEY=sk-new/' "$ENV_FILE"; assert_eq "$(_um_run update)" "signin syncs smoke"; assert_eq "$(_um_run update)" ""
  # LiteLLM's keys and admin mark: the keys step reads them, and Open WebUI's sign-in, syncs and the smoke test; not the search
  local k
  for k in LITELLM_KEY_CLAUDE_CODE LITELLM_KEY_OPENWEBUI LITELLM_DB_ADMIN_READY; do
    sed -i.bak "s/^$k=.*/$k=changed-$k/" "$ENV_FILE"; assert_eq "$(_um_run update)" "keys signin syncs smoke"; assert_eq "$(_um_run update)" ""
  done
  # the search check's own key
  sed -i.bak 's/^LITELLM_KEY_SETUP=.*/LITELLM_KEY_SETUP=sk-new/' "$ENV_FILE"; assert_eq "$(_um_run update)" "websearch keys signin syncs smoke"
}
