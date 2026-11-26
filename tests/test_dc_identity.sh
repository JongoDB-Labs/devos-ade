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

# _dc_same LABEL ARG... — old_dc and dc with ARG...: docker given the same arguments and environment, the same status,
# and dc's own output (its warnings) the same
_dc_same() {
  local label="$1" ro=0 rn=0; shift
  DC_OUT="$TMP/dc-old"; : > "$DC_OUT"; unset _DC_PROJECT_WARNED; old_dc "$@" > "$TMP/dc-old.out" 2>&1 || ro=$?
  DC_OUT="$TMP/dc-new"; : > "$DC_OUT"; unset _DC_PROJECT_WARNED; dc "$@" > "$TMP/dc-new.out" 2>&1 || rn=$?
  [ "$ro" = "$rn" ] || { printf '%s: status %s, was %s\n' "$label" "$rn" "$ro" >&2; return 1; }
  [ -s "$TMP/dc-old" ] || { printf '%s: docker not called\n' "$label" >&2; return 1; }
  cmp -s "$TMP/dc-old.out" "$TMP/dc-new.out" || { printf '%s: dc says something else\n' "$label" >&2; diff "$TMP/dc-old.out" "$TMP/dc-new.out" | head -10 >&2; return 1; }
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
    # (some keys twice: the last line counts)
    _env "TERMINAL_ENABLED=false" "CODE_ENABLED=true" "LOCALGIT=off" "TERMINAL_ENABLED=$te" "TERMINAL_WORKSPACE=$tw" "TERMINAL_EGRESS=$eg" "CODE_ENABLED=$ce" "LOCALGIT=$lg" \
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
    # (a COMPOSE_PROJECT_NAME of the shell's own: dc warns that it is ignored)
    if [ $((i % 7)) = 3 ]; then export COMPOSE_PROJECT_NAME=shellproj; else unset COMPOSE_PROJECT_NAME; fi
    _dc_same "case $i" exec -T portal true || return 1
    [ $((i % 8)) != 0 ] || _dc_same "case $i, up" up -d --wait portal open-webui || return 1
  done
  unset COMPOSE_PROJECT_NAME
}

test_dc_gives_docker_the_same_in_a_utf8_locale() {
  # (non-ASCII letters and spaces in values: the old tr and awk read them by the locale's characters)
  local l
  l="$(locale -a 2>/dev/null | grep -ixE 'en_US\.utf-?8|c\.utf-?8' | head -1)"
  [ -n "$l" ] || { echo "no UTF-8 locale here: skipped" >&2; return 0; }
  mkdir -p "$STATE_DIR"
  local v
  for v in $'on\xc2\xa0' $'\xc3\xa9' $'O\xcc\x81n' $'h\xc3\xb4st' $'\xe3\x80\x80true' $'\xffon' $'\xc2\xa0off' $'Host\xe2\x80\x83'; do
    _env "TERMINAL_ENABLED=true" "TERMINAL_WORKSPACE=/w" "TERMINAL_EGRESS=$v" "CODE_ENABLED=$v" "PORTAL_HTTPS=$v" \
      "PORTAL_HOST=$v.localhost" "LOCALGIT_SSO_HEADER=X" "TERMINAL_AUTO_MODE=$v"
    LC_ALL="$l" _dc_same "locale $l, value [$v]" exec -T portal true || return 1
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
  local v l utf8
  utf8="$(locale -a 2>/dev/null | grep -ixE 'en_US\.utf-?8|c\.utf-?8' | head -1)"
  for l in C ${utf8:+"$utf8"}; do
  export LC_ALL="$l"
  for v in '' true TRUE ' True ' 't r u e' $'yes\n' 1 01 on ON On oN off OFF Off no NO No 0 false FaLsE ' f a l s e ' \
      host HOST ' h o s t ' Host internet x truex $'\ttrue\r' y nope 'tru e' $'o\vn' $'o\fn' '1 ' ' 0' 'on!' 'o-n' \
      $'on\xc2\xa0' $'\xe3\x80\x80true' $'\xffon' 'TRUE_' '_on' 'I' 'ON.'; do
    assert_eq "$(flag_on "$v" && echo y || echo n)" "$(old_flag_on "$v" && echo y || echo n)" || { echo "flag_on [$v]" >&2; return 1; }
    assert_eq "$(flag_off "$v" && echo y || echo n)" "$(old_flag_off "$v" && echo y || echo n)" || { echo "flag_off [$v]" >&2; return 1; }
    assert_eq "$(egress_mode "$v")" "$(old_egress_mode "$v")" || { echo "egress_mode [$v] ($l)" >&2; return 1; }
  done
  done
  unset LC_ALL
}

test_a_dc_call_runs_fewer_programs() {
  # (each flag read ran printf | tr | tr, and rt_os ran uname for every runtime, twice a call: about 250 ms a call on
  # Linux, and an update makes some 35)
  _env "TERMINAL_ENABLED=true" "TERMINAL_WORKSPACE=/w" "CODE_ENABLED=true" "LOCALGIT_SSO_HEADER=X" "REMOTE_MODE=tailscale"
  local calls="$TMP/calls"
  tr() { echo tr >> "$calls"; command tr "$@"; }
  uname() { echo uname >> "$calls"; case "${1:-}" in -s) echo Linux ;; *) command uname "$@" ;; esac; }
  awk() { echo awk >> "$calls"; command awk "$@"; }
  # (and since v0.68.9: uname once a call, not once each for the runtimes' profiles and GPUs; no cat for the runtimes'
  # users, no mkdir while the projects' folder is there)
  mkdir -p "$STATE_DIR/projects/public" "$STATE_DIR/runtimes/llamacpp"; echo 1000:1000 > "$STATE_DIR/runtimes/llamacpp/user"
  cat() { echo cat >> "$calls"; command cat "$@"; }
  mkdir() { echo mkdir >> "$calls"; command mkdir "$@"; }
  DC_OUT="$TMP/dc-new"; : > "$calls"; dc exec -T portal true
  assert_eq "$(grep -c '^tr$' "$calls")" 0
  assert_eq "$(grep -c '^uname$' "$calls")" 1
  assert_eq "$(grep -c '^cat$' "$calls")" 0
  assert_eq "$(grep -c '^mkdir$' "$calls")" 0
  grep -q '^BN_LLAMACPP_USER=1000:1000$' "$DC_OUT" || { echo "the runtime's user not given" >&2; return 1; }
  # (get_env: an awk each for the three reads before dc's .env snapshot, project_name's and localgit_sso_ensure's;
  # none after)
  assert_eq "$(grep -c '^awk$' "$calls")" 3
}

test_nothing_dc_calls_after_its_snapshot_writes_env() {
  # (a write there in a subshell would leave dc reading the old value: tests/dc_env_writers.py follows the calls)
  local out
  out="$(python3 "$T_ROOT/tests/dc_env_writers.py" --root "$T_ROOT" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
  # (and it does find one: a copy of lib/ whose localgit_ca_publish appends to .env)
  local r="$TMP/root"; mkdir -p "$r/lib"; cp "$T_ROOT"/lib/*.sh "$r/lib/"
  awk '{ print } /^localgit_ca_publish\(\) \{$/ { print "  printf %s X >> \"$ENV_FILE\"" }' "$T_ROOT/lib/common.sh" > "$r/lib/common.sh"
  ! out="$(python3 "$T_ROOT/tests/dc_env_writers.py" --root "$r" 2>&1)" || { echo "missed a write" >&2; return 1; }
  assert_contains "$out" "localgit_ca_publish"
}

test_the_snapshot_never_reaches_a_programs_environment() {
  _env "TERMINAL_ENABLED=true" "TERMINAL_WORKSPACE=/w" "LOCALGIT_SSO_HEADER=X" "A=1"
  # (an _ENVV_ variable this shell was given is not read as .env's, and goes)
  export _ENVV_NOPE=given _ENVV_A=given
  assert_eq "$(_dc_env_snap=1; _env_snap; get_env NOPE; get_env A)" 1
  assert_eq "$(_env_snap; env | grep -c '^_ENVV_' || true)" 0
  # (under set -a, nothing of the snapshot is exported: docker is given no _ENVV_ variable)
  DC_OUT="$TMP/dc-new"; : > "$DC_OUT"
  set -a; dc exec -T portal true; set +a
  [ -s "$DC_OUT" ]
  ! grep -q '_ENVV_' "$DC_OUT"
  assert_eq "$(set -a; _env_snap; env | grep -c '^_ENVV_' || true)" 0
  case $- in *a*) echo "set -a left on" >&2; return 1 ;; esac
}

test_ev_reads_as_get_env() {
  # (_ev VAR KEY is "$(get_env KEY)" without the subshell: in dc's snapshot and outside it, for the same keys as above)
  printf '\357\273\277BOM=1\nA=1\nB=x=y z\r\n# C=no\nexport D=1\n  E=1\nF-G=1\nA=2\nH=\nI= sp \n9J=1\nL=a\\tb\\c\nM=100%%s\nN=\tt\nK=last' > "$ENV_FILE"
  local k v snap
  for snap in 0 1; do
    for k in A B C D E F-G F G H I 9J K L M N BOM NOPE 'export D' '  E' '# C' '' 'A=' '=' v _ev_n; do
      assert_eq "$(_dc_env_snap=$snap; [ "$snap" = 0 ] || _env_snap; _ev v "$k"; printf '%s' "$v")" "$(get_env "$k")" || { echo "_ev [$k], snapshot $snap" >&2; return 1; }
    done
  done
  # (no .env: empty; one gone after the snapshot: empty, as get_env reads it)
  assert_eq "$(_dc_env_snap=1; _env_snap; rm -f "$ENV_FILE"; v=x; _ev v A; printf '%s' "$v")" ""
  rm -f "$ENV_FILE"; v=x; _ev v A; assert_eq "$v" ""
}

test_text_of_reads_as_cat() {
  # (_text_of VAR FILE DEFAULT is "$(cat FILE 2>/dev/null || echo DEFAULT)": the runtimes' users in dc)
  local d="$TMP/t" f want got
  mkdir -p "$d/dir"
  printf '1000:1000\n' > "$d/one"; printf '1000:1000' > "$d/nonl"; printf 'a\n\n\n' > "$d/nls"; printf 'a\nb\n' > "$d/two"
  printf '1000:1000\r\n' > "$d/crlf"; printf '  x  \n' > "$d/sp"; : > "$d/empty"; printf '\n' > "$d/nl"; printf 'a\\b %%s\n' > "$d/bs"
  ln -s "$d/one" "$d/link"; ln -s "$d/none" "$d/dangling"; printf 'x\n' > "$d/noread"; chmod 000 "$d/noread"
  for f in one nonl nls two crlf sp empty nl bs link dangling none dir noread; do
    [ "$f" != noread ] || [ "$(id -u)" != 0 ] || continue
    want="$(cat "$d/$f" 2>/dev/null || echo 65534:65534)"
    _text_of got "$d/$f" 65534:65534
    assert_eq "[$got]" "[$want]" || { echo "_text_of $f" >&2; chmod 644 "$d/noread"; return 1; }
  done
  chmod 644 "$d/noread"
}

test_the_runtime_and_mirror_checks_answer_as_before() {
  # (rt_installed without rt_dir's subshells; localgit_mirror_wanted with _ev: as the old forms, in dc's snapshot and not)
  local id m e h s old new
  STATE_DIR="$TMP/state with space"; mkdir -p "$STATE_DIR/runtimes/ollama" "$STATE_DIR/runtimes/vllm/installed" "$STATE_DIR/runtimes/lmstudio"
  echo 1 > "$STATE_DIR/runtimes/ollama/installed"; : > "$STATE_DIR/runtimes/lmstudio/installed"
  ln -s "$STATE_DIR/runtimes/ollama/installed" "$STATE_DIR/runtimes/x"
  for id in ollama vllm lmstudio llamacpp '' x '../runtimes/ollama' 'a b'; do
    old=0; [ -s "$(rt_dir "$id")/installed" ] || old=1
    new=0; rt_installed "$id" || new=1
    assert_eq "$new" "$old" || { echo "rt_installed [$id]" >&2; return 1; }
  done
  for m in '' on ' On' off x; do for e in '' true 'YES ' 0 off; do for h in '' github.com; do for s in 0 1; do
    _env "LOCALGIT=$m" "LOCALGIT_MIRROR_EGRESS=$e" "LOCALGIT_MIRROR_HOSTS=$h"
    old="$(old_localgit_on && flag_on "$(get_env LOCALGIT_MIRROR_EGRESS)" && [ -n "$(get_env LOCALGIT_MIRROR_HOSTS)" ]; echo $?)"
    new="$(_dc_env_snap=$s; [ "$s" = 0 ] || _env_snap; localgit_mirror_wanted; echo $?)"
    assert_eq "$new" "$old" || { echo "localgit_mirror_wanted [$m|$e|$h] snapshot $s" >&2; return 1; }
  done; done; done; done
}

test_get_env_reads_the_snapshot_as_it_reads_the_file() {
  # (CRLF, a key twice, comments, "export", leading spaces, other characters in keys, "=" and spaces and backslashes and
  # % in values, empty values, a byte-order mark, no newline at the end)
  printf '\357\273\277BOM=1\nA=1\nB=x=y z\r\n# C=no\nexport D=1\n  E=1\nF-G=1\nA=2\nH=\nI= sp \n9J=1\nL=a\\tb\\c\nM=100%%s\nN=\tt\nK=last' > "$ENV_FILE"
  local k want got
  for k in A B C D E F-G F G H I 9J K L M N BOM NOPE 'export D' '  E' '# C' '' 'A=' '='; do
    want="$(get_env "$k"; echo "x$?")"
    got="$(_dc_env_snap=1; _env_snap; get_env "$k"; echo "x$?")"
    assert_eq "$got" "$want" || { echo "get_env [$k]" >&2; return 1; }
  done
  assert_eq "$(_dc_env_snap=1; _env_snap; get_env A)" 2
  assert_eq "$(_dc_env_snap=1; _env_snap; get_env K)" last
}

test_the_snapshot_is_dropped_on_each_write_and_after_dc() {
  local _dc_env_snap=1
  printf 'A=1\nZ=1\n' > "$ENV_FILE"; _env_snap
  assert_eq "$(get_env A)" 1
  set_env A 2; assert_eq "$(get_env A)" 2
  _env_snap; unset_env A; assert_eq "$(get_env A)" ""
  _env_snap; set_env_batch A 3 B 4; assert_eq "$(get_env A)$(get_env B)" 34
  # (a key no longer in .env is not read from an older snapshot; another ENV_FILE is read from the file)
  printf 'Y=1\n' > "$ENV_FILE"; _env_snap; assert_eq "$(get_env Z)" ""
  local e="$ENV_FILE"; ENV_FILE="$TMP/other.env"; printf 'Y=other\n' > "$ENV_FILE"; assert_eq "$(get_env Y)" other; ENV_FILE="$e"
  # (no .env, or one not readable: no snapshot)
  rm -f "$ENV_FILE"; ! _env_snap; assert_eq "$(get_env Y)" ""
  _dc_env_snap=0
  # (after dc, get_env reads the file again)
  _env "TERMINAL_ENABLED=true" "LOCALGIT_SSO_HEADER=X" "A=1"; DC_OUT="$TMP/dc-new"; dc ps
  printf 'A=2\n' >> "$ENV_FILE"; assert_eq "$(get_env A)" 2
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
  # (a line too many, and a failing cksum whose lines are all there: one at a time too)
  cksum() { if [ $# -gt 1 ] && [ ! -e "$TMP/extra" ]; then : > "$TMP/extra"; command cksum "$@"; echo "1 1 x"; else command cksum "$@"; fi; }
  assert_eq "$(STACK_DIR="$s" config_sums off)" "$want"
  [ -e "$TMP/extra" ]
  cksum() { if [ $# -gt 1 ] && [ ! -e "$TMP/failed" ]; then : > "$TMP/failed"; command cksum "$@"; return 1; else command cksum "$@"; fi; }
  assert_eq "$(STACK_DIR="$s" config_sums off)" "$want"
  [ -e "$TMP/failed" ]
  unset -f cksum
  # (a newline in the checkout's path)
  s="$TMP/n"$'\n'"l"; mkdir -p "$s/caddy" "$s/terminal/managed"; printf 'c\n' > "$s/caddy/Caddyfile"; printf '{}\n' > "$s/terminal/managed/off.json"
  STACK_DIR="$s" _sums_same "a newline in the path" off || return 1
  ! STACK_DIR="$s" _config_sums_one_pass off > /dev/null
}

test_config_sums_run_two_cksums_not_two_a_file() {
  local calls="$TMP/calls"
  cksum() { echo cksum >> "$calls"; command cksum "$@"; }
  awk() { echo awk >> "$calls"; command awk "$@"; }
  : > "$calls"; config_sums off > /dev/null
  assert_eq "$(grep -c '^cksum$' "$calls")" 2
  assert_eq "$(grep -c '^awk$' "$calls")" 0
}
