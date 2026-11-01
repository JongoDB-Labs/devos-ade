# shellcheck shell=bash
# The slow parts of ./stack update and setup, side by side and each timed (Home's update card shows every step with its
# time: lib/helper.sh _job_steps). Sourced by lib/commands.sh.
#
#   Image downloads  ./stack update starts them before setup (pulls_start): every image at once, each its own
#                    `docker pull`; an image pinned by its digest that is here already is not asked for again. Setup
#                    builds meanwhile and waits for them (pulls_wait) before it starts anything with them.
#   Image builds     each build's BuildKit output is read for when each image was ready, and whether it came from
#                    Docker's cache or what was built again (build_report): "Image terminal (rebuilt from RUN apt-get …)".
#   The sandboxes    the terminal's, its egress proxy's and the Code page's images build in the background
#                    (sandbox_build_start), while LiteLLM, Open WebUI and the portal come up; the terminal's step waits
#                    for them (sandbox_build_wait).

# --- image downloads ---

# image_short REF -> the image's name for people: litellm:1.105.0 (no registry, no digest)
image_short() { local r="${1%%@*}"; printf '%s\n' "${r##*/}"; }

# pull_needed REF -> 0 unless REF is pinned by its digest (NAME@sha256:…) and that image is here already: a digest
# never moves, so there is nothing to ask the registry. A tag is asked again (a rebuilt image under the same tag is
# fetched; an unchanged one costs a look at its manifest).
pull_needed() {
  case "$1" in *@sha256:*) ! docker image inspect "$1" >/dev/null 2>&1 ;; *) return 0 ;; esac
}

# update_pull_refs -> the images compose would pull (dc config --images: every service .env turns on, with its
# overlays and profiles), once each; this install's own builds (<project>/NAME:local) are left out, as
# `dc pull --ignore-buildable` leaves them out
update_pull_refs() {
  local p img; p="$(project_name)"
  dc config --images 2>/dev/null | awk '!seen[$0]++' | while IFS= read -r img; do
    case "$img" in '' | "$p"/*:local) continue ;; esac
    printf '%s\n' "$img"
  done
}

pulls_dir() { printf '%s/update-pulls\n' "$STATE_DIR"; }

# pulls_start — the update's image downloads, all at once, in the background: N.ref (the image), N.log (its `docker pull`
# words), N.res ("REF<TAB>SECONDS<TAB>STATUS") when it ended, skipped (the ones pinned by digest that are here), pid
# (the process that runs them) and done once all ended. PULLS_DIR and PULLS_PID say where and which (setup gets them in
# its environment: DEVOS_ADE_PULLS_DIR, DEVOS_ADE_PULLS_PID). Fails only when the images cannot be listed.
PULLS_DIR=''; PULLS_PID=''
pulls_start() {
  local d ref refs here i=0
  d="$(pulls_dir)"
  rm -rf "$d"; mkdir -p "$d" || return 1
  refs="$(update_pull_refs)" || return 1
  [ -n "$refs" ] || return 1
  # (which of them are here: one docker call for all — snapshot_refs, lib/images.sh — not one for each digest-pinned image)
  here="$(printf '%s\n' "$refs" | snapshot_refs | cut -f2)"
  for ref in $refs; do
    case "$ref" in
      *@sha256:*) case "
$here
" in *"
$ref
"*) printf '%s\n' "$ref" >> "$d/skipped"; continue ;; esac ;;
    esac
    i=$((i + 1)); printf '%s\n' "$ref" > "$d/$i.ref"
  done
  # (no terminal and no lock of its own: this command's lock covers it, and setup waits for it)
  ( trap - EXIT
    for f in "$d"/*.ref; do
      [ -f "$f" ] || continue
      ( n="${f%.ref}"; r="$(cat "$f")"; s=$SECONDS; rc=0
        docker pull "$r" > "$n.log" 2>&1 || rc=$?
        printf '%s\t%s\t%s\n' "$r" $((SECONDS - s)) "$rc" > "$n.res" ) &
    done
    wait
    : > "$d/done" ) </dev/null >/dev/null 2>&1 &
  PULLS_PID=$!
  # shellcheck disable=SC2034  # (read by lib/commands.sh cmd_update)
  PULLS_DIR="$d"
  printf '%s\n' "$PULLS_PID" > "$d/pid"
  log "downloading $i image(s) side by side while setup builds$([ ! -s "$d/skipped" ] || printf ' (%s here already, pinned by digest)' "$(wc -l < "$d/skipped" | tr -d ' ')")"
}

# pulls_wait — setup run by ./stack update (DEVOS_ADE_PULLS_DIR): its downloads, before anything starts with an image
# of this version. Each one as a step of its own ("Download litellm:1.105.0 ready (1m10s)": its own time, side by side
# with the others and setup's builds; the caller's step times the wait); one that failed stops setup there, with the
# image's own last words (nothing runs a new image yet: the update can be finished, or rolled back, as after any setup
# that stopped). Still waiting, it says so every 2½ minutes (BUILD_TICK_S); a download process that is gone counts as
# failed for what it had not finished.
pulls_wait() {
  local d="${DEVOS_ADE_PULLS_DIR:-}" pid="${DEVOS_ADE_PULLS_PID:-}" f r t rc bad='' start next
  [ -n "$d" ] && [ -d "$d" ] || return 0
  start="$(_now)"; next=$((SECONDS + BUILD_TICK_S))
  while [ ! -f "$d/done" ]; do
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 1
    [ "$SECONDS" -ge "$next" ] || continue
    next=$((next + BUILD_TICK_S)); log "still downloading images ($(fmt_elapsed $(($(_now) - start))))"
  done
  for f in "$d"/*.ref; do
    [ -f "$f" ] || continue
    r="$(cat "$f")"; t=''; rc=''
    [ ! -f "${f%.ref}.res" ] || IFS=$'\t' read -r _ t rc < "${f%.ref}.res"
    if [ "$rc" = 0 ]; then log "$(phase_line "Download $(image_short "$r")" "${t:-0}")"
    else
      bad="$bad $r"
      warn "could not download $r — its last words:"
      tail -n 8 "${f%.ref}.log" 2>/dev/null | sed 's/^/    /' >&2
    fi
  done
  [ ! -s "$d/skipped" ] || log "here already, pinned by digest (not asked again): $(while IFS= read -r r; do printf '%s ' "$(image_short "$r")"; done < "$d/skipped")"
  [ -z "$bad" ] || die "image download failed (network/registry?):$bad — nothing was started with this version's images yet"
  rm -rf "$d"
}

# --- image builds: when each image was ready, and what was built again ---

# _stamp_rel — stdin to stdout, each line after the seconds since it started ("12 #5 DONE 3.1s"); bash only
_stamp_rel() {
  local line
  SECONDS=0
  while IFS= read -r line || [ -n "$line" ]; do printf '%s %s\n' "$SECONDS" "$line"; done
}

# build_plain ARGS... — dc build ARGS with BuildKit's plain output, each line after the seconds since the build began
# (_stamp_rel), for build_report; its exit status is the build's. Called where set -e is off (a condition).
build_plain() {
  dc --progress plain build "$@" 2>&1 | _stamp_rel
  return "${PIPESTATUS[0]}"
}

# build_report < build_plain's output -> a line per image built: "IMAGE<TAB>READY_S<TAB>STEPS_RUN<TAB>WHY<TAB>WHY_S"
# — when it was ready (its "naming to …/IMAGE" line: seconds since the build began), how many of its steps ran again
# (not from Docker's cache), and the slowest of them with its own time; then "tools<TAB>-<TAB>RAN<TAB>…<TAB>SECONDS" for the
# terminal's ai-tools stage (your subscriptions' tools; RAN 0: from Docker's cache, else what install.sh says it
# installed and kept). IMAGE is the image's name without project and tag (portal, terminal-egress).
build_report() {
  awk '
    function clean(s) { gsub(/[\t\r]/, " ", s); return s }
    $2 ~ /^#[0-9]+$/ {
      id = $2; t = $1
      rest = $0; sub(/^[0-9]+ #[0-9]+ /, "", rest)
      if (rest ~ /^\[/) {
        hdr = substr(rest, 2, index(rest, "]") - 2); title = substr(rest, index(rest, "]") + 2)
        n = split(hdr, w, " "); svc = w[1]; stage = (n >= 2 ? w[2] : "")
        if (stage == "internal" || svc == "internal") next
        step_svc[id] = svc; step_title[id] = title
        if (title ~ /^RUN .*sh \/tmp\/tools\/install\.sh/) { tools_id[id] = 1; tools_seen = 1 }
        next
      }
      if (rest == "CACHED") { cached[id] = 1; next }
      if (rest ~ /^naming to /) {
        img = rest; sub(/^naming to /, "", img); sub(/ done$/, "", img); sub(/:[^:\/]*$/, "", img); sub(/^.*\//, "", img)
        if (!(img in ready)) { ready[img] = t; order[++k] = img; svc_of[img] = step_svc[id] }
        next
      }
      # (the tools stage says what it installed and what it kept: install.sh last line)
      if ((id in tools_id) && rest ~ /ai-tools: installed: /) { d = rest; sub(/^.*ai-tools: /, "", d); tools_detail = clean(d); next }
      if (rest ~ /^DONE [0-9.]+s$/ && (id in step_svc) && !(id in cached)) {
        s = rest; sub(/^DONE /, "", s); sub(/s$/, "", s); s += 0
        ttl = step_title[id]
        if (id in tools_id) { tools_s = s; tools_ran = 1 }
        if (ttl ~ /^(RUN|COPY|ADD) /) {
          sv = step_svc[id]; ran[sv]++
          if (s >= slow[sv]) { slow[sv] = s; why[sv] = ttl }
        }
      }
    }
    END {
      for (i = 1; i <= k; i++) {
        img = order[i]; sv = svc_of[img]
        y = clean(why[sv]); gsub(/--mount=[^ ]* /, "", y); if (length(y) > 48) y = substr(y, 1, 47) "…"
        printf "%s\t%d\t%d\t%s\t%d\n", img, ready[img], ran[sv] + 0, y, slow[sv] + 0
      }
      if (tools_seen) printf "tools\t-\t%d\t%s\t%d\n", tools_ran + 0, (tools_detail == "" ? "-" : tools_detail), tools_s + 0
    }'
}

# build_steps OUT — build_report's lines as steps of Home's card: "Image portal (from Docker's cache) ready (2s)",
# "Image terminal (rebuilt from RUN apt-get …) ready (4m20s)" and "Subscription tools (pinned, unchanged) ready (0s)" /
# "Subscription tools (installed again) ready (3m05s)". Never fatal.
build_steps() {
  local img at ran why ws
  while IFS=$'\t' read -r img at ran why ws; do
    [ -n "$img" ] || continue
    if [ "$img" = tools ]; then
      # (from Docker's cache: nothing ran; else install.sh's own account — what it installed, what it kept)
      if [ "$ran" = 0 ]; then log "$(phase_line "Subscription tools (pinned, unchanged)" 0)"
      elif [ "$why" != - ]; then log "$(phase_line "Subscription tools ($why)" "$ws")"
      else log "$(phase_line "Subscription tools (installed)" "$ws")"; fi
    elif [ "$ran" = 0 ]; then log "$(phase_line "Image $img (from Docker's cache)" "$at")"
    else log "$(phase_line "Image $img (rebuilt from ${why:-a changed step}, $(fmt_elapsed "$ws"))" "$at")"; fi
  done < <(build_report < "$1" 2>/dev/null)
  return 0
}

# --- the sandboxes' images, in the background ---

# sandbox_build_start ARGS -- SERVICE... — dc build of the terminal's, its egress proxy's and the Code page's images in
# the background (build_plain into a file): SANDBOX_BUILD names them while it runs. sandbox_build_wait collects it.
# A setup that ends before (an error, Ctrl-C) waits for it first (_sandbox_build_reap): no build of this run may name
# an image after the command that started it has ended.
SANDBOX_BUILD=''; SANDBOX_BUILD_PID=''; SANDBOX_BUILD_OUT=''; SANDBOX_BUILD_START=''
sandbox_build_start() {
  local args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  shift
  [ $# -gt 0 ] || return 0
  SANDBOX_BUILD=" $* "; SANDBOX_BUILD_OUT="$(mktemp)"; SANDBOX_BUILD_START="$(_now)"
  ( trap - EXIT; build_plain ${args[@]+"${args[@]}"} "$@" > "$SANDBOX_BUILD_OUT" 2>&1; echo "$?" > "$SANDBOX_BUILD_OUT.rc" ) </dev/null &
  SANDBOX_BUILD_PID=$!
  on_exit _sandbox_build_reap
}
_sandbox_build_reap() {
  [ -n "$SANDBOX_BUILD_PID" ] || return 0
  wait "$SANDBOX_BUILD_PID" 2>/dev/null || true
  rm -f "$SANDBOX_BUILD_OUT" "$SANDBOX_BUILD_OUT.rc"
  SANDBOX_BUILD_PID=''
}

# sandbox_build_wait — the background build's result, once: as steps of their own (build_steps; "Sandbox images" for
# the wait), and SETUP_BUILT names its images when it succeeded (lib/common.sh built_now). One that failed is said, and
# each image is built on its own next (terminal_build, code_build), which says the failure where it belongs. A helper
# job's log gets "still building" lines meanwhile.
sandbox_build_wait() {
  local rc start next svcs
  [ -n "$SANDBOX_BUILD_PID" ] || return 0
  start="$(_now)"; phase_start "Sandbox images"; next=$((SECONDS + BUILD_TICK_S))
  while kill -0 "$SANDBOX_BUILD_PID" 2>/dev/null; do
    sleep 1
    [ "$SECONDS" -ge "$next" ] || continue
    next=$((next + BUILD_TICK_S)); log "still building the sandbox's images ($(fmt_elapsed $(($(_now) - SANDBOX_BUILD_START))))"
  done
  wait "$SANDBOX_BUILD_PID" 2>/dev/null || true
  rc="$(cat "$SANDBOX_BUILD_OUT.rc" 2>/dev/null || echo 1)"
  svcs="$SANDBOX_BUILD"; SANDBOX_BUILD=''
  if [ "$rc" = 0 ]; then
    build_steps "$SANDBOX_BUILD_OUT"
    SETUP_BUILT="${SETUP_BUILT:- }${svcs# }"
    log "$(phase_line "Sandbox images" $(($(_now) - start)))"
  else
    warn "the sandbox's images did not build side by side — each is built on its own next; the build's last messages:"
    sed 's/^[0-9]* //' "$SANDBOX_BUILD_OUT" | tail -n 12 | sed 's/^/    /' >&2
  fi
  rm -f "$SANDBOX_BUILD_OUT" "$SANDBOX_BUILD_OUT.rc"; SANDBOX_BUILD_PID=''
}

# --- setup's update mode: a step runs only when its inputs changed since the last successful setup (JON-972) ---
#
# ./stack update runs `./stack setup --yes --update-mode` (nothing else turns it on; ./stack update --force, a plain
# ./stack setup, ./stack models --recheck run every step). Each gated step has an input digest (upd_in_NAME below: a hash of
# what the step reads — the .env keys, the catalog and templates, the compose files, the images this checkout builds, the
# containers' identity, the price file's age, and the step's own code). The digests of the last setup that SUCCEEDED are
# kept in .state/update/step-inputs.tsv, written only at its end (upd_commit); a setup removes the file when it starts
# (upd_begin), so one that fails halfway leaves none and the next update runs every step. A digest is taken after the step
# ran (what a later step reads from it is then in it) and compared before the next time. When in doubt a step runs: a digest
# that cannot be made differs from every earlier one. The model check (setup_bringup_and_probe; probe_reusable) skips on the
# same footing, with its own mark.
UPD_MODE=0; UPD_RECORD=0; UPD_PREV=''; UPD_NOW=''; UPD_CTR=''; UPD_CTR_SET=0; UPD_IDS=''; UPD_IDS_SET=0
UPD_STARTED_ALL=0   # the one `compose up` of all the services ran (upd_start_all_ok): the steps that start one are not needed
upd_file() { printf '%s/update/step-inputs.tsv\n' "$STATE_DIR"; }
upd_begin() {
  local f; f="$(upd_file)"
  UPD_PREV=''; UPD_NOW=''; UPD_CTR=''; UPD_CTR_SET=0; UPD_IDS=''; UPD_IDS_SET=0; UPD_STARTED_ALL=0
  UPD_RECORD=1   # (only a command that begins one — ./stack setup — notes digests: models --recheck runs the steps without)
  if [ -f "$f" ] && [ ! -L "$f" ]; then UPD_PREV="$(cat "$f" 2>/dev/null || true)"; fi
  rm -f "$f" 2>/dev/null || true
}
upd_forget() { rm -f "$(upd_file)" 2>/dev/null || true; }
# upd_commit — the setup succeeded: its digests become the state the next update compares with. A mark of the commit is
# not needed: the file exists only after a success.
upd_commit() {
  local f; f="$(upd_file)"
  mkdir -p "${f%/*}" 2>/dev/null && chmod 700 "${f%/*}" 2>/dev/null || return 0
  printf '%s\n' "$UPD_NOW" > "$f.tmp" 2>/dev/null && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f" 2>/dev/null || rm -f "$f.tmp" 2>/dev/null
  return 0
}
_upd_sum() { openssl dgst -sha256 2>/dev/null | awk '{ print $NF }'; }
# _upd_files FILE... -> each file's name and checksum ("-" for one that is not there)
_upd_files() { local f; for f in "$@"; do if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum < "$f" | awk '{ print $1 "-" $2 }')"; else printf '%s -\n' "$f"; fi; done; }
# _upd_tree DIR... -> the names and checksums of the files under them
_upd_tree() { local d; for d in "$@"; do [ -d "$d" ] || { printf '%s -\n' "$d"; continue; }; ( cd "$d" && find . -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f" | awk '{ print $1 "-" $2 }')"; done ); done; }
# _upd_fn NAME... -> the step's own code: the definition of each function (a release that changes it re-runs the step)
_upd_fn() { local n; for n in "$@"; do declare -f "$n" 2>/dev/null || printf 'no function %s\n' "$n"; done | cksum; }
# the .env keys setup itself writes after the ports and settings step (keys, the models' defaults, voice, the Open WebUI
# marks): never an input of a step before them
UPD_ENV_DERIVED='^(LITELLM_KEY_[A-Z_]*|OPENWEBUI_API_KEY|LITELLM_UI_USER|LITELLM_DB_ADMIN_READY|OWUI_[A-Z_]*|STT_BEDROCK_MODEL|CLAUDE_BEDROCK_[A-Z_]*|PORTAL_GID|REMOTE_SIDECAR_IP)='
_upd_env() { grep -vE "${1:-$UPD_ENV_DERIVED}" "$ENV_FILE" 2>/dev/null | LC_ALL=C sort; }   # (hashed with the rest, never printed)
_upd_env_settings() { _upd_env '^(LITELLM_KEY_[A-Z_]*|OPENWEBUI_API_KEY|LITELLM_UI_USER|LITELLM_DB_ADMIN_READY|OWUI_[A-Z_]*|STT_PROVIDER|STT_MODEL|STT_BEDROCK_MODEL|CLAUDE_BEDROCK_[A-Z_]*|PORTAL_GID|REMOTE_SIDECAR_IP)='; }
_upd_keys() { local k; for k in LITELLM_KEY_CLAUDE_CODE LITELLM_KEY_OPENWEBUI LITELLM_KEY_SETUP OPENWEBUI_API_KEY LITELLM_DB_ADMIN_READY; do printf '%s=%s\n' "$k" "$(get_env "$k")"; done; }
_upd_compose() { { cat "$STACK_DIR"/compose*.yaml 2>/dev/null; compose_overlays 2>/dev/null; project_name; } | cksum; }
# _upd_local_ids -> the IDs of the images this checkout builds (portal, shared-mcp, Open WebUI, stt), one docker call, kept
_upd_local_ids() {
  if [ "$UPD_IDS_SET" = 0 ]; then
    local p; p="$(project_name)"
    UPD_IDS="$(printf '%s\n' "$p/portal:local" "$p/shared-mcp:local" "$p/open-webui:local" "$p/stt:local" | snapshot_refs 2>/dev/null | LC_ALL=C sort)"
    UPD_IDS_SET=1
  fi
  printf '%s\n' "$UPD_IDS"
}
# _upd_containers -> the identity of the LiteLLM and Open WebUI containers (id and when each started), two docker calls, kept
# until upd_forget_containers: a recreated or restarted one is not the one an earlier step saw
_upd_containers() {
  if [ "$UPD_CTR_SET" = 0 ]; then
    local ids
    ids="$(dc ps -q litellm open-webui 2>/dev/null | tr '\n' ' ')"
    # shellcheck disable=SC2086  # one id per word
    if [ -n "$ids" ]; then UPD_CTR="$(docker inspect --format '{{.Name}} {{.Id}} {{.State.StartedAt}}' $ids 2>/dev/null | LC_ALL=C sort)"; else UPD_CTR=''; fi
    UPD_CTR_SET=1
  fi
  printf '%s\n' "$UPD_CTR"
}
upd_forget_containers() { UPD_CTR=''; UPD_CTR_SET=0; }
_upd_container_of() { _upd_containers | awk -v n="$1" 'index($1, n) { print }'; }

# --- each step's inputs (upd_in_NAME prints them; they are hashed, never shown) ---

# Ports and settings in .env: every .env key but the ones later steps write, and the code of the step. Remote access on: the
# step always runs (remote_net_preflight tells this run whether that network works, and a skipped step cannot).
upd_in_settings() {
  _upd_env_settings
  _upd_fn _setup_settings setup_ports setup_secrets setup_portal_host resolve_portal_port resolve_port migrate_direct_ports \
    remote_net_preflight setup_remote_choice setup_openrouter setup_explabs setup_stt ensure_portal_password_hash localgit_secrets \
    remote_ensure_proxy_secret owner_email_lowercase
  _upd_files "$STACK_DIR"/lib/ports.sh "$STACK_DIR"/lib/remote.sh "$STACK_DIR"/lib/openrouter.sh "$STACK_DIR"/lib/explabs.sh "$STACK_DIR"/lib/stt.sh
  if ! remote_on; then echo remote-off; else echo "remote-on $RANDOM$RANDOM"; fi
}
# Prices: the portal image that runs the updater, whether prices are updated at all, the catalog's prices, and the price
# file's age (fresh: written in the last 12 hours — the portal asks the sources itself every 24 h)
upd_in_prices() {
  _upd_local_ids | grep '/portal:local'
  printf 'updates=%s\n' "$(get_env PRICE_UPDATES)"
  _upd_files "$(prices_catalog)" "$STACK_DIR"/lib/prices.sh
  _upd_fn refresh_prices _setup_prices use_best_prices
  if [ "$(get_env PRICE_UPDATES)" = false ] || [ -n "$(find "$(prices_meta)" -mmin -720 2>/dev/null)" ]; then echo fresh; else echo "stale $RANDOM$RANDOM"; fi
}
# LiteLLM's config: everything render_config reads (.env, the catalog, the models found, the prices in use, the web search
# backend, the template code) and what it wrote (a config or hook that was changed by hand is written again)
upd_in_litellm_config() {
  _upd_env "^(LITELLM_KEY_[A-Z_]*|OPENWEBUI_API_KEY|LITELLM_UI_USER|OWUI_[A-Z_]*|CLAUDE_BEDROCK_[A-Z_]*|PORTAL_GID|REMOTE_SIDECAR_IP)="
  printf 'admin=%s\n' "$(get_env LITELLM_DB_ADMIN_READY)"
  catalog_rows 2>/dev/null | cksum
  _upd_files "$STACK_DIR/litellm/enabled-models.txt" "$STACK_DIR/litellm/probe-results.tsv" "$STACK_DIR/litellm/config.yaml" \
    "$STACK_DIR/litellm/bn_hooks.py" "$STACK_DIR/litellm/code-models.tsv" "$STACK_DIR/searxng/settings.yml" \
    "$STACK_DIR"/lib/models.sh "$STACK_DIR"/lib/websearch.sh "$STACK_DIR"/lib/code_models.sh "$STACK_DIR"/lib/explabs.sh \
    "$STACK_DIR"/lib/openrouter.sh "$STACK_DIR"/lib/local_models.sh "$STACK_DIR"/lib/litellm-hooks/bn_hooks.py
  prices_identity 2>/dev/null
  printf 'search=%s\n' "$(websearch_backend 2>/dev/null)"
  _upd_files "$STATE_DIR"/explabs-key.sha "$STATE_DIR"/openrouter-models-auto
  _upd_fn render_config _setup_websearch_render choose_defaults
}
# Voice (the choice of Bedrock speech-to-text from the models found)
upd_in_voice() {
  _upd_env; printf 'stt=%s\n' "$(get_env STT_PROVIDER)"
  _upd_files "$STACK_DIR/litellm/probe-results.tsv" "$STACK_DIR"/lib/stt.sh "$STATE_DIR/stt-start-failed"
  _upd_fn stt_after_probe stt_sync_env
}
# The speech-to-text container: its sources, the week of its ffmpeg layer, the compose files and the mark of a start that failed
upd_in_stt_service() {
  _upd_env; _upd_tree "$STACK_DIR/stt"; stt_apk_week; _upd_compose
  _upd_files "$STATE_DIR/stt-start-failed" "$STATE_DIR/stt-service" "$STACK_DIR"/lib/stt.sh
  _upd_local_ids | grep '/stt:local'
  _upd_fn stt_setup_service _stt_build_and_up _stt_build
}
# LiteLLM's virtual keys and its admin account (kept in its database): the budgets (.env), the keys as they are now, LiteLLM's
# image (the compose files) and the code
upd_in_keys() {
  _upd_env; _upd_keys; _upd_compose
  _upd_fn _setup_litellm_keys ensure_virtual_key setup_litellm_admin ensure_litellm_db_admin alert_pct_mark
}
# The portal sign-in and Chat's API key, and the Open WebUI syncs (models, prices, banner; the banner lives in Open WebUI's
# memory): the same Open WebUI container, and what the syncs send it
upd_in_signin() {
  _upd_env; _upd_keys; _upd_container_of open-webui; _upd_local_ids | grep -E '/(portal|open-webui):local'
  _upd_fn _setup_portal_signin settings_reconcile ensure_openwebui_api_key portal_session_start
}
upd_in_syncs() {
  _upd_env; _upd_keys; _upd_container_of open-webui; _upd_local_ids | grep '/open-webui:local'
  catalog_rows 2>/dev/null | cksum; prices_identity 2>/dev/null
  _upd_files "$STACK_DIR/litellm/enabled-models.txt" "$STATE_DIR/openrouter-owui-synced" "$STATE_DIR/explabs-owui-synced" "$STACK_DIR"/lib/owui.sh
  _upd_tree "$STACK_DIR/owui"
  _upd_fn _setup_owui_syncs sync_openwebui_models owui_install_cost_filter sync_budget_banner openrouter_sync_owui explabs_sync_owui stt_sync_owui
}
# The built-in SearXNG and the git server (Forgejo): their settings, compose files and code. The compose files carry their
# pinned images; compose itself recreates a container whose image or settings changed (config_sums), the step only checks.
upd_in_searxng() {
  _upd_env; _upd_compose; _upd_files "$STACK_DIR/searxng/settings.yml" "$STACK_DIR"/lib/websearch.sh
  _upd_fn websearch_builtin_up websearch_searxng_write websearch_builtin_on
}
upd_in_gitserver() {
  _upd_env; _upd_compose; _upd_files "$STACK_DIR"/lib/localgit.sh "$STATE_DIR"/localgit/tls/*
  _upd_fn localgit_start localgit_secrets localgit_tls_ensure
}
# The git server's account and the Code page's host (set in the Code page's container): both containers' images
upd_in_gitafter() {
  _upd_env; _upd_compose; _upd_local_ids | grep -E '/(portal|open-webui):local'
  _upd_files "$STATE_DIR"/localgit/tls/* "$STACK_DIR"/lib/localgit.sh "$STACK_DIR"/lib/code.sh
  { dc ps -q code terminal 2>/dev/null | tr '\n' ' '; } | awk '{ print "ctr " $0 }'
  _upd_fn localgit_after_up localgit_ensure_admin localgit_register_host
}
# The web search check (one search through LiteLLM) and the smoke test: LiteLLM's container, its config, models and keys
upd_in_websearch() {
  _upd_env; _upd_keys; _upd_container_of litellm; printf 'cfg=%s\n' "$(litellm_compose_sum)"
  printf 'fp=%s\n' "$(_ws_search_fp "$(websearch_backend 2>/dev/null)" 2>/dev/null | _upd_sum)"
  _upd_files "$STACK_DIR/litellm/enabled-models.txt" "$STACK_DIR"/lib/websearch.sh
  _upd_fn websearch_after_start websearch_search_check websearch_report
}
upd_in_smoke() {
  _upd_env; _upd_keys; _upd_container_of litellm; printf 'cfg=%s\n' "$(litellm_compose_sum)"
  _upd_files "$STACK_DIR/litellm/enabled-models.txt"; _upd_compose
  _upd_fn _setup_smoke_test cmd_test _check _test_portal ensure_portal_reachable
}
# The Code page on by default: the Code and terminal settings, their failure marks and the workspace folder
upd_in_codedefault() {
  _upd_env; _upd_files "$STATE_DIR"/code-default-failed "$STACK_DIR"/lib/code.sh
  [ -d "$(get_env TERMINAL_WORKSPACE)" ] && echo workspace-here || echo workspace-missing
  _upd_fn code_default_on code_default_wanted _code_default_skip
}

# upd_hash NAME -> the digest of the step's inputs now
# (in this shell, through a file: what the inputs keep — the images' IDs, the containers — is kept for the next digest; a grep
# that finds nothing is not a failure)
upd_hash() {
  local t h
  t="$(mktemp)" || return 1
  { printf 'v1 %s %s\n' "$(project_name)" "$STACK_DIR"; "upd_in_$1" || true; } > "$t" 2>/dev/null
  h="$(_upd_sum < "$t")"; rm -f "$t"
  printf '%s\n' "$h"
}
upd_in_defaults() { upd_in_litellm_config; }
upd_in_setupkey() { upd_in_keys; }
# upd_same NAME -> 0 when update mode is on and the step's inputs are what they were after the last successful setup
upd_same() {
  local prev now
  [ "$UPD_MODE" = 1 ] || return 1
  prev="$(printf '%s\n' "$UPD_PREV" | awk -F'\t' -v n="$1" '!f && $1 == n { print $2; f = 1 }')"
  [ -n "$prev" ] || return 1
  UPD_H="$(upd_hash "$1")"
  [ -n "$UPD_H" ] && [ "$UPD_H" = "$prev" ]
}
UPD_H=''
# upd_note NAME [HASH] — NAME's digest, as it is now (or HASH, when upd_same just made it), for upd_commit
upd_note() {
  local h
  [ "$UPD_RECORD" = 1 ] || return 0
  h="${2:-$(upd_hash "$1")}"
  UPD_NOW="$(printf '%s\n' "$UPD_NOW" | awk -F'\t' -v n="$1" '$1 != n && NF')"   # (a step noted twice keeps its last digest)
  UPD_NOW="${UPD_NOW}${UPD_NOW:+
}$1	$h"
}

# upd_gate [-s] NAME LABEL WHY CMD... — CMD as a timed step (timed_step; -s: CMD times itself, as a phase of its own); in update
# mode, when NAME's inputs did not change since the last successful setup, not run at all: "LABEL: not run — WHY" and a step
# of its own on Home's card, ready in 0 s (skipped). A step that ran or was skipped is noted for upd_commit; one that failed
# is not. UPD_SKIPPED says which it was.
UPD_SKIPPED=0
upd_gate() {
  local self=0 name label why rc
  [ "${1:-}" != -s ] || { self=1; shift; }
  name="$1"; label="$2"; why="$3"; shift 3
  UPD_SKIPPED=0
  if upd_same "$name"; then
    log "$label: not run — $why"; log "$label ready (skipped)"
    upd_note "$name" "$UPD_H"; UPD_SKIPPED=1; return 0
  fi
  if [ "$self" = 1 ]; then "$@"; rc=$?; else timed_step "$label" "$@"; rc=$?; fi
  [ "$rc" != 0 ] || upd_note "$name"
  return "$rc"
}

# upd_start_all_ok -> 0 when an update may start every service with one compose up: update mode, and the ports and settings, the
# keys and admin account, the voice settings and the speech-to-text container all unchanged — so no key is to be made or
# changed before Open WebUI starts with it, and nothing started later changes what Open WebUI was started with.
UPD_SETTINGS_SKIPPED=0
upd_start_all_ok() {
  [ "$UPD_MODE" = 1 ] && [ "$UPD_SETTINGS_SKIPPED" = 1 ] || return 1
  [ -n "$(get_env LITELLM_KEY_CLAUDE_CODE)" ] && [ -n "$(get_env LITELLM_KEY_OPENWEBUI)" ] && [ -n "$(get_env LITELLM_KEY_SETUP)" ] &&
    [ -n "$(get_env OPENWEBUI_API_KEY)" ] && [ "$(get_env LITELLM_DB_ADMIN_READY)" = true ] || return 1
  upd_same keys && upd_same voice && upd_same stt_service
}
