# shellcheck shell=bash
# shellcheck disable=SC2016,SC2329  # literal $ in expected output; stubs are called by the code under test
# LM Studio as a runtime DevOS ADE installs and runs (lib/runtimes.sh, JON-829) and its downloads (lib/local_models.sh):
# the pins; where it does not run (Linux, an Intel Mac); on an Apple-silicon Mac the pinned archive downloaded (a
# stand-in curl serves it: lmstudio.ai's server refuses HEAD and cannot continue a download), checked against its SHA-512,
# unpacked (links inside its own tree only) and installed by its own bootstrap (a stand-in llmster) into the stack's
# folder, then run as a launchd agent (a stand-in launchctl) by lib/lmstudio-agent.sh; a GGUF download for real
# (lib/hf_fetch.py and curl, against the stand-in Hub on 127.0.0.1) handed to LM Studio by link (a stand-in lms) and
# registered with the model gateway by the key LM Studio gave it; Remove. Nothing here reaches launchd or the network.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/local_models.sh and lib/runtimes.sh

SHA_A="$(printf 'a%.0s' $(seq 40))"
VER=0.0.25-1

_ls_env() {
  mkdir -p "$STATE_DIR/status" "$STATE_DIR/requests" "$STATE_DIR/helper" "$TMP/bin" "$TMP/pkg/.bundle/bin" "$TMP/pkg/.bundle/lib"
  printf 'X=1\nLOCAL_RUNTIME=lmstudio\n' > "$ENV_FILE"
  export RT_POLL_S=0.1 RT_START_WAIT=5 LOCAL_POLL_S=0.1 ASSUME_YES=1 PATH="$TMP/bin:$PATH"
  FAKE_OS=Darwin; FAKE_ARCH=arm64
  uname() { case "${1:-}" in -s) echo "$FAKE_OS" ;; -m) echo "$FAKE_ARCH" ;; *) command uname "$@" ;; esac; }
  # launchd: LM Studio's agent is loaded from bootstrap to bootout (TMP/ls-loaded)
  launchctl() {
    printf '%s\n' "$*" >> "$TMP/launchctl.args"
    case "$1" in
      print) case "$2" in *.lmstudio.*) [ -f "$TMP/ls-loaded" ] || return 113 ;; *) return 113 ;; esac
        printf '%s = {\n\tstate = running\n\truns = 1\n\tlast exit code = (never exited)\n\tpid = 4545\n}\n' "$2" ;;
      bootstrap) [ -f "$3" ] || return 5; case "$3" in *.lmstudio.*) : > "$TMP/ls-loaded" ;; esac ;;
      bootout) case "$2" in *.lmstudio.*) rm -f "$TMP/ls-loaded" ;; esac ;;
    esac
  }
  # curl: lmstudio.ai's archive (HEAD refused: no size; a range answered from the start, so curl -C - ends with 33 when
  # TMP/no-range says so), the LM Studio that answers while its agent is loaded (/v1/models, /api/v0/models from
  # TMP/ls-models.json), and the stand-in Hub on its own port (the real curl)
  cat > "$TMP/bin/curl" <<EOF
#!/bin/sh
T="$TMP"; out=''; url=''; head=0; prev=''; w=''; cont=0
printf '%s\n' "\$*" >> "\$T/curl.args"
for a in "\$@"; do
  [ "\$prev" = -o ] && out="\$a"; [ "\$prev" = -w ] && w="\$a"; [ "\$prev" = -C ] && cont=1
  case "\$a" in -sSIL) head=1 ;; http://* | https://*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  http://127.0.0.1:9/v1/models) if [ -f "\$T/ls-loaded" ]; then if [ -n "\$w" ]; then printf 200; else printf '{"data":[]}'; fi; exit 0; fi; [ -z "\$w" ] || printf 000; exit 7 ;;
  http://127.0.0.1:9/api/v0/models) [ -f "\$T/ls-loaded" ] || exit 7; cat "\$T/ls-models.json" 2>/dev/null || printf '{"data":[]}' ;;
  https://llmster.lmstudio.ai/download/*)
    if [ "\$head" = 1 ]; then printf 'HTTP/2 405\r\nallow: GET\r\n\r\n'; exit 0; fi
    if [ "\$cont" = 1 ] && [ -s "\$out" ] && [ -f "\$T/no-range" ]; then exit 33; fi
    cat "\$T/llmster.tgz" > "\$out" ;;
  http://127.0.0.1:*) exec "${BN_REAL_CURL:?}" "\$@" ;;
  *) exit 6 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  # lms: import links a file into its models folder (TMP/import-noop: it takes nothing); ls --json lists each with the
  # key LM Studio gives it and its path (TMP/ls-nopath: the key only; TMP/ls-extra: a model of another folder too)
  cat > "$TMP/lms-src" <<EOF
#!/bin/sh
T="$TMP"
printf '%s|HOME=%s|INFO=%s\n' "\$*" "\$HOME" "\${LMS_API_SERVER_INFO_PATH:-}" >> "\$T/lms.args"
case "\$1" in
  import) [ ! -f "\$T/import-noop" ] || exit 0
    mkdir -p "\$HOME/.lmstudio/models/\$4" && ln -sf "\$2" "\$HOME/.lmstudio/models/\$4/\${2##*/}" ;;
  ls) printf '['; sep=''
    for x in "\$HOME"/.lmstudio/models/*/*/*; do
      [ -L "\$x" ] || continue
      b="\${x##*/}"; k="\$(printf '%s' "\${b%.gguf}" | tr 'A-Z' 'a-z')"
      if [ -f "\$T/ls-nopath" ]; then printf '%s{"modelKey":"%s"}' "\$sep" "\$k"
      else printf '%s{"type":"llm","modelKey":"%s","path":"%s"}' "\$sep" "\$k" "\${x#"\$HOME"/.lmstudio/models/}"; fi
      sep=,
    done
    [ ! -f "\$T/ls-extra" ] || printf '%s{"modelKey":"other-model","path":"x/y/other.gguf"}' "\$sep"
    printf ']\n' ;;
  server) [ ! -f "\$T/server-fails" ] || exit 1 ;;
esac
EOF
  chmod +x "$TMP/lms-src"
  # the archive: llmster (bootstrap: lms, and llmster where its installer records it; TMP/boot-fails: it stops;
  # TMP/boot-no-lms, TMP/boot-no-record: it leaves that out; TMP/boot-in-place: it records itself where it was unpacked)
  # and its bundle, with a link that goes up and back into it (as LM Studio's do)
  cat > "$TMP/pkg/llmster" <<EOF
#!/bin/sh
T="$TMP"
printf '%s|HOME=%s|BOOT=%s|NOUPD=%s|PWD=%s\n' "\$*" "\$HOME" "\${LMS_BOOTSTRAP_INSTALL_SH:-}" "\${LMS_DAEMON_DISABLE_UPDATES:-}" "\$(pwd)" >> "\$T/llmster.args"
case "\${1:-}" in
  bootstrap) [ ! -f "\$T/boot-fails" ] || { echo "bootstrap: no space left on device" >&2; exit 1; }
    h="\$HOME/.lmstudio"; v="\$h/llmster/$VER"
    mkdir -p "\$h/bin" "\$h/.internal" "\$v" && cp "\$0" "\$v/llmster" && chmod +x "\$v/llmster"
    [ -f "\$T/boot-no-lms" ] || { cp "\$T/lms-src" "\$h/bin/lms" && chmod +x "\$h/bin/lms"; }
    [ ! -f "\$T/boot-in-place" ] || v="\$(pwd)"
    [ -f "\$T/boot-no-record" ] || printf '{"path":"%s","argv":["%s","."],"cwd":"%s"}' "\$v/llmster" "\$v/llmster" "\$v" > "\$h/.internal/llmster-install-location.json"
    echo "(node:4242) [DEP0040] DeprecationWarning: The punycode module is deprecated." >&2 ;;
  *) exec sleep 20 ;;
esac
EOF
  chmod +x "$TMP/pkg/llmster"
  printf 'node' > "$TMP/pkg/.bundle/bin/node"; ln -sf ../bin/node "$TMP/pkg/.bundle/lib/node"
  tar -czf "$TMP/llmster.tgz" -C "$TMP/pkg" llmster .bundle
  _rt_sha512 "$TMP/llmster.tgz" > "$TMP/sha"
  rt_pin() { case "$1" in LMSTUDIO_VERSION) echo "$VER" ;; LMSTUDIO_SHA512_MACOS_ARM64) cat "$TMP/sha" ;; LMSTUDIO_BYTES_MACOS_ARM64) wc -c < "$TMP/llmster.tgz" | tr -d ' ' ;;
    OLLAMA_VERSION) echo 0.40.11 ;; LLAMACPP_VERSION) echo 0.8.0 ;; esac; }
  config_apply() { printf '%s|%s|%s\n' "$*" "$CFG_ORDER" "$(cfg_new LOCAL_MODELS)" >> "$TMP/apply"; }   # (what it would write)
  local_dmr_state() { echo not-installed; }   # (no Docker here)
}
_job() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(rt_job_file)" "$1"; }
_events() { cut -f2- "$(rt_events_file)" 2>/dev/null | tr '\t' ' '; }
_wait_for() { local n=0; until eval "$1"; do sleep 0.1; n=$((n + 1)); [ "$n" -lt 150 ] || { echo "timed out waiting for: $1" >&2; return 1; }; done; }

# The stand-in Hub with a GGUF repo, org/M-GGUF at SHA_A: Q4_K_M, a look-alike beside it, and a README
_ls_hub() {
  mkdir -p "$TMP/hub-files"; rm -f "$TMP/hub.port" "$TMP/hub.log"
  head -c 200000 /dev/urandom > "$TMP/hub-files/M-Q4_K_M.gguf"
  head -c 3000 /dev/urandom > "$TMP/hub-files/M-Q4_K_M_L.gguf"; head -c 300 /dev/urandom > "$TMP/hub-files/README.md"
  python3 -I -c '
import hashlib, json, os, sys
root, sha = sys.argv[1], sys.argv[2]
sib = []
for n in ["README.md", "M-Q4_K_M.gguf", "M-Q4_K_M_L.gguf"]:
    b = open(os.path.join(root, n), "rb").read()
    e = {"rfilename": n, "size": len(b), "blobId": hashlib.sha1(b"blob %d\0" % len(b) + b).hexdigest()}
    if n.endswith(".gguf"):
        e["lfs"] = {"sha256": hashlib.sha256(b).hexdigest(), "size": len(b), "pointerSize": 134}
    sib.append(e)
json.dump({"id": "org/M-GGUF", "sha": sha, "siblings": sib}, open(os.path.join(root, ".api.json"), "w"))' "$TMP/hub-files" "$SHA_A"
  python3 -I "$STACK_DIR/tests/fixtures/hf_hub_server.py" "$TMP/hub-files" "$TMP/hub.port" "$TMP/hub.log" </dev/null >/dev/null 2>&1 &
  HUB_PID=$!
  _wait_for '[ -s "$TMP/hub.port" ]'
  export HF_ENDPOINT="http://127.0.0.1:$(cat "$TMP/hub.port")"
}

# --- the pins, and where it does not run ---

test_the_pins_are_a_version_a_sha512_and_a_size_bumped_by_hand() {
  local v s b
  v="$(sed -n 's/^ARG LMSTUDIO_VERSION=//p' "$STACK_DIR/catalog/runtimes.pins")"
  s="$(sed -n 's/^ARG LMSTUDIO_SHA512_MACOS_ARM64=//p' "$STACK_DIR/catalog/runtimes.pins")"
  b="$(sed -n 's/^ARG LMSTUDIO_BYTES_MACOS_ARM64=//p' "$STACK_DIR/catalog/runtimes.pins")"
  [[ $v =~ ^[0-9]+(\.[0-9]+){1,3}(-[0-9]+)?$ ]] && [[ $s =~ ^[0-9a-f]{128}$ ]] && [[ $b =~ ^[0-9]+$ ]] && [ "$b" -gt 100000000 ]
  assert_eq "$(rt_pinned_version lmstudio)" "$v"
  assert_contains "$(cat "$STACK_DIR/bin/bump-core-services")" "LM Studio (LMSTUDIO_*)"
}

test_where_it_does_not_run_it_says_why_and_nothing_is_installed() {
  _ls_env
  FAKE_ARCH=x86_64
  assert_eq "$(rt_why_not lmstudio)" "LM Studio has no build for Intel Macs"
  assert_eq "$(rt_state lmstudio)" unsupported
  ( rt_install lmstudio ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "LM Studio does not run here: LM Studio has no build for Intel Macs"
  FAKE_OS=Linux; FAKE_ARCH=x86_64
  assert_eq "$(rt_why_not lmstudio)" "DevOS ADE runs LM Studio on Apple-silicon Macs (here, llama.cpp and Ollama serve the same models)"
  assert_eq "$(rt_state lmstudio)" unsupported
  assert_eq "$(rt_kind lmstudio)" none
  assert_eq "$(rt_kind llamacpp)" container
  ( rt_install lmstudio ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "LM Studio does not run here: DevOS ADE runs LM Studio on Apple-silicon Macs"
  [ ! -e "$(rt_dir lmstudio)/home" ]
  assert_not_contains "$(cat "$TMP/curl.args" 2>/dev/null)" lmstudio.ai
}

# --- install ---

test_install_downloads_the_pinned_archive_checks_its_sha512_and_its_own_installer_puts_it_in_the_stacks_folder() {
  _ls_env
  assert_eq "$(rt_state lmstudio)" not-installed
  rt_install lmstudio > "$TMP/out" 2>&1 || { cat "$TMP/out" "$(rt_dir lmstudio)/install.log" >&2; return 1; }
  assert_eq "$(rt_state lmstudio)" running
  assert_eq "$(rt_installed_version lmstudio)" "$VER"
  local d h; d="$(rt_dir lmstudio)"; h="$d/home/.lmstudio"
  assert_contains "$(cat "$TMP/curl.args")" "--proto =https --proto-redir =https"
  assert_contains "$(cat "$TMP/curl.args")" "https://llmster.lmstudio.ai/download/$VER-darwin-arm64.full.tar.gz"
  # its installer: run from the unpacked archive with the stack's HOME and its updates off; what it started, stopped
  assert_contains "$(cat "$TMP/llmster.args")" "bootstrap|HOME=$d/home|BOOT=1|NOUPD=1|PWD=$d/pkg"
  assert_contains "$(cat "$TMP/lms.args")" "daemon down|HOME=$d/home|INFO=$h/.internal/http-server.json"
  [ -x "$h/bin/lms" ] && [ ! -e "$d/pkg" ] && [ -z "$(find "$d" -maxdepth 1 -name '*.part')" ] && [ ! -e "$d/install.log" ]
  [ ! -e "$HOME/.lmstudio" ]   # (yours, the LM Studio app's: never touched)
  assert_eq "$(perm_of "$d/home")" 700
  # where llmster is, for its agent: resolved, in the stack's folder; and the python3 its gate runs on
  assert_eq "$(cat "$d/llmster.run")" "$(printf '%s\t%s\t.\t%s' "$(cd "$h/llmster/$VER" && pwd -P)/llmster" "$(cd "$h/llmster/$VER" && pwd -P)" "$(command -v python3)")"
  assert_eq "$(perm_of "$d/llmster.run")" 600
  # its gate's key: 32 random bytes in hex, in a folder of its own; ./stack's own looks send it from a header file
  local k; k="$(cat "$d/etc/api-key")"; [[ $k =~ ^[0-9a-f]{64}$ ]]
  assert_eq "$(perm_of "$d/etc")" 700
  assert_eq "$(perm_of "$d/etc/api-key")" 600
  assert_eq "$(perm_of "$d/etc/auth.hdr")" 600
  assert_eq "$(rt_api_key lmstudio)" "$k"
  assert_contains "$(cat "$TMP/curl.args")" "-H @$d/etc/auth.hdr http://127.0.0.1:9/v1/models"
  assert_not_contains "$(cat "$TMP/curl.args")" "$k"
  # the agent: this stack's label, lib/lmstudio-agent.sh on 11439, the stack's HOME, its updates off
  local p x; p="$(rt_plist lmstudio)"; x="$(cat "$p")"
  assert_contains "$p" "$HOME/Library/LaunchAgents/dev.devos.ade.lmstudio."
  assert_contains "$x" "<string>/bin/bash</string><string>$STACK_DIR/lib/lmstudio-agent.sh</string><string>11439</string><string>$d/llmster.run</string><string>$d/etc/api-key</string>"
  assert_not_contains "$x" "$k"
  assert_contains "$x" "<key>HOME</key><string>$d/home</string><key>LMS_DAEMON_DISABLE_UPDATES</key><string>1</string>"
  ! command -v plutil >/dev/null 2>&1 || plutil -lint "$p" >/dev/null
  # the job, the event, the portal's file (its row third)
  assert_eq "$(_job state)" done
  assert_eq "$(_events)" "lmstudio installed LM Studio $VER was installed and runs on 127.0.0.1:11439"
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d["runtimes"][2]
assert (r["id"], r["name"], r["state"], r["managed"], r["kind"], r["version"], r["pinned"], r["address"], r["why_not"]) == ("lmstudio", "LM Studio", "running", True, "agent", sys.argv[2], sys.argv[2], "127.0.0.1:11439", ""), r' "$(rt_status_file)" "$VER"
  assert_contains "$(cmd_runtimes status)" "LM Studio   running $VER on 127.0.0.1:11439 (launchd agent)"
  # the models it has loaded (no size: it does not say one)
  printf '{"data":[{"id":"m-q4_k_m","state":"loaded"},{"id":"n","state":"not-loaded"}]}' > "$TMP/ls-models.json"
  assert_eq "$(_rt_ps lmstudio)" "$(printf 'm-q4_k_m\t0\t0')"
  assert_contains "$(cat "$TMP/curl.args")" "-H @$d/etc/auth.hdr http://127.0.0.1:9/api/v0/models"
  # again: the same key (the model gateway's config keeps working)
  ( rt_install lmstudio ) > /dev/null 2>&1
  assert_eq "$(cat "$d/etc/api-key")" "$k"
  # stop and start: the agent goes and comes back
  rt_stop lmstudio > /dev/null 2>&1; assert_eq "$(rt_state lmstudio)" stopped
  rt_start lmstudio > /dev/null 2>&1; assert_eq "$(rt_state lmstudio)" running
  # Uninstall: all of it
  rt_uninstall lmstudio > /dev/null 2>&1
  [ ! -e "$d" ] && [ ! -e "$p" ]
  assert_eq "$(rt_state lmstudio)" not-installed
}

test_a_server_that_cannot_continue_a_download_gets_one_more_from_the_start_and_the_size_is_the_pinned_one() {
  _ls_env
  local d; d="$(rt_dir lmstudio)"; mkdir -p "$d"
  printf 'what an earlier one left' > "$d/llmster-$VER-darwin-arm64.tar.gz.part"
  : > "$TMP/no-range"
  rt_install lmstudio > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_eq "$(rt_state lmstudio)" running
  assert_eq "$(grep -c -- "-o $d/llmster-$VER-darwin-arm64.tar.gz.part https://llmster.lmstudio.ai/" "$TMP/curl.args")" 2
  # its size: not said by the server (HEAD refused), so the pinned one
  local n; n="$(wc -c < "$TMP/llmster.tgz" | tr -d ' ')"
  rm -f "$d/x.part"; _RT_TOTAL=''
  _rt_download lmstudio "LM Studio $VER" "https://llmster.lmstudio.ai/download/$VER-darwin-arm64.full.tar.gz" "$(cat "$TMP/sha")" "$d/x.part" lmstudio.ai "$n"
  assert_eq "$_RT_TOTAL" "$n"
}

test_an_archive_that_does_not_match_its_sha512_or_whose_installer_fails_installs_nothing() {
  _ls_env
  local d; d="$(rt_dir lmstudio)"
  printf '0%.0s' $(seq 128) > "$TMP/sha"
  ( rt_install lmstudio ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "What arrived does not match the SHA-512 DevOS ADE pins for LM Studio $VER, so it was deleted and nothing was installed."
  assert_eq "$(rt_state lmstudio)" not-installed
  [ ! -e "$d/home" ] && [ ! -e "$d/pkg" ] && [ -z "$(find "$d" -maxdepth 1 -name '*.part')" ]
  _rt_sha512 "$TMP/llmster.tgz" > "$TMP/sha"; : > "$TMP/boot-fails"
  ( rt_install lmstudio ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "LM Studio's installer did not finish: bootstrap: no space left on device"
  assert_eq "$(rt_state lmstudio)" not-installed
  [ ! -e "$d/pkg" ] && [ ! -e "$d/llmster.run" ]
}

test_an_installer_that_leaves_out_lms_or_where_llmster_is_says_which() {
  # (each its own try: what an earlier one left in the stack's LM Studio home is cleared first)
  _ls_env
  local d k; d="$(rt_dir lmstudio)"
  for k in boot-no-lms boot-no-record boot-in-place; do
    rm -rf "$d/home" "$TMP"/boot-*; : > "$TMP/$k"
    ( rt_install lmstudio ) > "$TMP/out.$k" 2>&1 && { echo "$k: installed" >&2; return 1; }
    assert_eq "$(rt_state lmstudio)" not-installed
    [ ! -e "$d/llmster.run" ] && [ ! -e "$d/pkg" ]
  done
  assert_contains "$(cat "$TMP/out.boot-no-lms")" "LM Studio's installer left no lms in .state/runtimes/lmstudio/home/.lmstudio/bin; .state/runtimes/lmstudio/home/.lmstudio holds .internal, bin, llmster"
  assert_contains "$(cat "$TMP/out.boot-no-record")" "LM Studio's installer left no record of where llmster is (.state/runtimes/lmstudio/home/.lmstudio/.internal/llmster-install-location.json)"
  assert_contains "$(cat "$TMP/out.boot-in-place")" "LM Studio's installer recorded llmster at .state/runtimes/lmstudio/pkg/llmster, outside .state/runtimes/lmstudio/home;"
}

test_its_bundle_unpacks_with_links_inside_its_own_tree_and_nothing_else() {
  local a; a="$TMP/arch"; mkdir -p "$a"
  python3 -I - "$a" <<'PY'
import io, sys, tarfile
def make(name, members):
    with tarfile.open(f"{sys.argv[1]}/{name}.tgz", "w:gz") as t:
        for n, kind, x in members:
            i = tarfile.TarInfo(n); i.mode = 0o755
            if kind == "f":
                i.size = len(x); t.addfile(i, io.BytesIO(x))
            elif kind == "d":
                i.type = tarfile.DIRTYPE; t.addfile(i)
            elif kind == "l":
                i.type = tarfile.SYMTYPE; i.linkname = x; t.addfile(i)
            elif kind == "p":
                i.type = tarfile.FIFOTYPE; t.addfile(i)
good = [("llmster", "f", b"x"), (".bundle", "d", None), (".bundle/bin/node", "f", b"n"), (".bundle/lib/a/node", "l", "../../bin/node")]
make("good", good)
make("up", good + [(".bundle/lib/evil", "l", "../../../etc/passwd")])
make("abs", good + [(".bundle/lib/evil", "l", "/etc/passwd")])
make("dots", good + [("../evil", "f", b"x")])
make("absname", good + [("/tmp/evil", "f", b"x")])
make("fifo", good + [(".bundle/p", "p", None)])
PY
  _rt_unpack_bundle "$a/good.tgz" "$TMP/out-good"
  assert_eq "$(cat "$TMP/out-good/.bundle/lib/a/node")" n
  local x; for x in up abs dots absname fifo; do
    if _rt_unpack_bundle "$a/$x.tgz" "$TMP/out-$x"; then echo "$x was unpacked" >&2; return 1; fi
    [ ! -e "$TMP/out-$x" ] || { echo "$x left $TMP/out-$x" >&2; return 1; }
  done
}

_free_port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
_key() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }

test_the_agent_runs_llmster_its_server_on_a_port_of_its_own_and_the_gate_in_front_and_stops_them_all() {
  local h v ap lp port bp k; h="$TMP/h"; v="$h/.lmstudio/llmster/$VER"; port="$(_free_port)"; k="$TMP/api-key"
  mkdir -p "$h/.lmstudio/bin" "$v"; v="$(cd "$v" && pwd -P)"   # (as install records it: resolved)
  _key > "$k"
  printf '#!/bin/sh\nprintf "%%s|%%s\\n" "$*" "$LMS_API_SERVER_INFO_PATH" >> "%s/lms.args"\n[ ! -f "%s/server-fails" ] || exit 1\n' "$TMP" "$TMP" > "$h/.lmstudio/bin/lms"
  printf '#!/bin/sh\necho "$$|$*|$(pwd)" > "%s/llmster.ran"\nexec sleep 20\n' "$TMP" > "$v/llmster"
  chmod +x "$h/.lmstudio/bin/lms" "$v/llmster"
  printf '%s\t%s\t.\t%s\n' "$v/llmster" "$v" "$(command -v python3)" > "$TMP/run"
  HOME="$h" /bin/bash "$STACK_DIR/lib/lmstudio-agent.sh" "$port" "$TMP/run" "$k" > "$TMP/agent.out" 2>&1 &
  ap=$!
  _wait_for '[ -s "$TMP/lms.args" ] && [ -s "$TMP/llmster.ran" ]' || { kill "$ap"; return 1; }
  # LM Studio's server: 127.0.0.1, a port of its own (never the gate's), lms pointed at this llmster alone
  bp="$(sed -n 's/^server start --port \([0-9]*\) --bind 127\.0\.0\.1|.*/\1/p' "$TMP/lms.args")"
  [[ $bp =~ ^[0-9]+$ ]] && [ "$bp" != "$port" ]
  assert_eq "$(cut -d'|' -f2 "$TMP/lms.args")" "$h/.lmstudio/.internal/http-server.json"
  lp="$(cut -d'|' -f1 "$TMP/llmster.ran")"
  assert_eq "$(cut -d'|' -f2- "$TMP/llmster.ran")" ".|$v"
  # the gate on PORT: nothing without the key; with it, on to LM Studio's port (nothing there in this test: 502)
  _wait_for '[ "$("$BN_REAL_CURL" -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/v1/models")" = 401 ]' || { kill "$ap"; return 1; }
  assert_eq "$("$BN_REAL_CURL" -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$k")" "http://127.0.0.1:$port/v1/models")" 502
  assert_contains "$(cat "$TMP/agent.out")" "lmstudio-agent: LM Studio's server on 127.0.0.1:$bp, its gate on 127.0.0.1:$port"
  kill -0 "$ap" && kill -0 "$lp"
  # launchd's stop: the agent ends, and llmster and the gate with it
  kill -TERM "$ap"; wait "$ap" || { kill "$lp" 2>/dev/null; return 1; }
  _wait_for '! kill -0 "$lp" 2>/dev/null'
  _wait_for '[ "$("$BN_REAL_CURL" -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/v1/models")" = 000 ]'
  # a recorded place out of its HOME, or no python3 for the gate: nothing runs
  rm -f "$TMP/llmster.ran"
  printf '%s\t%s\t-\t%s\n' /bin/sleep /bin "$(command -v python3)" > "$TMP/run"
  if HOME="$h" /bin/bash "$STACK_DIR/lib/lmstudio-agent.sh" "$port" "$TMP/run" "$k" > "$TMP/agent.out" 2>&1; then return 1; fi
  assert_contains "$(cat "$TMP/agent.out")" "lmstudio-agent: no llmster in $h/.lmstudio"
  printf '%s\t%s\t-\t%s\n' "$v/llmster" "$v" python3 > "$TMP/run"
  if HOME="$h" /bin/bash "$STACK_DIR/lib/lmstudio-agent.sh" "$port" "$TMP/run" "$k" > "$TMP/agent.out" 2>&1; then return 1; fi
  assert_contains "$(cat "$TMP/agent.out")" "lmstudio-agent: no python3 or key for its gate"
  [ ! -e "$TMP/llmster.ran" ]
  # a server that does not start while llmster has ended: it says so and ends
  printf '#!/bin/sh\necho "$$" > "%s/llmster.ran"\nexit 3\n' "$TMP" > "$v/llmster"; : > "$TMP/server-fails"
  printf '%s\t%s\t-\t%s\n' "$v/llmster" "$v" "$(command -v python3)" > "$TMP/run"
  if HOME="$h" /bin/bash "$STACK_DIR/lib/lmstudio-agent.sh" "$port" "$TMP/run" "$k" > "$TMP/agent.out" 2>&1; then return 1; fi
  assert_contains "$(cat "$TMP/agent.out")" "lmstudio-agent: its server did not start on 127.0.0.1:"
}

# The gate in front of a stand-in LM Studio server (it answers each request with what it was sent; /v1/stream sends its
# answer in three parts, a second apart)
test_the_gate_lets_through_only_this_computers_names_with_the_key_and_the_openai_api() {
  local port bp k gp c; port="$(_free_port)"; k="$(_key)"; printf '%s\n' "$k" > "$TMP/api-key"; c="$BN_REAL_CURL"
  cat > "$TMP/backend.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def _go(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        if self.path == "/v1/stream":
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            for i in range(3):
                self.wfile.write(b"data: %d\n\n" % i); self.wfile.flush(); time.sleep(1)
            return
        out = json.dumps({"method": self.command, "path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(out))); self.end_headers()
        self.wfile.write(out)
    do_GET = do_POST = do_DELETE = _go
    def log_message(self, *a): pass
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
  python3 -I "$TMP/backend.py" "$TMP/bp" </dev/null >/dev/null 2>&1 &
  BACK_PID=$!
  _wait_for '[ -s "$TMP/bp" ]'; bp="$(cat "$TMP/bp")"
  python3 -I "$STACK_DIR/lib/lmstudio-gate.py" "$port" "$bp" "$TMP/api-key" </dev/null > "$TMP/gate.out" 2>&1 &
  gp=$!
  _wait_for '[ "$("$c" -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/v1/models")" != 000 ]' || { kill "$gp" "$BACK_PID"; return 1; }
  local A="Authorization: Bearer $k" u="http://127.0.0.1:$port"
  _code() { "$c" -s -o /dev/null -w '%{http_code}' "$@"; }
  # no key, a wrong one: refused
  assert_eq "$(_code "$u/v1/models")" 401
  assert_eq "$(_code -H "Authorization: Bearer $(_key)" "$u/v1/models")" 401
  # a name that is not this computer's (a page's, pointed here): refused, with the key too
  assert_eq "$(_code -H "$A" -H "Host: rebind.example:$port" "$u/v1/models")" 403
  assert_eq "$(_code -H "$A" -H "Host: 127.0.0.1:$bp" "$u/v1/models")" 403
  # the rest of LM Studio's API: never, with the key too
  local x; for x in /api/v1/models/download /api/v1/models/load /api/v1/log/entries /api/v1/chat /api/v0/chat/completions /v1/../api/v1/models/download /v1/%2e%2e/api/v1/log/entries /; do
    assert_eq "$(_code --path-as-is -X POST -H "$A" -H 'Content-Type: application/json' -d '{}' "$u$x")" 403
  done
  assert_eq "$(_code -X POST -H "$A" -d '{}' "$u/api/v0/models")" 403
  # a body sent in chunks: refused (a request body is passed on by its length only)
  assert_eq "$(_code -H "$A" -H 'Transfer-Encoding: chunked' -d '{}' "$u/v1/chat/completions")" 411
  # through: by the names this computer has, the key not passed on, one request per connection, the body as sent
  local r; r="$("$c" -s -H "$A" "$u/v1/models")"
  python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); h = d["headers"]
assert (d["method"], d["path"], h["host"], h["connection"]) == ("GET", "/v1/models", "127.0.0.1:" + sys.argv[2], "close"), d
assert "authorization" not in h, d' "$r" "$bp"
  r="$("$c" -s -H "$A" -H "Host: host.docker.internal:$port" -H 'Content-Type: application/json' -d '{"model":"m","messages":[]}' "$u/v1/chat/completions")"
  python3 -I -c 'import json, sys; d = json.loads(sys.argv[1])
assert (d["method"], d["path"], d["body"]) == ("POST", "/v1/chat/completions", "{\"model\":\"m\",\"messages\":[]}"), d' "$r"
  # a client that waits for 100 Continue before its body (curl's, for a large one): answered by the gate, not passed on
  r="$("$c" -s -m 8 --expect100-timeout 20 -H "$A" -H 'Expect: 100-continue' -d '{"n":1}' "$u/v1/embeddings")"
  python3 -I -c 'import json, sys; d = json.loads(sys.argv[1])
assert (d["path"], d["body"]) == ("/v1/embeddings", "{\"n\":1}") and "expect" not in d["headers"], d' "$r"
  assert_eq "$(_code -H "$A" -H 'Expect: something-else' -d '{}' "$u/v1/embeddings")" 417
  assert_eq "$(_code -H "$A" -H "Host: localhost:$port" "$u/api/v0/models")" 200
  # a streamed answer: each part as it comes
  r="$("$c" -s -N -H "$A" "$u/v1/stream")"
  assert_eq "$r" "$(printf 'data: 0\n\ndata: 1\n\ndata: 2')"
  # LM Studio not answering: said so
  kill "$BACK_PID"; wait "$BACK_PID" 2>/dev/null || true
  assert_eq "$(_code -H "$A" "$u/v1/models")" 502
  kill "$gp"; wait "$gp" 2>/dev/null || true
  # nothing it was sent is in its output
  assert_eq "$(cat "$TMP/gate.out")" ""
}

# --- its models: by link, by the key LM Studio gives them ---

test_a_gguf_download_goes_to_lm_studio_by_link_and_the_gateway_names_it_by_its_key_and_remove_takes_it_out() {
  _ls_env; _ls_hub
  rt_install lmstudio > /dev/null 2>&1
  local_pull org/M-GGUF Q4_K_M --context 131072 --tools yes --params-m 8000 > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" "$(local_dir)/pull.log" >&2; return 1; }
  kill "$HUB_PID"
  local d h s; d="$(rt_dir lmstudio)"; h="$d/home/.lmstudio"; s="$d/hub/models--org--M-GGUF/snapshots/$SHA_A"
  cmp -s "$s/M-Q4_K_M.gguf" "$TMP/hub-files/M-Q4_K_M.gguf"
  assert_eq "$(cd "$s" && find . -type l | sort)" "./M-Q4_K_M.gguf"
  # LM Studio has it by link (never a second copy), from this stack's lms only
  assert_contains "$(cat "$TMP/lms.args")" "import $s/M-Q4_K_M.gguf --user-repo org/M-GGUF --symbolic-link --yes|HOME=$d/home|INFO=$h/.internal/http-server.json"
  assert_eq "$(readlink "$h/models/org/M-GGUF/M-Q4_K_M.gguf")" "$s/M-Q4_K_M.gguf"
  assert_eq "$(cat "$(rt_lmstudio_models)")" "$(printf 'org/M-GGUF:Q4_K_M\tm-q4_k_m\tmodels--org--M-GGUF/snapshots/%s/M-Q4_K_M.gguf\tM-Q4_K_M.gguf' "$SHA_A")"
  assert_eq "$(rt_lmstudio_key org/M-GGUF:Q4_K_M)" m-q4_k_m
  # the registry, LOCAL_MODELS, the job
  assert_contains "$(local_registry_rows)" "$(printf 'lmstudio\torg/M-GGUF:Q4_K_M\torg/M-GGUF\tQ4_K_M\t200000\t-\t1\t131072\t8000\t')"
  assert_eq "$(tail -n 1 "$TMP/apply")" "local cli |LOCAL_MODELS|lmstudio:org/M-GGUF:Q4_K_M"
  assert_eq "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$(local_job_file)")" done
  # the model gateway's entry: Chat Completions to this Mac's LM Studio, by its key
  printf 'LOCAL_MODELS=lmstudio:org/M-GGUF:Q4_K_M\n' >> "$ENV_FILE"
  local y; y="$(local_models_yaml)"
  assert_contains "$y" '- model_name: "lm/org/M-GGUF:Q4_K_M"'
  assert_contains "$y" 'model: "openai/m-q4_k_m"'
  assert_contains "$y" 'api_base: "http://host.docker.internal:11439/v1"'
  assert_contains "$y" "api_key: \"$(rt_api_key lmstudio)\""
  assert_contains "$y" "input_cost_per_token: 0"
  # the portal's file: LM Studio ready, the model on disk and registered
  local_status_write
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); i=d["installed"][0]
assert d["runtime"]["kind"] == "lmstudio" and d["runtime"]["lmstudio"] == "ready", d["runtime"]
assert (i["runtime"], i["id"], i["present"], i["registered"]) == ("lmstudio", "org/M-GGUF:Q4_K_M", True, True), i' "$(local_status_file)"
  # Remove when LM Studio does not let it go: the job says where to look (and nothing is deleted)
  ( rt_lmstudio_forget() { return 1; }; local_rm org/M-GGUF Q4_K_M ) > /dev/null 2>&1 && return 1
  assert_contains "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$(local_job_file)")" \
    "Taken out of the pickers, but the runtime did not delete the files (is it running?): ./stack runtimes status"
  [ -f "$s/M-Q4_K_M.gguf" ]
  # Remove: unloaded, its link and its files gone, out of the gateway
  local_rm org/M-GGUF Q4_K_M > /dev/null 2>&1
  assert_contains "$(cat "$TMP/lms.args")" "unload m-q4_k_m|HOME=$d/home"
  [ ! -e "$h/models/org" ] && [ ! -e "$d/hub/models--org--M-GGUF" ]
  assert_eq "$(cat "$(rt_lmstudio_models)")" ""
  assert_eq "$(local_registry_rows)" ""
  assert_eq "$(tail -n 1 "$TMP/apply")" "local cli |LOCAL_MODELS|"
}

test_its_key_is_the_new_one_lm_studio_lists_when_it_names_no_path_and_nothing_else_is_imported() {
  _ls_env
  local d h s; d="$(rt_dir lmstudio)"; h="$d/home/.lmstudio"; s="$d/hub/models--org--M-GGUF/snapshots/$SHA_A"
  mkdir -p "$h/bin" "$s"; cp "$TMP/lms-src" "$h/bin/lms"; printf q4 > "$s/M-Q4_K_M.gguf"
  : > "$TMP/ls-nopath"; : > "$TMP/ls-extra"
  rt_lmstudio_model_add org/M-GGUF:Q4_K_M org/M-GGUF "models--org--M-GGUF/snapshots/$SHA_A/M-Q4_K_M.gguf" M-Q4_K_M.gguf
  assert_eq "$(rt_lmstudio_key org/M-GGUF:Q4_K_M)" m-q4_k_m
  # again: one row for it
  rt_lmstudio_model_add org/M-GGUF:Q4_K_M org/M-GGUF "models--org--M-GGUF/snapshots/$SHA_A/M-Q4_K_M.gguf" M-Q4_K_M.gguf
  assert_eq "$(wc -l < "$(rt_lmstudio_models)" | tr -d ' ')" 1
  # what is not one is never handed to lms
  : > "$TMP/lms.args"
  ! rt_lmstudio_model_add 'org/X;rm' org/X "models--org--X/snapshots/$SHA_A/x.gguf" x.gguf
  ! rt_lmstudio_model_add org/X:Q4 org/X "models--org--X/snapshots/$SHA_A/../../../../etc/x" x.gguf
  ! rt_lmstudio_model_add org/X:Q4 org/X "models--org--X/snapshots/$SHA_A/x.gguf" ../x.gguf
  assert_not_contains "$(cat "$TMP/lms.args")" import
  # LM Studio never lists it: not added
  RT_START_WAIT=1; : > "$TMP/import-noop"
  ! rt_lmstudio_model_add org/N:Q8_0 org/N "models--org--N/snapshots/$SHA_A/n.gguf" n.gguf
  assert_eq "$(rt_lmstudio_key org/N:Q8_0)" ""
}

# --- where downloads go, and Cancel ---

test_downloads_go_to_lm_studio_when_named_or_when_nothing_else_runs() {
  _ls_env
  export LOCAL_MLX=off
  assert_eq "$(local_runtime)" none
  assert_contains "$(local_how_text)" "Downloads go to LM Studio (Settings › Local models › Runtimes), which is not running: install it in Settings › Local models › Runtimes (./stack runtimes install lmstudio)."
  rt_install lmstudio > /dev/null 2>&1
  assert_eq "$(local_runtime)" lmstudio
  rt_stop lmstudio > /dev/null 2>&1
  assert_eq "$(local_runtime)" none
  assert_contains "$(local_how_text)" "start it in Settings › Local models › Runtimes (./stack runtimes start lmstudio)."
  rt_start lmstudio > /dev/null 2>&1
  printf 'X=1\n' > "$ENV_FILE"   # (automatic: MLX off, no Docker Model Runner, Ollama or llama.cpp: LM Studio)
  assert_eq "$(local_runtime)" lmstudio
  valid_local_entry lmstudio:org/M-GGUF:Q4_K_M
  _sv_local_runtime lmstudio
}

test_cancel_deletes_what_arrived_and_says_so() {
  _ls_env
  local h; h="$(rt_dir lmstudio)/hub/models--org--M-GGUF"
  mkdir -p "$h/blobs" "$(local_dir)"; printf x > "$h/blobs/$(printf '4%.0s' $(seq 64)).part"
  _local_stopped cancel lmstudio org/M-GGUF Q4_K_M 1 100
  [ ! -e "$h" ]
  assert_eq "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$(local_job_file)")" "Cancelled: what had arrived was deleted."
}
