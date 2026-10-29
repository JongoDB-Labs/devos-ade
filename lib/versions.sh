# shellcheck shell=bash
# The core services' versions: what each runs now, what this release pins, and the newest upstream release
# (./stack versions, the line in ./stack status, Settings › Updates & backups › Core services), and the check at the end
# of ./stack update that every recreated service runs exactly the image this release pins. Sourced by lib/commands.sh.
#
#   running   the image the service's container was created from (its tag; Open WebUI: the base image it was built on)
#   pinned    what compose.yaml names for it (the release's own pin, with its digest)
#   newest    the newest stable upstream release when bin/bump-core-services last ran (catalog/core-services.tsv: a
#             maintainer's tool, run before every release — docs/releasing.md); users' computers never ask upstream
#
# The check (update_verify_images) is by DIGEST: a registry image's container must be of an image whose digest is the one
# compose.yaml pins; Open WebUI's local build must say (label) it was built on the pinned base; the portal's, shared-mcp's
# and stt's builds must be the image just built. Anything else — or an image that cannot be read — fails the update.

core_services_tsv() { printf '%s/catalog/core-services.tsv\n' "$STACK_DIR"; }
BN_BASE_LABEL=dev.devos-ade.base-image   # open-webui/Dockerfile's label: the pinned image the local build is on

# core_service_ids -> the services of catalog/core-services.tsv (compose service names), in file order
core_service_ids() { awk -F'\t' '!/^#/ && NF >= 2 { print $1 }' "$(core_services_tsv)" 2>/dev/null; }
# _core_field ID N -> column N (1 id, 2 name, 3 newest, 4 released, 5 notes url, 6 checked) of its row
_core_field() { awk -F'\t' -v s="$1" -v n="$2" '!/^#/ && $1 == s { print $n; exit }' "$(core_services_tsv)" 2>/dev/null; }

# compose_service_image SERVICE [COMPOSE_FILE] -> the registry image compose.yaml pins for SERVICE: its `image:` line, or
# (Open WebUI, built locally on a pinned base) the `image:` build argument naming it; never this project's own :local
compose_service_image() {
  awk -v s="$1" '
    $0 ~ "^  " s ":[[:space:]]*$" { on = 1; next }
    on && /^  [A-Za-z0-9_-]+:/ { exit }
    on && /^[^ #]/ { exit }
    on && /^[[:space:]]+image:[[:space:]]/ {
      v = $0; sub(/^[[:space:]]+image:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v); gsub(/["'"'"']/, "", v)
      if (v !~ /COMPOSE_PROJECT_NAME/) { print v; exit }
    }' "${2:-$STACK_DIR/compose.yaml}"
}

# ref_digest REF -> sha256:… of a pinned reference ("" without one)
ref_digest() { case "$1" in *@sha256:*) printf '%s\n' "sha256:${1##*@sha256:}" ;; esac; }
# ref_version REF -> the release a reference names: tag without a leading v and without the image flavour
# (v0.12.4-slim → 0.12.4, 0.8.7-pg17 → 0.8.7, 2.11.7-alpine → 2.11.7); "" when it has no tag
ref_version() {
  local r="${1%%@*}" t
  case "${r##*/}" in *:*) t="${r##*:}" ;; *) return 0 ;; esac
  t="${t#v}"; t="${t%-slim}"; t="${t%-alpine}"; t="${t%-builder-alpine}"; t="${t%-pg[0-9]*}"
  printf '%s\n' "$t"
}
# version_gt A B -> 0 when A is a newer release than B (sort -V; equal or unreadable: no)
version_gt() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }

# _svc_container SERVICE -> the id of this project's container of SERVICE (any state), "" when there is none
_svc_container() {
  docker ps -a -q --no-trunc --filter "label=com.docker.compose.project=$(project_name)" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -n 1
}
# _svc_image_id CID -> the image id the container was created from
_svc_image_id() { docker inspect --format '{{.Image}}' "$1" 2>/dev/null; }

# _svc_running_ref SERVICE CID PINNED -> the reference the container runs: its image's tag, or for Open WebUI's local
# build the base image it says it was built on (the label). The label is read from the container, which Docker gives a
# copy of its image's labels when it creates it: on Docker's containerd image store a rebuild that came wholly from the
# cache gets a new id (its provenance attestation is new), the old image is gone, and Compose rightly keeps the container.
_svc_running_ref() {
  local cfg lab
  cfg="$(docker inspect --format '{{.Config.Image}}' "$2" 2>/dev/null)" || return 0
  case "$cfg" in
    *:local | *:previous | '')
      lab="$(docker inspect --format "{{index .Config.Labels \"$BN_BASE_LABEL\"}}" "$2" 2>/dev/null || true)"
      case "$lab" in '<no value>') lab='' ;; esac
      printf '%s\n' "$lab" ;;
    *) printf '%s\n' "$cfg" ;;
  esac
}

# _svc_matches SERVICE PINNED CID -> 0 when the container runs the pinned image (by digest; a pin without one: by
# reference), 1 when it does not or when that cannot be read (fails closed)
_svc_matches() {
  local pinned="$2" cid="$3" want img have
  want="$(ref_digest "$pinned")"
  img="$(_svc_image_id "$cid")"; [ -n "$img" ] || return 1
  if [ -n "$want" ] && have="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$img" 2>/dev/null)"; then
    printf '%s\n' "$have" | grep "@$want\$" >/dev/null && return 0
  elif [ -n "$want" ]; then
    # an image that cannot be read: only a local build may still say what it is (its container's label, above)
    case "$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null)" in *:local | *:previous) ;; *) return 1 ;; esac
  fi
  # a local build (Open WebUI): it says which pinned image it was built on
  [ "$(_svc_running_ref "$1" "$cid" "$pinned")" = "$pinned" ]
}

# _svc_runs_build CID REF -> 0 when the container runs REF's image: the same id, or (Docker's containerd image store, a
# rebuild from the cache: _svc_running_ref) the same image for the container's platform
_svc_runs_build() {
  local img built md plat
  img="$(_svc_image_id "$1")"
  built="$(docker image inspect --format '{{.Id}}' "$2" 2>/dev/null || true)"
  [ -n "$img" ] && [ -n "$built" ] || return 1
  [ "$img" != "$built" ] || return 0
  read -r md plat <<EOF
$(docker inspect --format '{{with .ImageManifestDescriptor}}{{.Digest}} {{with .Platform}}{{.OS}}/{{.Architecture}}{{with .Variant}}/{{.}}{{end}}{{end}}{{end}}' "$1" 2>/dev/null || true)
EOF
  [ -n "$md" ] && [ -n "$plat" ] || return 1
  [ "$(docker image inspect --platform "$plat" --format '{{.Id}}' "$2" 2>/dev/null || true)" = "$md" ]
}

# versions_row ID -> "id<TAB>name<TAB>running<TAB>pinned<TAB>newest<TAB>state<TAB>notes_url":
# state: current | behind (newer upstream exists; the next release brings it) | pending (the pin is newer than what
# runs: ./stack update or up brings it) | stopped (no container: running is empty)
versions_row() {
  local id="$1" pinned pv rv newest cid ref state
  pinned="$(compose_service_image "$id")"; pv="$(ref_version "$pinned")"
  newest="$(_core_field "$id" 3)"
  cid="$(_svc_container "$id")"; rv=''
  if [ -n "$cid" ]; then ref="$(_svc_running_ref "$id" "$cid" "$pinned")"; rv="$(ref_version "$ref")"; fi
  if [ -z "$cid" ]; then state=stopped
  elif [ -n "$rv" ] && [ "$rv" != "$pv" ] || ! _svc_matches "$id" "$pinned" "$cid"; then state=pending
  elif version_gt "$newest" "$pv"; then state=behind
  else state=current; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(_core_field "$id" 2)" "$rv" "$pv" "$newest" "$state" "$(_core_field "$id" 5)"
}

# versions_say STATE NEWEST PINNED -> the plain sentence for a row
versions_say() {
  case "$1" in
    pending) printf 'Update now brings it to %s\n' "$3" ;;
    behind) printf 'newer upstream exists (%s); the next DevOS ADE release will bring it\n' "$2" ;;
    stopped) printf 'not running\n' ;;
    *) printf 'current\n' ;;
  esac
}

# core_versions_table -> every row of versions_row, one per core service
core_versions_table() { local id; for id in $(core_service_ids); do versions_row "$id"; done; }

# write_versions_json — .state/status/versions.json for Settings (the same rows). Never fatal.
write_versions_json() {
  local d tmp rows id name rv pv newest state url sep='' checked
  [ -f "$ENV_FILE" ] || return 0
  d="$(status_dir)"; mkdir -p "$d" 2>/dev/null || return 0
  rows="$(core_versions_table 2>/dev/null)" || return 0
  checked="$(awk -F'\t' '!/^#/ && $6 { print $6; exit }' "$(core_services_tsv)" 2>/dev/null || true)"   # (no list: none)
  tmp="$(mktemp "$d/.versions.XXXXXX")" || return 0
  {
    printf '{"version": 1, "written_at": %s, "checked": "%s", "services": [' "$(date +%s)" "$(printf '%s' "$checked" | LC_ALL=C tr -cd '0-9-')"
    while IFS="	" read -r id name rv pv newest state url; do
      [ -n "$id" ] || continue
      printf '%s{"id": "%s", "name": "%s", "running": "%s", "pinned": "%s", "newest": "%s", "state": "%s", "notes": "%s"}' "$sep" \
        "$(_json_str "$id")" "$(_json_str "$name")" "$(_json_str "$rv")" "$(_json_str "$pv")" "$(_json_str "$newest")" "$state" "$(_json_str "$url")"
      sep=', '
    done <<EOF
$rows
EOF
    printf ']}\n'
  } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  chmod 644 "$tmp"; mv -f "$tmp" "$d/versions.json" 2>/dev/null || rm -f "$tmp"
  return 0
}

# versions_status_line -> one line for ./stack status ("" when there is nothing to say)
versions_status_line() {
  local rows n_behind n_pending
  rows="$(core_versions_table 2>/dev/null)" || return 0
  [ -n "$rows" ] || return 0
  n_pending="$(printf '%s\n' "$rows" | awk -F'\t' '$6 == "pending"' | wc -l | tr -d ' ')"
  n_behind="$(printf '%s\n' "$rows" | awk -F'\t' '$6 == "behind"' | wc -l | tr -d ' ')"
  if [ "$n_pending" -gt 0 ]; then printf 'Core services: %s not on this release'"'"'s pinned version — ./stack update (./stack versions)\n' "$n_pending"
  elif [ "$n_behind" -gt 0 ]; then printf 'Core services: all on this release'"'"'s pinned versions; %s have a newer upstream release (the next DevOS ADE release brings them: ./stack versions)\n' "$n_behind"
  else printf 'Core services: all on this release'"'"'s pinned versions, the newest upstream (./stack versions)\n'; fi
}

cmd_versions() {
  local rows id name rv pv newest state url
  [ $# -eq 0 ] || die "usage: ./stack versions   (what each core service runs, what this release pins, the newest upstream)"
  [ -f "$(core_services_tsv)" ] || die "catalog/core-services.tsv is missing from this checkout"
  rows="$(core_versions_table)"
  printf '%-22s %-12s %-12s %-12s %s\n' "Core service" Running "This release" "Newest" ""
  while IFS="	" read -r id name rv pv newest state url; do
    [ -n "$id" ] || continue
    printf '%-22s %-12s %-12s %-12s %s\n' "$name" "${rv:--}" "${pv:--}" "${newest:--}" "$(versions_say "$state" "$newest" "$pv")"
  done <<EOF
$rows
EOF
  printf '\n"Newest" is upstream'"'"'s newest stable release when this DevOS ADE release was made (%s); releases are\n' \
    "$(awk -F'\t' '!/^#/ && $6 { print $6; exit }' "$(core_services_tsv)")"
  printf 'pinned a few days after upstream ships them, by digest. ./stack update (or Update now on Home) brings every service to what its release pins.\n'
  write_versions_json
}

# update_verify_images — after ./stack update's setup: every container this release recreated runs the image the
# release pins (digest match for registry images; the base-image label for Open WebUI's local build; the fresh build for
# the portal, shared-mcp and stt). Prints each mismatch; 0 when all match, 1 otherwise. A service with no container
# (an optional one that is off) is skipped; one whose image cannot be read fails.
update_verify_images() {
  local id pinned cid bad=0 p
  p="$(project_name)"
  for id in $(core_service_ids); do
    pinned="$(compose_service_image "$id")"; [ -n "$pinned" ] || continue
    cid="$(_svc_container "$id")"; [ -n "$cid" ] || continue
    if _svc_matches "$id" "$pinned" "$cid"; then continue; fi
    printf '  %s runs %s, not the %s this release pins\n' "$id" "$(_svc_running_ref "$id" "$cid" "$pinned" | sed 's/^$/an image it cannot name/')" "$(ref_version "$pinned")" >&2
    bad=1
  done
  for id in portal shared-mcp stt; do
    cid="$(_svc_container "$id")"; [ -n "$cid" ] || continue
    _svc_runs_build "$cid" "$p/$id:local" ||
      { printf '  %s does not run the image this update built (%s:local)\n' "$id" "$id" >&2; bad=1; }
  done
  return "$bad"
}
