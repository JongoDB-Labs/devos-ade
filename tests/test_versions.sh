# shellcheck shell=bash
# shellcheck disable=SC2016  # literal $ in expected strings
# lib/versions.sh: the core services' running / pinned / newest versions (./stack versions, status, Settings) and the
# digest check at the end of ./stack update. Docker is stubbed with a tiny container + image store in $TMP.
. "$STACK_DIR/lib/commands.sh"

# _ctr SERVICE IMAGE_ID CONFIG_IMAGE   a container of this project;  _img ID DIGEST [LABEL]   an image: its repo digest and
# (a local build) the label naming its base image;  _built REF ID   what a local tag points to
_ctr() { mkdir -p "$TMP/ctr"; printf '%s|%s\n' "$2" "$3" > "$TMP/ctr/$1"; }
_img() { mkdir -p "$TMP/img"; printf '%s\n' "$2" > "$TMP/img/$1.digest"; printf '%s\n' "${3:-}" > "$TMP/img/$1.label"; }
_built() { mkdir -p "$TMP/ref"; printf '%s\n' "$2" > "$TMP/ref/$(printf '%s' "$1" | tr '/:' '__')"; }
_stub_docker() {
  printf 'COMPOSE_PROJECT_NAME=bn-t\n' > "$ENV_FILE"
  docker() {
    local last="${*: -1}" svc cid
    case "$*" in
      "ps -a -q --no-trunc --filter label=com.docker.compose.project=bn-t --filter label=com.docker.compose.service="*)
        svc="${last#label=com.docker.compose.service=}"; [ ! -f "$TMP/ctr/$svc" ] || echo "cid-$svc" ;;
      "inspect --format {{.Image}} cid-"*) cut -d'|' -f1 "$TMP/ctr/${last#cid-}" ;;
      "inspect --format {{.Config.Image}} cid-"*) cut -d'|' -f2 "$TMP/ctr/${last#cid-}" ;;
      "image inspect --format {{range .RepoDigests}}{{println .}}{{end}} "*) [ -f "$TMP/img/$last.digest" ] || return 1; cat "$TMP/img/$last.digest" ;;
      "image inspect --format {{index .Config.Labels \"dev.devos-ade.base-image\"}} "*) [ -f "$TMP/img/$last.label" ] || return 1; cat "$TMP/img/$last.label" ;;
      "image inspect --format {{.Id}} "*) cat "$TMP/ref/$(printf '%s' "$last" | tr '/:' '__')" 2>/dev/null || return 1 ;;
      *) echo "unexpected docker $*" >&2; return 1 ;;
    esac
  }
  cid=''
}
# every core service running exactly what compose.yaml pins
_all_match() {
  local id ref d
  for id in postgres rustfs rustfs-init litellm searxng caddy; do
    ref="$(compose_service_image "$id")"; d="$(ref_digest "$ref")"
    _img "img-$id" "${ref%%@*}@$d"; _ctr "$id" "img-$id" "$ref"
  done
  ref="$(compose_service_image open-webui)"
  _img img-open-webui "" "$ref"; _ctr open-webui img-open-webui "bn-t/open-webui:local"
  for id in portal shared-mcp stt; do _img "img-$id" ""; _ctr "$id" "img-$id" "bn-t/$id:local"; _built "bn-t/$id:local" "img-$id"; done
}

test_pins_are_read_from_compose_yaml() {
  assert_eq "$(ref_version "$(compose_service_image litellm)")" "$(sed -n 's|^    image: ghcr.io/berriai/litellm:\([0-9.]*\)@.*|\1|p' "$STACK_DIR/compose.yaml")"
  assert_contains "$(compose_service_image open-webui)" "ghcr.io/open-webui/open-webui:v"   # its build argument, not the :local image
  assert_not_contains "$(compose_service_image open-webui)" ":local"
  assert_eq "$(compose_service_image nonesuch)" ""
}

test_ref_version_drops_the_prefix_and_the_flavour() {
  assert_eq "$(ref_version ghcr.io/open-webui/open-webui:v0.12.4-slim@sha256:abc)" "0.12.4"
  assert_eq "$(ref_version pgvector/pgvector:0.8.7-pg17)" "0.8.7"
  assert_eq "$(ref_version caddy:2.11.7-alpine@sha256:abc)" "2.11.7"
  assert_eq "$(ref_version searxng/searxng:2026.10.24-ef0ec03da@sha256:abc)" "2026.10.24-ef0ec03da"
  assert_eq "$(ref_version bn-t/portal)" ""
  assert_eq "$(ref_digest foo:1@sha256:abc)" "sha256:abc"
  assert_eq "$(ref_digest foo:1)" ""
}

test_version_gt_compares_releases_numerically() {
  version_gt 1.106.5 1.106.3 || return 1
  version_gt 1.10.0 1.9.0 || return 1
  version_gt 1.0.3 1.0.3 && return 1
  version_gt 1.0.3 1.0.4 && return 1
  version_gt "" 1.0.3 && return 1
  return 0
}

test_every_listed_service_has_a_pin_and_a_name() {
  local id
  [ -n "$(core_service_ids)" ] || { echo "catalog/core-services.tsv lists nothing" >&2; return 1; }
  for id in $(core_service_ids); do
    [ -n "$(compose_service_image "$id")" ] || { echo "$id has no pin in compose.yaml" >&2; return 1; }
    [ -n "$(_core_field "$id" 2)" ] && [ -n "$(_core_field "$id" 3)" ] || { echo "$id: no name or newest version" >&2; return 1; }
  done
  assert_contains "$(core_service_ids | tr '\n' ' ')" "litellm open-webui rustfs"
}

test_the_manifest_never_lists_an_older_newest_than_the_pin() {
  local id n p
  for id in $(core_service_ids); do
    n="$(_core_field "$id" 3)"; p="$(ref_version "$(compose_service_image "$id")")"
    ! version_gt "$p" "$n" || { echo "$id: pinned $p is newer than the manifest's newest $n (bin/bump-core-services writes both)" >&2; return 1; }
  done
}

test_all_services_on_the_pinned_images_verify() {
  _stub_docker; _all_match
  update_verify_images 2> "$TMP/err" || { cat "$TMP/err" >&2; return 1; }
  assert_eq "$(cat "$TMP/err")" ""
}

test_a_service_on_another_digest_fails_the_update_check() {
  _stub_docker; _all_match
  _img img-litellm "ghcr.io/berriai/litellm@sha256:$(printf 'f%.0s' $(seq 64))"; _ctr litellm img-litellm "ghcr.io/berriai/litellm:1.105.0"
  if update_verify_images 2> "$TMP/err"; then echo "a stale litellm passed" >&2; return 1; fi
  assert_contains "$(cat "$TMP/err")" "litellm runs ghcr.io/berriai/litellm:1.105.0, not the $(ref_version "$(compose_service_image litellm)") this release pins"
}

test_an_image_that_cannot_be_read_fails_closed() {
  _stub_docker; _all_match
  rm "$TMP/img/img-rustfs.digest"
  if update_verify_images 2> "$TMP/err"; then echo "an unreadable image passed" >&2; return 1; fi
  assert_contains "$(cat "$TMP/err")" "rustfs runs"
}

test_open_webui_must_be_built_on_the_pinned_base() {
  _stub_docker; _all_match
  _img img-open-webui "" "ghcr.io/open-webui/open-webui:v0.12.0-slim@sha256:$(printf 'a%.0s' $(seq 64))"
  if update_verify_images 2> "$TMP/err"; then echo "an old Open WebUI base passed" >&2; return 1; fi
  assert_contains "$(cat "$TMP/err")" "open-webui runs"
  _img img-open-webui "" ""   # an image with no label at all (built before the label existed)
  if update_verify_images 2>/dev/null; then return 1; fi
}

test_a_local_build_that_is_not_the_fresh_one_fails() {
  _stub_docker; _all_match
  _built bn-t/portal:local img-portal-new
  if update_verify_images 2> "$TMP/err"; then echo "a stale portal passed" >&2; return 1; fi
  assert_contains "$(cat "$TMP/err")" "portal does not run the image this update built"
}

test_a_service_without_a_container_is_skipped_not_failed() {
  _stub_docker; _all_match
  rm "$TMP/ctr/stt" "$TMP/ctr/searxng"   # optional services that are off
  update_verify_images 2>/dev/null || return 1
}

test_cmd_update_runs_the_check_after_setup_and_before_the_update_counts_as_done() {
  local body
  body="$(sed -n '/^cmd_update() {/,/^}/p' "$STACK_DIR/lib/commands.sh")"
  assert_contains "$(printf '%s\n' "$body" | grep -n 'stack" setup --yes\|update_verify_images\|update_record_done' | cut -d: -f2- | tr -s ' ' | tr '\n' '|')" \
    ' ${pullenv[@]+"${pullenv[@]}"} "$STACK_DIR/stack" setup --yes ||| timed_step "Services run the pinned images" update_verify_images ||| update_record_done|'
}

test_versions_rows_and_the_plain_sentences() {
  _stub_docker; _all_match
  local row
  row="$(versions_row litellm)"
  assert_eq "$(printf '%s' "$row" | cut -f1,3,4)" "litellm	$(ref_version "$(compose_service_image litellm)")	$(ref_version "$(compose_service_image litellm)")"
  # a service on an older release than the pin: Update now brings it
  _img img-litellm "ghcr.io/berriai/litellm@sha256:$(printf 'e%.0s' $(seq 64))"; _ctr litellm img-litellm "ghcr.io/berriai/litellm:1.105.0"
  row="$(versions_row litellm)"
  assert_eq "$(printf '%s' "$row" | cut -f3)" "1.105.0"
  assert_eq "$(printf '%s' "$row" | cut -f6)" "pending"
  assert_eq "$(versions_say pending 1.106.5 1.106.3)" "Update now brings it to 1.106.3"
  assert_eq "$(versions_say behind 1.106.5 1.106.3)" "newer upstream exists (1.106.5); the next DevOS ADE release will bring it"
  assert_eq "$(versions_say current 1.106.3 1.106.3)" "current"
  # no container: not running
  rm "$TMP/ctr/rustfs"
  assert_eq "$(versions_row rustfs | cut -f3,6)" "	stopped"
}

test_cmd_versions_lists_every_core_service_plainly() {
  _stub_docker; _all_match
  local out; out="$(cmd_versions 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  assert_contains "$out" "Core service"
  assert_contains "$out" "LiteLLM"
  assert_contains "$out" "Open WebUI"
  assert_contains "$out" "RustFS"
  assert_contains "$out" "Update now"   # (the explanation line)
  if (cmd_versions extra) 2>/dev/null; then return 1; fi
}

test_status_gets_one_compact_line() {
  _stub_docker; _all_match
  local l; l="$(versions_status_line)"
  case "$l" in "Core services: "*) ;; *) echo "line: $l" >&2; return 1 ;; esac
  [ "$(printf '%s\n' "$l" | wc -l | tr -d ' ')" = 1 ] || return 1
  _img img-caddy "caddy@sha256:$(printf 'd%.0s' $(seq 64))"; _ctr caddy img-caddy "caddy:2.11.0-alpine"
  assert_contains "$(versions_status_line)" "not on this release's pinned version — ./stack update"
}

test_versions_json_for_settings() {
  _stub_docker; _all_match; mkdir -p "$STATE_DIR"
  write_versions_json
  f="$(status_dir)/versions.json"
  [ -f "$f" ] || { echo "no versions.json" >&2; return 1; }
  assert_contains "$(cat "$f")" '"id": "litellm", "name": "LiteLLM"'
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["version"]==1 and len(d["services"])>=6, d' "$f"
}

test_service_moves_names_what_an_update_changed() {
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$TMP/s/catalog"; STACK_DIR="$TMP/s"
  cp "$T_ROOT/catalog/core-services.tsv" "$TMP/s/catalog/"
  printf 'services:\n  litellm:\n    image: ghcr.io/berriai/litellm:1.105.0@sha256:aa\n  rustfs:\n    image: rustfs/rustfs:1.0.1\n  caddy:\n    image: caddy:2.11.7-alpine@sha256:bb\n' > "$STACK_DIR/compose.yaml"
  git init -q -b main "$STACK_DIR"; git -C "$STACK_DIR" add -A; git -C "$STACK_DIR" commit -qm one
  from="$(git -C "$STACK_DIR" rev-parse HEAD)"
  printf 'services:\n  litellm:\n    image: ghcr.io/berriai/litellm:1.106.3@sha256:cc\n  rustfs:\n    image: rustfs/rustfs:1.0.3@sha256:dd\n  caddy:\n    image: caddy:2.11.7-alpine@sha256:ee\n' > "$STACK_DIR/compose.yaml"
  assert_eq "$(service_moves "$from")" "$(printf 'RustFS 1.0.1 → 1.0.3\nLiteLLM 1.105.0 → 1.106.3')" || true
  out="$(service_moves "$from")"
  assert_contains "$out" "LiteLLM 1.105.0 → 1.106.3"
  assert_contains "$out" "RustFS 1.0.1 → 1.0.3"
  assert_not_contains "$out" "Caddy"   # a new digest of the same release is not a move
  assert_eq "$(service_moves)" ""
}

# LiteLLM's admin UI banner ("The latest version is …"): it has no setting, so every site block that serves the UI answers
# its one lookup route itself (caddy/Caddyfile litellm_no_banner)
test_litellm_new_version_banner_is_answered_by_caddy() {
  local f
  assert_contains "$(cat "$STACK_DIR/caddy/Caddyfile")" "@bn_litellm_latest path /get/latest_release_info"
  assert_contains "$(cat "$STACK_DIR/caddy/Caddyfile")" 'respond @bn_litellm_latest "null" 200'
  for f in Caddyfile remote-tailscale.caddy remote-domain.caddy; do
    assert_eq "$(grep -B1 'reverse_proxy litellm:4000 {' "$STACK_DIR/caddy/$f" | head -n 1 | tr -d '\t ')" "importlitellm_no_banner"
  done
}
