# shellcheck shell=bash
# Local container health (JON-440 G4, under JON-149): restart counts, exit codes and unhealthy transitions of this
# stack's containers, written next to services.json for the portal's Activity feed. LOCAL ONLY: nothing here sends
# anything anywhere, and nothing but Docker's own numbers and words is recorded (never a log line, a path, a command
# or an environment value). On by default: it is a display, not telemetry.
#
#   .state/status/container-health.json   {"version": 1, "written_at": N, "services": [{service, restarts, state,
#                                          exit_code, health}], "events": [{at, service, kind, count, exit_code}]}
#   .state/status/container-health.tsv    the last snapshot (what the next write compares with), pipe-separated
#   .state/status/container-events.tsv    the events, at most HEALTH_EVENTS_MAX, newest last
#
# An event: kind restart (RestartCount grew: count = by how much), unhealthy (health turned to unhealthy), exit (a
# container ended with a code other than 0 and 143, which `docker stop` gives; 137 only when it was out of memory)
# or oom (killed for memory; its exit_code is recorded as Docker reports it, usually 137). Each is recorded once: a restart by the count, an exit by the time it ended, an
# unhealthy by its change. The first look has no snapshot to compare with, so only what is wrong then (restarts
# already counted, an unhealthy or failed container) is recorded. A container made again (./stack down, up) starts
# its count over: that is not a restart. Only containers of this checkout's Compose project (dc ps) are looked at.
HEALTH_EVENTS_MAX=50
# The subjects a record may name: the stack's own services, as the compose files define them (compose.yaml and its
# overlays), and nothing else. A container of this project that is not one of them (a service you added to the
# project yourself) is recorded as "other" and never by name. docs/event-schema.md lists the same set; a test checks
# both against the compose files.
HEALTH_SERVICES="caddy chat-egress code forgejo litellm llamacpp ollama ollama-gate open-webui portal postgres rustfs rustfs-init searxng shared-mcp stt subs-chat tailscale terminal terminal-egress terminal-gateway vllm"
# An event row is immutable: at (the local clock as it is, never corrected), count and exit_code are fixed when the
# row is first written and never recomputed (a replayed event must make the same dedupe key). Rows are only ever
# appended, and the oldest dropped from the front past HEALTH_EVENTS_MAX.

# health_subject NAME -> NAME when it is one of HEALTH_SERVICES, else "other"
health_subject() { case " $HEALTH_SERVICES " in *" $1 "*) printf '%s' "$1" ;; *) printf other ;; esac; }

health_json_file() { printf '%s/container-health.json\n' "$(status_dir)"; }

# _health_word TEXT -> TEXT as Docker words (lowercase letters, digits, dashes, underscores, at most 40)
_health_word() { printf '%s' "$1" | LC_ALL=C tr -cd 'a-z0-9_-' | cut -c1-40; }
_health_num() { local n; n="$(printf '%s' "$1" | LC_ALL=C tr -cd '0-9' | cut -c1-12)"; printf '%s' "${n:-0}"; }

# health_ids -> the ids of this project's containers, one a line (tests/e2e/container-health.sh asks by label instead)
health_ids() { dc ps -a -q 2>/dev/null; }

# health_inspect -> one line per container of this project: service|restarts|state|exit|health|oom|finished
# (a Docker that does not answer: nothing, status 1). Overridable by tests' stubs of docker.
health_inspect() {
  local ids
  ids="$(health_ids)" || return 1
  ids="$(printf '%s\n' "$ids" | grep -E '^[0-9a-f]{12,64}$' || true)"   # (container ids only)
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086  # one id per word
  docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}|{{.RestartCount}}|{{.State.Status}}|{{.State.ExitCode}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.State.OOMKilled}}|{{.State.FinishedAt}}' $ids 2>/dev/null
}

# health_record_write [LINES] — compares the containers now (LINES, else health_inspect) with the last snapshot,
# appends the new events and rewrites container-health.json. Never fatal; writes nothing without an answer.
health_record_write() {
  local d now lines prev_f ev_f snap tmp out pf='' nl new='' sj='' ej='' last=''
  [ -f "$ENV_FILE" ] || return 0
  d="$(status_dir)"; mkdir -p "$d" 2>/dev/null || return 0
  if [ $# -gt 0 ]; then lines="$1"; else lines="$(health_inspect)" || return 0; fi
  prev_f="$d/container-health.tsv"; ev_f="$d/container-events.tsv"; now="$(date +%s)"
  nl='
'
  [ ! -f "$prev_f" ] || pf="$prev_f"
  # One awk reads every container: sanitises each field as _health_word/_health_num do (bytes, LC_ALL=C), looks up
  # the first line of the last snapshot with the same key (`^key|`), decides the events, and prints three parts
  # divided by @@NEW and @@SJ lines: the new snapshot, the new event rows, the services' JSON. The snapshot key of a
  # container that is not one of HEALTH_SERVICES is other~<cksum of its name>: awk cannot sum, so cksum runs (once a
  # name) as a command of its own. Nothing printed: no container.
  out="$(printf '%s\n' "$lines" | LC_ALL=C awk -v now="$now" -v known="$HEALTH_SERVICES" -v pf="$pf" '
    function word(x) { gsub(/[^a-z0-9_-]/, "", x); return substr(x, 1, 40) }
    function num(x) { gsub(/[^0-9]/, "", x); x = substr(x, 1, 12); return x == "" ? "0" : x }
    function after(s, k,   i, p) { for (i = 0; i < k; i++) { p = index(s, "|"); if (!p) return ""; s = substr(s, p + 1) } return s }
    BEGIN {
      n = split(known, kw, " "); for (i = 1; i <= n; i++) isknown[kw[i]] = 1
      if (pf != "") {
        while ((getline l < pf) > 0) { i = index(l, "|"); if (i > 0) { k = substr(l, 1, i - 1); if (!(k in pl)) pl[k] = l } }
        close(pf)
      }
    }
    {
      n = split($0, f, "|")
      svc = word(f[1]); if (svc == "") next
      rs = num(f[2]); st = word(f[3]); ex = num(f[4]); hl = word(f[5]); oom = word(f[6])
      fin = after($0, 6); gsub(/[^0-9TZ:.-]/, "", fin); fin = substr(fin, 1, 40)
      if (oom != "true") oom = "false"
      key = svc
      if (!(svc in isknown)) {
        svc = "other"
        if (!(key in ck)) {
          cmd = "printf %s \047" key "\047 | cksum"; r = ""; cmd | getline r; close(cmd)
          split(r, a, " "); ck[key] = a[1]
        }
        key = "other~" ck[key]
      }
      p_rs = 0; p_hl = ""; p_fin = ""; found = 0
      if (key in pl) {
        found = 1; l = pl[key]; split(l, g, "|"); p_rs = g[2]; p_hl = g[5]; p_fin = after(l, 6)
      }
      if ((!found || p_rs ~ /^[0-9]+$/) && rs + 0 > p_rs + 0)
        new = new now "|" svc "|restart|" sprintf("%.0f", rs - p_rs) "|" ex "\n"
      if (hl == "unhealthy" && p_hl != "unhealthy") new = new now "|" svc "|unhealthy|0|0\n"
      if (st == "exited" && fin != "" && fin != p_fin && substr(fin, 1, 5) != "0001-") {
        if (oom == "true") new = new now "|" svc "|oom|0|" ex "\n"
        else if (ex != "0" && ex != "143" && ex != "137") new = new now "|" svc "|exit|0|" ex "\n"
      }
      snap = snap key "|" rs "|" st "|" ex "|" hl "|" oom "|" fin "\n"
      sj = sj (sj == "" ? "" : ", ") "{\"service\": \"" svc "\", \"restarts\": " rs ", \"state\": \"" st "\", \"exit_code\": " ex ", \"health\": \"" hl "\"}"
      cnt++
    }
    END { if (cnt) printf "%s@@NEW\n%s@@SJ\n%s\n", snap, new, sj }
  ' 2>/dev/null)" || out=''
  [ -n "$out" ] || return 0   # no container of this project: nothing to say (the old record stays)
  snap="${out%%@@NEW${nl}*}"; out="${out#*@@NEW${nl}}"
  new="${out%%@@SJ${nl}*}"; sj="${out#*@@SJ${nl}}"
  tmp="$(mktemp "$d/.container-health.XXXXXX" 2>/dev/null)" || return 0
  { [ -z "$new" ] || printf '%s' "$new" >> "$ev_f"
    [ ! -f "$ev_f" ] || { tail -n "$HEALTH_EVENTS_MAX" "$ev_f" > "$tmp" && cat "$tmp" > "$ev_f"; }
    printf '%s' "$snap" > "$tmp" && mv -f "$tmp" "$prev_f"
    chmod 644 "$prev_f" "$ev_f" 2>/dev/null
    if [ -f "$ev_f" ]; then
      last="$(tail -c 1 "$ev_f")"   # (not empty: the last line has no newline, which `read` leaves out)
      ej="$(LC_ALL=C awk -v drop="$last" '
        function word(x) { gsub(/[^a-z0-9_-]/, "", x); return substr(x, 1, 40) }
        function num(x) { gsub(/[^0-9]/, "", x); x = substr(x, 1, 12); return x == "" ? "0" : x }
        function after(s, k,   i, p) { for (i = 0; i < k; i++) { p = index(s, "|"); if (!p) return ""; s = substr(s, p + 1) } return s }
        function emit(l,   p, at, f) {
          p = index(l, "|"); at = p ? substr(l, 1, p - 1) : l
          if (at == "") return
          split(l, f, "|")
          ej = ej (ej == "" ? "" : ", ") "{\"at\": " num(at) ", \"service\": \"" word(f[2]) "\", \"kind\": \"" word(f[3]) "\", \"count\": " num(f[4]) ", \"exit_code\": " num(after(l, 4)) "}"
        }
        { if (have) emit(prev); prev = $0; have = 1 }
        END { if (have && drop == "") emit(prev); printf "%s", ej }
      ' "$ev_f")"
    fi
    tmp="$(mktemp "$d/.container-health.XXXXXX")" &&
      printf '{"version": 1, "written_at": %s, "services": [%s], "events": [%s]}\n' "$now" "$sj" "$ej" > "$tmp" &&
      chmod 644 "$tmp" && mv -f "$tmp" "$(health_json_file)"
  } 2>/dev/null || rm -f "$tmp"
  return 0
}
