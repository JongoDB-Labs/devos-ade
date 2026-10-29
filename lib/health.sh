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
HEALTH_SERVICES="caddy chat-egress code forgejo litellm llamacpp ollama ollama-gate open-webui portal postgres rustfs rustfs-init searxng shared-mcp stt subs-chat tailscale terminal terminal-egress terminal-gateway"
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
  local d now lines prev_f ev_f snap tmp line svc key rs st ex hl oom fin p_rs p_hl p_fin n new='' sj='' ej=''
  [ -f "$ENV_FILE" ] || return 0
  d="$(status_dir)"; mkdir -p "$d" 2>/dev/null || return 0
  if [ $# -gt 0 ]; then lines="$1"; else lines="$(health_inspect)" || return 0; fi
  prev_f="$d/container-health.tsv"; ev_f="$d/container-events.tsv"; now="$(date +%s)"
  snap=''
  while IFS='|' read -r svc rs st ex hl oom fin; do
    svc="$(_health_word "$svc")"; [ -n "$svc" ] || continue
    rs="$(_health_num "$rs")"; ex="$(_health_num "$ex")"; st="$(_health_word "$st")"; hl="$(_health_word "$hl")"
    oom="$(_health_word "$oom")"; fin="$(printf '%s' "$fin" | LC_ALL=C tr -cd '0-9TZ:.-' | cut -c1-40)"
    case "$oom" in true) ;; *) oom=false ;; esac
    # what a record names: a known service, else "other" (never the name). The snapshot, which stays on this computer
    # and is never sent, tells two such containers apart by a checksum of the name; svc is only ever the subject.
    key="$svc"; svc="$(health_subject "$svc")"
    [ "$svc" != other ] || key="other~$(printf '%s' "$key" | cksum | cut -d' ' -f1)"
    p_rs=0; p_hl=''; p_fin=''
    line="$(grep "^$key|" "$prev_f" 2>/dev/null | head -n 1 || true)"
    [ -z "$line" ] || IFS='|' read -r _ p_rs _ _ p_hl _ p_fin <<EOFP
$line
EOFP
    if [ "$rs" -gt "$p_rs" ]; then new="$new$now|$svc|restart|$((rs - p_rs))|$ex
"; fi
    if [ "$hl" = unhealthy ] && [ "$p_hl" != unhealthy ]; then new="$new$now|$svc|unhealthy|0|0
"; fi
    if [ "$st" = exited ] && [ -n "$fin" ] && [ "$fin" != "$p_fin" ] && [ "${fin#0001-}" = "$fin" ]; then
      if [ "$oom" = true ]; then new="$new$now|$svc|oom|0|$ex
"
      elif [ "$ex" != 0 ] && [ "$ex" != 143 ] && [ "$ex" != 137 ]; then new="$new$now|$svc|exit|0|$ex
"; fi
    fi
    snap="$snap$key|$rs|$st|$ex|$hl|$oom|$fin
"
    sj="$sj${sj:+, }{\"service\": \"$svc\", \"restarts\": $rs, \"state\": \"$st\", \"exit_code\": $ex, \"health\": \"$hl\"}"
  done <<EOF2
$lines
EOF2
  [ -n "$snap" ] || return 0   # no container of this project: nothing to say (the old record stays)
  tmp="$(mktemp "$d/.container-health.XXXXXX" 2>/dev/null)" || return 0
  { [ -z "$new" ] || printf '%s' "$new" >> "$ev_f"
    [ ! -f "$ev_f" ] || { tail -n "$HEALTH_EVENTS_MAX" "$ev_f" > "$tmp" && cat "$tmp" > "$ev_f"; }
    printf '%s' "$snap" > "$tmp" && mv -f "$tmp" "$prev_f"
    chmod 644 "$prev_f" "$ev_f" 2>/dev/null
    while IFS='|' read -r at svc kind n ex; do
      [ -n "$at" ] || continue
      ej="$ej${ej:+, }{\"at\": $(_health_num "$at"), \"service\": \"$(_health_word "$svc")\", \"kind\": \"$(_health_word "$kind")\", \"count\": $(_health_num "$n"), \"exit_code\": $(_health_num "$ex")}"
    done < "$ev_f"
    tmp="$(mktemp "$d/.container-health.XXXXXX")" &&
      printf '{"version": 1, "written_at": %s, "services": [%s], "events": [%s]}\n' "$now" "$sj" "$ej" > "$tmp" &&
      chmod 644 "$tmp" && mv -f "$tmp" "$(health_json_file)"
  } 2>/dev/null || rm -f "$tmp"
  return 0
}
