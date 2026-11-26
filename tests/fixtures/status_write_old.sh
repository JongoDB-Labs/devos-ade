# shellcheck shell=bash
# shellcheck disable=SC2120  # the old functions took their arguments as the new ones do
# The functions as they were at 19702f3d (before JON-972 made them quicker), renamed old_*: tests/test_health_identity.sh
# runs them beside the new ones and compares the files byte for byte. Do not edit.
old_health_record_write() {
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
old_services_status_write() {
  local d f tmp ps s row state health out='' extra
  [ -f "$ENV_FILE" ] || return 0
  if [ $# -gt 0 ]; then ps="$1"
  else ps="$(dc ps -a --format '{{.Service}}	{{.State}}	{{.Health}}' 2>/dev/null)" || return 0; fi
  d="$(status_dir)"; mkdir -p "$d" 2>/dev/null || return 0
  f="$(services_status_file)"
  extra="$(optional_services 2>/dev/null || true)"
  for s in $STACK_BASE_SERVICES $extra; do
    row="$(printf '%s\n' "$ps" | awk -F'\t' -v s="$s" '!f && $1 == s { print $2 "\t" $3; f = 1 }')"
    state="${row%%	*}"; health="${row#*	}"
    [ -n "$row" ] || { state="not created"; health=''; }
    # (Docker's own words — running, exited, healthy, starting …: lowercase letters, spaces and dashes only)
    state="$(printf '%s' "$state" | LC_ALL=C tr -cd 'a-z -' | cut -c1-24)"
    health="$(printf '%s' "$health" | LC_ALL=C tr -cd 'a-z -' | cut -c1-24)"
    out="$out${out:+, }{\"service\": \"$s\", \"state\": \"$state\", \"health\": \"$health\"}"
  done
  tmp="$(mktemp "$d/.services.XXXXXX" 2>/dev/null)" || return 0
  { printf '{"version": 1, "written_at": %s, "services": [%s]}\n' "$(date +%s)" "$out" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$f"; } 2>/dev/null ||
    rm -f "$tmp"
  ! declare -F old_health_record_write >/dev/null || old_health_record_write || true   # lib/health.sh: restarts, exit codes, unhealthy (local)
  return 0
}
