# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2329  # literal ${...} in patterns; stubs read by the libs
# LiteLLM's own image (litellm-image/, JON-1484): the pinned LiteLLM with its Python compiled at build time, so a start
# does not compile 2776 files again. One pin everywhere, compose's local name that no pull can replace, what the build
# does (and does not: no writable bytecode cache, no volume, no other setting), and every place that knows a local build.
# No Docker: the files are read.
. "$STACK_DIR/lib/commands.sh"

LLM="$STACK_DIR/litellm-image"

test_litellm_one_pin_everywhere_and_a_local_image_no_pull_replaces() {
  local pin dflt svc tag
  svc="$(awk '/^  litellm:$/ { f = 1; next } f && /^  [a-z]/ { f = 0 } f' "$STACK_DIR/compose.yaml")"
  pin="$(printf '%s\n' "$svc" | sed -n 's/^ *image: \(ghcr\.io\/berriai\/litellm:[^ ]*\)$/\1/p')"
  grep -qE '^ghcr\.io/berriai/litellm:[0-9][0-9.]*@sha256:[0-9a-f]{64}$' <<< "$pin" || { echo "pin: $pin" >&2; return 1; }
  # the Dockerfile's default is compose.yaml's pin; compose.yaml stays the single source
  dflt="$(sed -n 's/^ARG image=\(.*\)$/\1/p' "$LLM/Dockerfile")"
  assert_eq "$dflt" "$pin"
  assert_contains "$(cat "$LLM/Dockerfile")" 'FROM ${image}'
  # a local image of this project, built here, never pulled; the build context is the Dockerfile's folder alone
  assert_contains "$svc" 'image: ${COMPOSE_PROJECT_NAME:-devos-ade}/litellm:local'
  assert_contains "$svc" 'pull_policy: never'
  assert_contains "$svc" 'context: ./litellm-image'
  assert_eq "$(ls -A "$LLM" | tr '\n' ' ')" "Dockerfile "
  # no other reference to LiteLLM's registry image in any compose file
  assert_eq "$(grep -h 'berriai/litellm' "$STACK_DIR"/compose*.yaml | wc -l | tr -d ' ')" 1
  # the pin is still read as before: from the build argument, never the :local name
  assert_eq "$(compose_service_image litellm)" "$pin"
  # (the e2e reads the tag from compose.yaml: its first image line naming LiteLLM)
  tag="$(sed -n "s|^[[:space:]]*image:[[:space:]]*[^[:space:]]*berriai/litellm:\\([^@[:space:]]*\\).*|\\1|p" "$STACK_DIR/compose.yaml" | head -n 1)"
  assert_contains "$pin" "litellm:$tag@"
}

test_litellm_image_compiles_site_packages_and_changes_nothing_else() {
  local d; d="$(cat "$LLM/Dockerfile")"
  # the pinned base is labelled (what ./stack update checks: lib/versions.sh BN_BASE_LABEL)
  assert_contains "$d" 'LABEL dev.devos-ade.base-image="${image}"'
  assert_contains "$d" "$BN_BASE_LABEL"
  # compiled at build time with the default timestamp invalidation, in parallel, quietly
  assert_contains "$d" 'python -m compileall -q -j 0 "$d"'
  assert_not_contains "$d" '--invalidation-mode'
  assert_not_contains "$d" ' -d '
  # the folders come from Python itself, not a hard-coded python3.NN path
  assert_contains "$d" 'site.getsitepackages()'
  assert_contains "$d" 'sysconfig.get_paths()["purelib"]'
  assert_not_contains "$d" 'python3.'
  assert_not_contains "$d" '/usr/lib'
  # nothing writable keeps compiled code (a security review rejected it) and nothing else of the image changes
  assert_not_contains "$d" 'PYTHONPYCACHEPREFIX'
  assert_not_contains "$d" 'PYTHONDONTWRITEBYTECODE'
  for w in VOLUME ENTRYPOINT CMD USER WORKDIR ENV COPY ADD EXPOSE HEALTHCHECK; do
    if grep -qE "^[[:space:]]*$w[[:space:]]" "$LLM/Dockerfile"; then echo "the Dockerfile sets $w: nothing else may change" >&2; return 1; fi
  done
  assert_not_contains "$(cat "$STACK_DIR/compose.yaml")" 'PYTHONPYCACHEPREFIX'
  assert_not_contains "$(cat "$STACK_DIR/compose.yaml")" 'litellm-pycache'
  # a compile that fails fails the build (set -e), never a half-compiled image
  assert_contains "$d" 'set -e;'
}

test_litellm_is_one_of_the_images_this_project_builds() {
  # kept as :previous for ./stack rollback, put back by it, removed with the install
  case " $LOCAL_BUILDS " in *" litellm "*) ;; *) echo "litellm is not in LOCAL_BUILDS: $LOCAL_BUILDS" >&2; return 1 ;; esac
  # never downloaded: the missing-image list leaves the local name out and keeps the pinned base
  printf 'COMPOSE_PROJECT_NAME=bn-t\n' > "$ENV_FILE"
  dc() { printf 'bn-t/litellm:local\nbn-t/open-webui:local\npgvector/pgvector:0.8.7-pg17\n'; }
  compose_refs() { printf 'bn-t/litellm:local\nghcr.io/berriai/litellm:1.0@sha256:%064d\n' 0; }
  assert_eq "$(_missing_candidates | tr '\n' ' ')" "pgvector/pgvector:0.8.7-pg17 ghcr.io/berriai/litellm:1.0@sha256:$(printf '%064d' 0) "
}

test_the_updates_local_image_ids_include_litellms() {
  project_name() { echo bn-t; }
  snapshot_refs() { cat > "$TMP/asked"; while IFS= read -r r; do printf 'id-%s\t%s\n' "${r%%:*}" "$r"; done < "$TMP/asked"; }
  UPD_IDS_SET=0
  assert_contains "$(_upd_local_ids)" "bn-t/litellm:local"
  assert_contains "$(cat "$TMP/asked")" "bn-t/litellm:local"
}

test_the_prepare_builds_litellms_image_only_when_the_release_has_one() {
  # the new release's own files decide (an older release has the registry image: nothing to build)
  mkdir -p "$TMP/rel/litellm-image"
  STACK_DIR="$TMP/rel"; terminal_on() { return 1; }; stt_services() { :; }
  assert_not_contains "$(_prep_services | tr '\n' ' ')" "litellm"
  : > "$TMP/rel/litellm-image/Dockerfile"
  assert_eq "$(_prep_services | tr '\n' ' ')" "portal shared-mcp open-webui litellm "
}

test_litellm_build_is_a_cache_hit_when_setup_built_it_and_builds_it_once_otherwise() {
  building() { shift; "$@"; }
  dc() { echo "dc $*" >> "$TMP/dc"; }
  : > "$TMP/dc"
  SETUP_BUILT=' portal litellm '; litellm_build || return 1
  assert_eq "$(cat "$TMP/dc")" ""
  SETUP_BUILT=''; litellm_build || return 1
  assert_eq "$(cat "$TMP/dc")" "dc build -q litellm"
  # a failed build fails the step
  dc() { return 1; }
  if litellm_build; then echo "a failed build passed" >&2; return 1; fi
}
