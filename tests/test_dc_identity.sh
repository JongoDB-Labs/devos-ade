# shellcheck shell=bash
# shellcheck disable=SC2329,SC2034  # stubs are called by the code under test; the FAKE_* and _*_PROFILE are read there
# JON-972: dc (lib/common.sh) gives docker the very same arguments and environment as before, with fewer programs a
# call. tests/fixtures/dc_old.sh keeps dc and the helpers it called as they were (v0.68.6), as old_dc; each case runs
# both on the same .env, state and files, with docker stubbed to write down what it was given.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/runtimes.sh
. "$STACK_DIR/tests/fixtures/dc_old.sh"

docker() { { printf '%s\n' "$@"; printf -- '--- env\n'; env | LC_ALL=C grep -v '^_=' | LC_ALL=C sort; } > "$DC_OUT"; }
localgit_tls_ensure() { [ "${FAKE_TLS:-1}" = 1 ]; }
uname() { case "${1:-}" in -s) echo "${FAKE_OS:-Linux}" ;; *) command uname "$@" ;; esac; }
rt_vllm_serving() { [ "${FAKE_VLLM:-0}" = 1 ] && echo some/model; }

# _dc_same LABEL ARG... — old_dc and dc with ARG...: docker given the same arguments and environment, the same status
_dc_same() {
  local label="$1" ro=0 rn=0; shift
  DC_OUT="$TMP/dc-old"; : > "$DC_OUT"; old_dc "$@" || ro=$?
  DC_OUT="$TMP/dc-new"; : > "$DC_OUT"; dc "$@" || rn=$?
  [ "$ro" = "$rn" ] || { printf '%s: status %s, was %s\n' "$label" "$rn" "$ro" >&2; return 1; }
  [ -s "$TMP/dc-old" ] || { printf '%s: docker not called\n' "$label" >&2; return 1; }
  cmp -s "$TMP/dc-old" "$TMP/dc-new" && return 0
  printf '%s: docker is given something else\n' "$label" >&2; diff "$TMP/dc-old" "$TMP/dc-new" | head -20 >&2
  return 1
}

# _env K=V... — .env with just these lines
_env() { : > "$ENV_FILE"; local kv; for kv in "$@"; do printf '%s\n' "$kv" >> "$ENV_FILE"; done; }

_pick() { local i="$1"; shift; local -a v=("$@"); printf '%s' "${v[$((i % ${#v[@]}))]}"; }

test_dc_gives_docker_the_same_for_many_settings() {
  local i te tw eg ce lg rm stt ws https tam cam ph pd prj os
  mkdir -p "$STATE_DIR/runtimes/ollama" "$STATE_DIR/runtimes/vllm" "$STATE_DIR/runtimes/llamacpp"
  for i in $(seq 0 47); do
    te="$(_pick "$i" '' true ' On ' no TRUE)"; tw="$(_pick $((i / 5)) /w '')"
    eg="$(_pick $((i * 7)) '' host ' HOST' off internet x No)"; ce="$(_pick $((i * 3)) '' yes OFF 1 ' y e s ')"
    lg="$(_pick $((i * 11)) '' off 'Off ' on false)"; rm="$(_pick $((i * 5)) '' tailscale domain)"
    stt="$(_pick $((i * 13)) '' bedrock)"; ws="$(_pick $((i * 17)) '' off ' OFF' on)"; https="$(_pick $((i * 19)) '' true 'TRUE ' 0)"
    tam="$(_pick $((i * 23)) '' on Yes)"; cam="$(_pick $((i * 29)) '' 1 off)"
    ph="$(_pick $((i * 31)) '' bedrock-now.localhost x.bedrock-now.localhost devos.localhost)"
    pd="$(_pick $((i * 37)) '' bedrock-now-preview.localhost p.example.test)"; prj="$(_pick $((i * 41)) '' myproj)"
    _env "TERMINAL_ENABLED=$te" "TERMINAL_WORKSPACE=$tw" "TERMINAL_EGRESS=$eg" "CODE_ENABLED=$ce" "LOCALGIT=$lg" \
      "REMOTE_MODE=$rm" "STT_PROVIDER=$stt" "WEBSEARCH_SEARXNG_BUILTIN=$ws" "PORTAL_HTTPS=$https" "TERMINAL_AUTO_MODE=$tam" \
      "CODE_AUTO_MODE=$cam" "PORTAL_HOST=$ph" "PREVIEW_DOMAIN=$pd" "COMPOSE_PROJECT_NAME=$prj" "LOCALGIT_SSO_HEADER=X-H-$i"
    FAKE_OS="$(_pick "$i" Linux Darwin Linux)"; FAKE_TLS="$(_pick $((i / 3)) 1 0)"; FAKE_VLLM="$(_pick $((i / 2)) 0 1)"
    REMOTE_DEGRADED="$(_pick $((i / 7)) 0 1)"; _RT_PROFILE="$(_pick $((i / 4)) '' vllm llamacpp)"
    _STT_PROFILE="$(_pick $((i / 6)) '' 1)"; _WS_SEARXNG_PROFILE="$(_pick $((i / 8)) '' 1)"; _LG_PROFILE="$(_pick $((i / 9)) '' 1)"
    # (the runtimes installed, a GPU, the projects' compose file, the portal's certificate: on and off as i goes)
    if [ $((i % 3)) = 0 ]; then echo 0.1 > "$STATE_DIR/runtimes/ollama/installed"; else rm -f "$STATE_DIR/runtimes/ollama/installed"; fi
    if [ $((i % 4)) = 1 ]; then echo 0.2 > "$STATE_DIR/runtimes/vllm/installed"; echo nvidia > "$STATE_DIR/runtimes/vllm/gpu"; else rm -f "$STATE_DIR/runtimes/vllm/installed"; fi
    if [ $((i % 5)) = 2 ]; then echo 0.3 > "$STATE_DIR/runtimes/llamacpp/installed"; echo 1000:1000 > "$STATE_DIR/runtimes/llamacpp/user"; else rm -f "$STATE_DIR/runtimes/llamacpp/installed"; fi
    if [ $((i % 2)) = 0 ]; then mkdir -p "$STATE_DIR/projects"; : > "$STATE_DIR/projects/compose.yaml"; else rm -f "$STATE_DIR/projects/compose.yaml"; fi
    if [ $((i % 6)) = 3 ]; then mkdir -p "$STATE_DIR/tls/serve"; echo "pem $i" > "$STATE_DIR/tls/serve/site.pem"; else rm -f "$STATE_DIR/tls/serve/site.pem"; fi
    DEVOS_ADE_COMPOSE_CONTEXTS="$(_pick $((i / 10)) 0 1)"
    _dc_same "case $i" exec -T portal true || return 1
    [ $((i % 8)) != 0 ] || _dc_same "case $i, up" up -d --wait portal open-webui || return 1
  done
}

test_dc_gives_docker_the_same_without_a_localgit_header_yet() {
  # (localgit_sso_ensure makes one on old_dc's call; dc then finds it, as a second call of the old one would)
  _env "LOCALGIT=" "TERMINAL_ENABLED=true" "TERMINAL_WORKSPACE=/w"
  _dc_same "a new header" config --services || return 1
  [ -n "$(get_env LOCALGIT_SSO_HEADER)" ]
  _env "LOCALGIT=off"
  _dc_same "no git server" config --services || return 1
  assert_eq "$(get_env LOCALGIT_SSO_HEADER)" ""
}

test_dc_gives_docker_the_same_for_other_config_files() {
  # config_sums: another checkout's caddy/, litellm/, searxng/ and terminal/managed/ files, some missing or unreadable
  local s="$TMP/stack"
  mkdir -p "$s/caddy" "$s/litellm" "$s/searxng" "$s/terminal/managed" "$STATE_DIR"
  printf 'c\n' > "$s/caddy/Caddyfile"; printf 'a\n' > "$s/caddy/a b.caddy"; printf 'g\n' > "$s/caddy/terminal-gateway.caddy"
  printf 'o\n' > "$s/caddy/ollama-gate.caddy"; printf 'l\n' > "$s/litellm/config.yaml"; printf 's\n' > "$s/searxng/settings.yml"
  printf '{}\n' > "$s/terminal/managed/off.json"; printf '{"a":1}\n' > "$s/terminal/managed/chat.json"
  _env "TERMINAL_ENABLED=true" "TERMINAL_WORKSPACE=/w" "LOCALGIT_SSO_HEADER=X"
  STACK_DIR="$s" _dc_same "another checkout" ps || return 1
  printf 'h\n' > "$s/litellm/bn_hooks.py"; printf '%s other\n' "$(cd "$s/litellm" && cksum config.yaml bn_hooks.py | cksum | awk '{ print $1 "-" $2 }')" > "$STATE_DIR/litellm-live.sum"
  STACK_DIR="$s" _dc_same "the live LiteLLM sum" ps || return 1
  rm -f "$s/caddy/Caddyfile" "$s/searxng/settings.yml"; printf 'on\n' > "$s/caddy/localgit-gateway-on.caddy"
  STACK_DIR="$s" _dc_same "files gone, one more" ps || return 1
  _env "TERMINAL_AUTO_MODE=on" "LOCALGIT_SSO_HEADER=X"; printf '{"on":1}\n' > "$s/terminal/managed/on.json"
  STACK_DIR="$s" _dc_same "the auto-mode policy" ps || return 1
  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$s/caddy/a b.caddy" "$s/litellm/config.yaml"
    STACK_DIR="$s" _dc_same "unreadable files" ps || { chmod 644 "$s/caddy/a b.caddy" "$s/litellm/config.yaml"; return 1; }
    chmod 644 "$s/caddy/a b.caddy" "$s/litellm/config.yaml"
  fi
}

test_the_flag_readers_read_as_before() {
  local v
  for v in '' true TRUE ' True ' 't r u e' $'yes\n' 1 01 on ON On oN off OFF Off no NO No 0 false FaLsE ' f a l s e ' \
      host HOST ' h o s t ' Host internet x truex $'\ttrue\r' y nope 'tru e' $'o\vn' $'o\fn' '1 ' ' 0'; do
    assert_eq "$(flag_on "$v" && echo y || echo n)" "$(old_flag_on "$v" && echo y || echo n)" || { echo "flag_on [$v]" >&2; return 1; }
    assert_eq "$(flag_off "$v" && echo y || echo n)" "$(old_flag_off "$v" && echo y || echo n)" || { echo "flag_off [$v]" >&2; return 1; }
    assert_eq "$(egress_mode "$v")" "$(old_egress_mode "$v")" || { echo "egress_mode [$v]" >&2; return 1; }
  done
}

test_a_dc_call_runs_fewer_programs() {
  # (each flag read ran printf | tr | tr, and rt_os ran uname for every runtime, twice a call: about 250 ms a call on
  # Linux, and an update makes some 35)
  _env "TERMINAL_ENABLED=true" "TERMINAL_WORKSPACE=/w" "CODE_ENABLED=true" "LOCALGIT_SSO_HEADER=X" "REMOTE_MODE=tailscale"
  local calls="$TMP/calls"
  tr() { echo tr >> "$calls"; command tr "$@"; }
  uname() { echo uname >> "$calls"; case "${1:-}" in -s) echo Linux ;; *) command uname "$@" ;; esac; }
  DC_OUT="$TMP/dc-new"; : > "$calls"; dc exec -T portal true
  assert_eq "$(grep -c '^tr$' "$calls")" 0
  [ "$(grep -c '^uname$' "$calls")" -le 2 ]
}

# _sums_same LABEL [POLICY] — config_sums and old_config_sums: the same lines, the same status
_sums_same() {
  local o n ro=0 rn=0
  o="$(old_config_sums "${2:-}" 2>/dev/null)" || ro=$?
  n="$(config_sums "${2:-}" 2>/dev/null)" || rn=$?
  [ "$o" = "$n" ] && [ "$ro" = "$rn" ] && return 0
  printf '%s: config_sums gives other sums (status %s, was %s)\n' "$1" "$rn" "$ro" >&2; diff <(printf '%s\n' "$o") <(printf '%s\n' "$n") >&2
  return 1
}

test_config_sums_give_the_same_sums_in_one_pass() {
  local p s
  for p in '' off on code-auto; do _sums_same "this checkout, policy [$p]" "$p" || return 1; done
  # (another checkout: spaces in its path and its names, every line's files there, then some gone, none of the imports)
  s="$TMP/st ack"; mkdir -p "$s/caddy" "$s/litellm" "$s/searxng" "$s/terminal/managed" "$STATE_DIR/tls/serve"
  printf 'c\n' > "$s/caddy/Caddyfile"; printf 'a\n' > "$s/caddy/a b.caddy"
  printf 'g\n' > "$s/caddy/terminal-gateway.caddy"; printf 'off\n' > "$s/caddy/localgit-gateway-off.caddy"
  printf 'o\n' > "$s/caddy/ollama-gate.caddy"; printf 'l\n' > "$s/litellm/config.yaml"; printf 'h\n' > "$s/litellm/bn_hooks.py"
  printf 's\n' > "$s/searxng/settings.yml"; printf '{}\n' > "$s/terminal/managed/off.json"; printf '{"c":1}\n' > "$s/terminal/managed/chat.json"
  printf 'pem\n' > "$STATE_DIR/tls/serve/site.pem"
  STACK_DIR="$s" _sums_same "every file there" off || return 1
  STACK_DIR="$s" _config_sums_one_pass off > /dev/null   # (in one pass)
  # (LiteLLM's config given live: its line keeps the base the container started with)
  printf '%s base-1\n' "$(files_sum "$s/litellm" config.yaml bn_hooks.py)" > "$STATE_DIR/litellm-live.sum"
  STACK_DIR="$s" _sums_same "LiteLLM's config given live" off || return 1
  assert_contains "$(STACK_DIR="$s" config_sums off)" "BN_LITELLM_CONFIG_SUM=base-1"
  rm -f "$s/caddy/"*.caddy "$s/litellm/bn_hooks.py" "$STATE_DIR/tls/serve/site.pem" "$s/searxng/settings.yml"
  STACK_DIR="$s" _sums_same "some gone, no imports" on || return 1
  rm -f "$s/caddy/Caddyfile" "$s/litellm/config.yaml" "$s/terminal/managed/"*.json
  STACK_DIR="$s" _sums_same "none there" off || return 1
  assert_eq "$(STACK_DIR="$s" config_sums off | grep -c '=$')" 8
  # (where one pass could not be sure, config_sums takes them one at a time: a name that starts with "-", a backslash
  # in the path, a file not readable, one gone between the look and the cksum)
  printf 'c\n' > "$s/caddy/Caddyfile"; printf 'z\n' > "$s/caddy/-z.caddy"
  STACK_DIR="$s" _sums_same "a name that starts with -" || return 1
  ! STACK_DIR="$s" _config_sums_one_pass off > /dev/null
  rm -f "$s/caddy/-z.caddy"
  s="$TMP/b\\s"; mkdir -p "$s/caddy" "$s/terminal/managed"; printf 'c\n' > "$s/caddy/Caddyfile"; printf '{}\n' > "$s/terminal/managed/chat.json"
  STACK_DIR="$s" _sums_same "a backslash in the path" || return 1
  ! STACK_DIR="$s" _config_sums_one_pass off > /dev/null
  s="$TMP/st ack"; printf 'c\n' > "$s/caddy/Caddyfile"; printf 's\n' > "$s/searxng/settings.yml"; printf '{}\n' > "$s/terminal/managed/chat.json"
  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$s/searxng/settings.yml"
    STACK_DIR="$s" _sums_same "a file not readable" || { chmod 644 "$s/searxng/settings.yml"; return 1; }
    ! STACK_DIR="$s" _config_sums_one_pass off > /dev/null 2>&1 || { chmod 644 "$s/searxng/settings.yml"; return 1; }
    chmod 644 "$s/searxng/settings.yml"
  fi
  local want; want="$(STACK_DIR="$s" old_config_sums off)"
  cksum() { if [ $# -gt 1 ] && [ ! -e "$TMP/dropped" ]; then : > "$TMP/dropped"; command cksum "$@" | sed '$d'; else command cksum "$@"; fi; }
  assert_eq "$(STACK_DIR="$s" config_sums off)" "$want"
  [ -e "$TMP/dropped" ]
  unset -f cksum
}

test_config_sums_run_two_cksums_not_two_a_file() {
  local calls="$TMP/calls"
  cksum() { echo cksum >> "$calls"; command cksum "$@"; }
  awk() { echo awk >> "$calls"; command awk "$@"; }
  : > "$calls"; config_sums off > /dev/null
  assert_eq "$(grep -c '^cksum$' "$calls")" 2
  assert_eq "$(grep -c '^awk$' "$calls")" 0
}
