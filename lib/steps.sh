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
# its environment: BEDROCK_NOW_PULLS_DIR, BEDROCK_NOW_PULLS_PID). Fails only when the images cannot be listed.
PULLS_DIR=''; PULLS_PID=''
pulls_start() {
  local d ref refs i=0
  d="$(pulls_dir)"
  rm -rf "$d"; mkdir -p "$d" || return 1
  refs="$(update_pull_refs)" || return 1
  [ -n "$refs" ] || return 1
  for ref in $refs; do
    if pull_needed "$ref"; then i=$((i + 1)); printf '%s\n' "$ref" > "$d/$i.ref"
    else printf '%s\n' "$ref" >> "$d/skipped"; fi
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

# pulls_wait — setup run by ./stack update (BEDROCK_NOW_PULLS_DIR): its downloads, before anything starts with an image
# of this version. Each one as a step of its own ("Download litellm:1.105.0 ready (1m10s)": its own time, side by side
# with the others and setup's builds; the caller's step times the wait); one that failed stops setup there, with the
# image's own last words (nothing runs a new image yet: the update can be finished, or rolled back, as after any setup
# that stopped). Still waiting, it says so every 2½ minutes (BUILD_TICK_S); a download process that is gone counts as
# failed for what it had not finished.
pulls_wait() {
  local d="${BEDROCK_NOW_PULLS_DIR:-}" pid="${BEDROCK_NOW_PULLS_PID:-}" f r t rc bad='' start next
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
