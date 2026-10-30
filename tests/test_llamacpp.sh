# shellcheck shell=bash
# shellcheck disable=SC2016,SC2329  # literal $ in expected output; stubs are called by the code under test
# llama.cpp as a runtime DevOS ADE installs and runs (lib/runtimes.sh, JON-829) and its downloads (lib/local_models.sh):
# the pins; the Linux container's isolation, as Compose renders it; on a Mac the pinned build downloaded (a stand-in curl
# serves it), checked, taken out of its folder and run as a launchd agent (a stand-in launchctl) with its API key and
# presets and no web UI; presets.ini from what was downloaded; a GGUF download for real (lib/hf_fetch.py and curl, against
# the stand-in Hub on 127.0.0.1: tests/fixtures/hf_hub_server.py) added to llama.cpp and registered with the model
# gateway with its key; Remove; Linux's install and Stop. Nothing here reaches launchd, Docker or the network.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/local_models.sh and lib/runtimes.sh

BUILD=b11960
SHA_A="$(printf 'a%.0s' $(seq 40))"
TOKEN_FAKE="hf_$(printf 'abcdefghij%.0s' 1 2 3)"   # (built here, never a literal in the repo)

_lc_env() {
  mkdir -p "$STATE_DIR/status" "$STATE_DIR/requests" "$STATE_DIR/helper" "$TMP/bin" "$TMP/pkg/llama-$BUILD"
  printf 'X=1\nLOCAL_RUNTIME=llamacpp\n' > "$ENV_FILE"
  export RT_POLL_S=0.1 RT_START_WAIT=5 LOCAL_POLL_S=0.1 ASSUME_YES=1 PATH="$TMP/bin:$PATH"
  FAKE_OS=Darwin; FAKE_ARCH=arm64
  uname() { case "${1:-}" in -s) echo "$FAKE_OS" ;; -m) echo "$FAKE_ARCH" ;; *) command uname "$@" ;; esac; }
  # launchd: llama.cpp's agent is loaded from bootstrap to bootout (TMP/lc-loaded); kickstart -k is one more run
  launchctl() {
    printf '%s\n' "$*" >> "$TMP/launchctl.args"
    case "$1" in
      print) case "$2" in *.llamacpp.*) [ -f "$TMP/lc-loaded" ] || return 113 ;; *) return 113 ;; esac
        printf '%s = {\n\tstate = running\n\truns = %s\n\tlast exit code = (never exited)\n\tpid = 4343\n}\n' "$2" "$(cat "$TMP/lc-runs" 2>/dev/null || echo 1)" ;;
      bootstrap) [ -f "$3" ] || return 5; case "$3" in *.llamacpp.*) : > "$TMP/lc-loaded" ;; esac ;;
      bootout) case "$2" in *.llamacpp.*) rm -f "$TMP/lc-loaded" ;; esac ;;
      kickstart) echo $(( $(cat "$TMP/lc-runs" 2>/dev/null || echo 1) + 1 )) > "$TMP/lc-runs" ;;
    esac
  }
  # curl: GitHub's release file and its size, the llama.cpp that answers while its agent is loaded (/health, and /models
  # from TMP/lc-models.json), and the stand-in Hub on its own port (the real curl: the shim guards this computer's
  # addresses for a live DevOS ADE, and that one is the test's own server)
  cat > "$TMP/bin/curl" <<EOF
#!/bin/sh
T="$TMP"; out=''; url=''; head=0; prev=''; w=''
printf '%s\n' "\$*" >> "\$T/curl.args"
for a in "\$@"; do
  [ "\$prev" = -o ] && out="\$a"; [ "\$prev" = -w ] && w="\$a"
  case "\$a" in -sSIL) head=1 ;; http://* | https://*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  http://127.0.0.1:9/health) if [ -f "\$T/lc-loaded" ]; then [ -z "\$w" ] || printf 200; exit 0; fi; [ -z "\$w" ] || printf 000; exit 7 ;;
  http://127.0.0.1:9/models) [ -f "\$T/lc-loaded" ] || exit 7; cat "\$T/lc-models.json" 2>/dev/null || printf '{"data":[]}' ;;
  https://github.com/ggml-org/llama.cpp/releases/download/*)
    if [ "\$head" = 1 ]; then printf 'HTTP/2 200\r\ncontent-length: %s\r\n\r\n' "\$(wc -c < "\$T/llama.tgz" | tr -d ' ')"; exit 0; fi
    cat "\$T/llama.tgz" > "\$out" ;;
  http://127.0.0.1:*) exec "${BN_REAL_CURL:?}" "\$@" ;;
  *) exit 6 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  # the release: one folder, llama-<build>, with llama-server, a library and a link to it beside it
  printf '#!/bin/sh\necho "version: 11960"\n' > "$TMP/pkg/llama-$BUILD/llama-server"; chmod +x "$TMP/pkg/llama-$BUILD/llama-server"
  printf 'lib' > "$TMP/pkg/llama-$BUILD/libllama.dylib"; ln -sf libllama.dylib "$TMP/pkg/llama-$BUILD/libllama.0.dylib"
  tar -czf "$TMP/llama.tgz" -C "$TMP/pkg" "llama-$BUILD"
  _rt_sha256 "$TMP/llama.tgz" > "$TMP/sha"
  rt_pin() { case "$1" in LLAMACPP_VERSION) echo 0.8.0 ;; LLAMACPP_BUILD) echo "$BUILD" ;; LLAMACPP_SHA256_MACOS_*) cat "$TMP/sha" ;; OLLAMA_VERSION) echo 0.40.11 ;; esac; }
  config_apply() { printf '%s|%s|%s\n' "$*" "$CFG_ORDER" "$(cfg_new LOCAL_MODELS)" >> "$TMP/apply"; }   # (what it would write)
  local_dmr_state() { echo not-installed; }   # (no Docker here)
}
_job() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(rt_job_file)" "$1"; }
_events() { cut -f2- "$(rt_events_file)" 2>/dev/null | tr '\t' ' '; }
_wait_for() { local n=0; until eval "$1"; do sleep 0.1; n=$((n + 1)); [ "$n" -lt 150 ] || { echo "timed out waiting for: $1" >&2; return 1; }; done; }

# The stand-in Hub with a GGUF repo, org/M-GGUF at SHA_A: Q4_K_M (with look-alikes beside it: Q4_K_M_L, IQ4_K_M and a
# vision projector), and Q8_0 split in three parts in a folder of its own (LC_PARTS: how many of them the Hub lists)
_lc_hub() {
  mkdir -p "$TMP/hub-files/Q8_0"; rm -f "$TMP/hub.port" "$TMP/hub.log" "$TMP/hub-files/.api.code"
  head -c 200000 /dev/urandom > "$TMP/hub-files/M-Q4_K_M.gguf"
  local f; for f in M-Q4_K_M_L.gguf M-IQ4_K_M.gguf mmproj-M-Q4_K_M.gguf Q8_0/M-Q8_0-00001-of-00003.gguf Q8_0/M-Q8_0-00002-of-00003.gguf \
    Q8_0/M-Q8_0-00003-of-00003.gguf README.md; do head -c 3000 /dev/urandom > "$TMP/hub-files/$f"; done
  _lc_api
  python3 -I "$STACK_DIR/tests/fixtures/hf_hub_server.py" "$TMP/hub-files" "$TMP/hub.port" "$TMP/hub.log" </dev/null >/dev/null 2>&1 &
  HUB_PID=$!
  _wait_for '[ -s "$TMP/hub.port" ]'
  export HF_ENDPOINT="http://127.0.0.1:$(cat "$TMP/hub.port")"
}
_lc_api() {
  python3 -I -c '
import hashlib, json, os, sys
root, sha, parts = sys.argv[1], sys.argv[2], int(sys.argv[3])
names = ["README.md", "M-Q4_K_M.gguf", "M-Q4_K_M_L.gguf", "M-IQ4_K_M.gguf", "mmproj-M-Q4_K_M.gguf"] + ["Q8_0/M-Q8_0-%05d-of-00003.gguf" % i for i in range(1, parts + 1)]
sib = []
for n in names:
    b = open(os.path.join(root, n), "rb").read()
    e = {"rfilename": n, "size": len(b), "blobId": hashlib.sha1(b"blob %d\0" % len(b) + b).hexdigest()}
    if n.endswith(".gguf"):
        e["lfs"] = {"sha256": hashlib.sha256(b).hexdigest(), "size": len(b), "pointerSize": 134}
    sib.append(e)
json.dump({"id": "org/M-GGUF", "sha": sha, "siblings": sib}, open(os.path.join(root, ".api.json"), "w"))' "$TMP/hub-files" "$SHA_A" "${LC_PARTS:-3}"
}

# --- the pins, and the container on Linux ---

test_the_pins_name_one_build_for_the_mac_archives_and_the_linux_images() {
  [[ $(rt_pin LLAMACPP_VERSION) =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  local b; b="$(rt_pin LLAMACPP_BUILD)"; [[ $b =~ ^b[0-9]+$ ]]
  [[ $(rt_pin LLAMACPP_SHA256_MACOS_ARM64) =~ ^[0-9a-f]{64}$ ]] && [[ $(rt_pin LLAMACPP_SHA256_MACOS_X64) =~ ^[0-9a-f]{64}$ ]]
  grep -Eq "^    image: ghcr.io/ggml-org/llama.cpp:server-$b@sha256:[0-9a-f]{64}\$" "$STACK_DIR/compose.yaml"
  grep -Eq "^    image: ghcr.io/ggml-org/llama.cpp:server-cuda-$b@sha256:[0-9a-f]{64}\$" "$STACK_DIR/compose.llamacpp-gpu.yaml"
  uname() { case "${1:-}" in -s) echo Linux ;; *) command uname "$@" ;; esac; }
  assert_eq "$(rt_pinned_version llamacpp)" "$(rt_pin LLAMACPP_VERSION)"
}

test_the_container_publishes_nothing_reaches_nothing_and_drops_its_privileges() {
  local svc; svc="$(awk '/^  llamacpp:/{s=1;print;next} s&&/^  [a-z]/{exit} s' "$STACK_DIR/compose.yaml")"
  assert_contains "$svc" 'profiles: ["llamacpp"]'
  assert_not_contains "$svc" "ports:"
  assert_contains "$svc" "networks: [llamacpp]"
  assert_contains "$svc" 'user: "${BN_LLAMACPP_USER:-65534:65534}"'
  assert_contains "$svc" "read_only: true"
  assert_contains "$svc" "cap_drop: [ALL]"
  assert_contains "$svc" "no-new-privileges"
  assert_contains "$svc" '"--api-key-file", "/etc/llamacpp/api-key", "--no-ui"'
  assert_contains "$svc" '"--cors-origins", "localhost"'
  assert_contains "$svc" '/hub:/models:ro,z'
  assert_contains "$svc" '/etc:/etc/llamacpp:ro,z'
  assert_contains "$(awk '/^networks:/,0' "$STACK_DIR/compose.yaml")" "$(printf '  llamacpp:\n    internal: true')"
  assert_contains "$(status_url llamacpp)" "LiteLLM's alone"
}

# compose.yaml as Docker Compose renders it with the profile (no daemon): who is on llama.cpp's network, its user and
# mounts, and the CUDA image with the GPU
test_compose_renders_llamacpp_on_an_internal_network_with_the_gateway_alone() {
  [ -n "${BN_REAL_DOCKER:-}" ] && "$BN_REAL_DOCKER" compose version >/dev/null 2>&1 || { echo "no docker compose" >&2; return 77; }
  docker() { case "$*" in *" config --format json") "$BN_REAL_DOCKER" "$@" ;; *) echo "unexpected docker $*" >&2; return 97 ;; esac; }
  printf 'POSTGRES_PASSWORD=p\nRUSTFS_ACCESS_KEY=a\nRUSTFS_SECRET_KEY=s\nLITELLM_MASTER_KEY=m\nLITELLM_SALT_KEY=s\nLITELLM_UI_PASSWORD=u\nWEBUI_SECRET_KEY=w\nOPENWEBUI_ADMIN_EMAIL=a@b.c\nOPENWEBUI_ADMIN_PASSWORD=p\nSHARED_MCP_TOKEN=t\nSTT_PROVIDER=bedrock\n' > "$ENV_FILE"
  mkdir -p "$STATE_DIR/runtimes/llamacpp"; echo 1234:5678 > "$STATE_DIR/runtimes/llamacpp/user"
  local out; out="$(_RT_PROFILE=llamacpp dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c '
import json, sys
d = json.load(sys.stdin); s = d["services"]; l = s["llamacpp"]; root = sys.argv[1]
on = lambda n: sorted(k for k, v in s.items() if n in (v.get("networks") or {}))
assert on("llamacpp") == ["litellm", "llamacpp"], on("llamacpp")
assert d["networks"]["llamacpp"]["internal"] is True, d["networks"]["llamacpp"]
assert "ports" not in l and list(l["networks"]) == ["llamacpp"], l
assert l["user"] == "1234:5678" and l["read_only"] is True and l["cap_drop"] == ["ALL"], l
assert ":server-b" in l["image"] and "deploy" not in l, l
m = {v["target"]: (v["source"], v.get("read_only")) for v in l["volumes"]}
assert m == {"/models": (root + "/hub", True), "/etc/llamacpp": (root + "/etc", True)}, m
' "$STATE_DIR/runtimes/llamacpp"
  echo nvidia > "$STATE_DIR/runtimes/llamacpp/gpu"
  out="$(_RT_PROFILE=llamacpp dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c '
import json, sys
l = json.load(sys.stdin)["services"]["llamacpp"]
assert ":server-cuda-b" in l["image"], l["image"]
assert l["deploy"]["resources"]["reservations"]["devices"][0]["driver"] == "nvidia", l["deploy"]'
  # without the profile: no llama.cpp
  rm -f "$STATE_DIR/runtimes/llamacpp/gpu"
  out="$(dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); assert "llamacpp" not in d["services"], sorted(d["services"])'
}

# --- macOS: install, its key, the agent ---

test_install_downloads_the_pinned_build_checks_it_and_runs_it_with_its_key_and_no_web_ui() {
  _lc_env
  assert_eq "$(rt_state llamacpp)" not-installed
  rt_install llamacpp > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_eq "$(rt_state llamacpp)" running
  assert_eq "$(rt_installed_version llamacpp)" 0.8.0
  local d; d="$(rt_dir llamacpp)"
  [ -x "$d/bin/llama-server" ] && [ -L "$d/bin/libllama.0.dylib" ] && [ ! -e "$d/bin/llama-$BUILD" ] && [ ! -e "$d/bin.new" ]
  [ -z "$(find "$d" -maxdepth 1 -name '*.part')" ]
  assert_contains "$(cat "$TMP/curl.args")" "--proto =https --proto-redir =https"
  assert_contains "$(cat "$TMP/curl.args")" "https://github.com/ggml-org/llama.cpp/releases/download/$BUILD/llama-$BUILD-bin-macos-arm64.tar.gz"
  # its key: 32 random bytes in hex, in a folder of its own; the header ./stack's own looks send it in (a file: never an argument)
  local k; k="$(cat "$d/etc/api-key")"; [[ $k =~ ^[0-9a-f]{64}$ ]]
  assert_eq "$(perm_of "$d/etc")" 700
  assert_eq "$(perm_of "$d/etc/api-key")" 600
  assert_eq "$(perm_of "$d/etc/auth.hdr")" 600
  assert_eq "$(cat "$d/etc/auth.hdr")" "Authorization: Bearer $k"
  assert_eq "$(rt_llamacpp_key)" "$k"
  # the agent: this stack's label, 127.0.0.1:11438 only, router mode on its presets, the key from its file, no web UI
  local p x; p="$(rt_plist llamacpp)"; x="$(cat "$p")"
  assert_contains "$p" "$HOME/Library/LaunchAgents/dev.devos.ade.llamacpp."
  assert_eq "$(perm_of "$p")" 600
  assert_contains "$x" "<string>$d/bin/llama-server</string><string>--host</string><string>127.0.0.1</string><string>--port</string><string>11438</string>"
  assert_contains "$x" "<string>--models-preset</string><string>$d/etc/presets.ini</string><string>--api-key-file</string><string>$d/etc/api-key</string><string>--no-ui</string><string>--cors-origins</string><string>localhost</string><string>--models-max</string><string>2</string>"
  assert_contains "$x" "<key>LLAMA_CACHE</key><string>$d/cache</string>"
  assert_not_contains "$x" "$k"
  ! command -v plutil >/dev/null 2>&1 || plutil -lint "$p" >/dev/null
  assert_eq "$(grep -v '^;' "$d/etc/presets.ini")" "$(printf '[*]\njinja = true\nc = 8192')"
  # the job, the event, the portal's file (Ollama's row first)
  assert_eq "$(_job state)" done
  assert_eq "$(_events)" "llamacpp installed llama.cpp 0.8.0 was installed and runs on 127.0.0.1:11438"
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d["runtimes"][1]
assert [x["id"] for x in d["runtimes"]] == ["ollama", "llamacpp", "lmstudio", "vllm"], d["runtimes"]
assert (r["name"], r["state"], r["managed"], r["kind"], r["version"], r["pinned"], r["address"], r["size"]) == ("llama.cpp", "running", True, "agent", "0.8.0", "0.8.0", "127.0.0.1:11438", "about 16 MB"), r' "$(rt_status_file)"
  assert_contains "$(cmd_runtimes status)" "llama.cpp   running 0.8.0 on 127.0.0.1:11438 (launchd agent)"
  # the models it has loaded: asked with its key in the header file
  printf '{"data":[{"id":"org/M-GGUF:Q4_K_M","status":{"value":"loaded"}},{"id":"org/N:Q8_0","status":{"value":"unloaded"}}]}' > "$TMP/lc-models.json"
  assert_eq "$(_rt_ps llamacpp)" "$(printf 'org/M-GGUF:Q4_K_M\t0\t0')"
  cmd_runtimes status > "$TMP/out"   # (llama.cpp does not give its memory: no size, never "0 MB")
  grep -qx '            loaded: org/M-GGUF:Q4_K_M' "$TMP/out"
  assert_contains "$(cat "$TMP/curl.args")" "-H @$d/etc/auth.hdr http://127.0.0.1:9/models"
  assert_not_contains "$(cat "$TMP/curl.args")" "$k"
  # again: the same key (the model gateway's config keeps working), still running
  ( rt_install llamacpp ) > /dev/null 2>&1
  assert_eq "$(cat "$d/etc/api-key")" "$k"
  assert_eq "$(rt_state llamacpp)" running
}

test_a_build_that_does_not_match_its_sha256_or_has_no_server_is_not_installed() {
  _lc_env
  echo 0000000000000000000000000000000000000000000000000000000000000000 > "$TMP/sha"
  ( rt_install llamacpp ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "does not match the SHA-256 DevOS ADE pins for llama.cpp 0.8.0"
  assert_eq "$(rt_state llamacpp)" not-installed
  rm "$TMP/pkg/llama-$BUILD/llama-server"; tar -czf "$TMP/llama.tgz" -C "$TMP/pkg" "llama-$BUILD"; _rt_sha256 "$TMP/llama.tgz" > "$TMP/sha"
  ( rt_install llamacpp ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "The archive has no llama-server program: nothing was installed."
  [ ! -e "$(rt_dir llamacpp)/bin" ] && [ ! -e "$(rt_dir llamacpp)/bin.new" ]
}

test_something_else_on_its_port_is_never_installed_over() {
  _lc_env
  : > "$TMP/lc-loaded"   # (something answers on 11438, and no agent of this stack's is there: it is not ours)
  launchctl() { [ "$1" != print ] || return 113; printf '%s\n' "$*" >> "$TMP/launchctl.args"; }
  assert_eq "$(rt_state llamacpp)" external
  ( rt_install llamacpp ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "Something that is not DevOS ADE's already answers on 127.0.0.1:11438, the address llama.cpp would have"
  assert_contains "$(_rt_status_lines)" "llama.cpp   its address is taken: something that is not DevOS ADE's answers on 127.0.0.1:11438"
}

# --- its models: presets.ini, and Remove ---

test_presets_name_each_model_with_its_file_and_a_capped_context_and_forget_deletes_only_its_own_files() {
  _lc_env
  rt_install llamacpp > /dev/null 2>&1
  local d h s q4 p1 p2 ini; d="$(rt_dir llamacpp)"; h="$d/hub/models--org--M-GGUF"; s="$h/snapshots/$SHA_A"
  q4="$(printf '1%.0s' $(seq 64))"; p1="$(printf '2%.0s' $(seq 64))"; p2="$(printf '3%.0s' $(seq 64))"
  mkdir -p "$h/blobs" "$s/Q8_0"
  printf q4 > "$h/blobs/$q4"; printf p1 > "$h/blobs/$p1"; printf p2 > "$h/blobs/$p2"
  ln -s "../../blobs/$q4" "$s/M-Q4_K_M.gguf"; ln -s "../../../blobs/$p1" "$s/Q8_0/M-Q8_0-00001-of-00002.gguf"; ln -s "../../../blobs/$p2" "$s/Q8_0/M-Q8_0-00002-of-00002.gguf"
  rt_llamacpp_model_put org/M-GGUF:Q4_K_M "models--org--M-GGUF/snapshots/$SHA_A/M-Q4_K_M.gguf" 131072 M-Q4_K_M.gguf
  rt_llamacpp_model_put org/M-GGUF:Q8_0 "models--org--M-GGUF/snapshots/$SHA_A/Q8_0/M-Q8_0-00001-of-00002.gguf" - "Q8_0/M-Q8_0-00001-of-00002.gguf,Q8_0/M-Q8_0-00002-of-00002.gguf"
  ini="$(cat "$d/etc/presets.ini")"
  assert_contains "$ini" "$(printf '[org/M-GGUF:Q4_K_M]\nmodel = %s/M-Q4_K_M.gguf\nc = 32768\n\n[org/M-GGUF:Q8_0]\nmodel = %s/Q8_0/M-Q8_0-00001-of-00002.gguf' "$s" "$s")"
  assert_eq "$(perm_of "$d/etc/presets.ini")" 600
  # Linux: the container's /models
  FAKE_OS=Linux; rt_llamacpp_presets_write; FAKE_OS=Darwin
  assert_contains "$(cat "$d/etc/presets.ini")" "model = /models/models--org--M-GGUF/snapshots/$SHA_A/M-Q4_K_M.gguf"
  rt_llamacpp_presets_write
  # an id or a file that is not one is never written
  ! rt_llamacpp_model_put 'org/X;rm' "models--org--X/snapshots/$SHA_A/x.gguf" - x.gguf
  ! rt_llamacpp_model_put org/X:Q4 "models--org--X/snapshots/$SHA_A/../../../../etc/x" - x.gguf
  assert_eq "$(wc -l < "$(rt_llamacpp_models)" | tr -d ' ')" 2
  # Remove Q8_0: its parts and their blobs go, Q4_K_M stays, and llama.cpp is started again without it
  : > "$TMP/launchctl.args"
  rt_llamacpp_forget org/M-GGUF:Q8_0
  [ ! -e "$s/Q8_0/M-Q8_0-00001-of-00002.gguf" ] && [ ! -e "$s/Q8_0/M-Q8_0-00002-of-00002.gguf" ] && [ ! -e "$h/blobs/$p1" ] && [ ! -e "$h/blobs/$p2" ]
  [ -L "$s/M-Q4_K_M.gguf" ] && [ -f "$h/blobs/$q4" ]
  assert_not_contains "$(cat "$d/etc/presets.ini")" "Q8_0"
  assert_contains "$(cat "$TMP/launchctl.args")" "kickstart -k gui/$(id -u)/$(rt_label llamacpp)"
  # the last one of the repo: its whole folder
  rt_llamacpp_forget org/M-GGUF:Q4_K_M
  [ ! -e "$h" ]
  assert_eq "$(grep -c '^\[' "$d/etc/presets.ini")" 1
}

# --- a download, for real: lib/hf_fetch.py and curl against the stand-in Hub ---

test_a_gguf_download_is_checked_fetched_added_to_llamacpp_and_registered_with_its_key() {
  _lc_env; _lc_hub
  rt_install llamacpp > /dev/null 2>&1
  printf 'HF_TOKEN=%s\n' "$TOKEN_FAKE" >> "$ENV_FILE"
  : > "$TMP/launchctl.args"
  local_pull org/M-GGUF Q4_K_M --context 131072 --tools yes --params-m 8000 > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" "$(local_dir)/pull.log" >&2; return 1; }
  kill "$HUB_PID"
  local d s k; d="$(rt_dir llamacpp)"; s="$d/hub/models--org--M-GGUF/snapshots/$SHA_A"; k="$(rt_llamacpp_key)"
  cmp -s "$s/M-Q4_K_M.gguf" "$TMP/hub-files/M-Q4_K_M.gguf"
  # the quantization's own file only: not its look-alikes, the projector, another quantization or the README
  assert_eq "$(cd "$s" && find . -type l | sort)" "./M-Q4_K_M.gguf"
  # the Hub asked with the token in a header, the file pinned to the commit checked; the token never on a command line
  assert_contains "$(cat "$TMP/hub.log")" "/api/models/org/M-GGUF/revision/main?blobs=true	Bearer $TOKEN_FAKE"
  assert_contains "$(cat "$TMP/hub.log")" "/org/M-GGUF/resolve/$SHA_A/M-Q4_K_M.gguf"
  assert_not_contains "$(cat "$TMP/curl.args")" "$TOKEN_FAKE"
  # llama.cpp has it (its context capped), started again to read it
  assert_contains "$(cat "$d/etc/presets.ini")" "$(printf '[org/M-GGUF:Q4_K_M]\nmodel = %s/M-Q4_K_M.gguf\nc = 32768' "$s")"
  assert_contains "$(cat "$TMP/launchctl.args")" "kickstart -k"
  # the registry, LOCAL_MODELS, the job
  assert_contains "$(local_registry_rows)" "$(printf 'llamacpp\torg/M-GGUF:Q4_K_M\torg/M-GGUF\tQ4_K_M\t200000\t-\t1\t131072\t8000\t')"
  assert_eq "$(local_registry_rows | cut -f11)" "$SHA_A"
  assert_eq "$(tail -n 1 "$TMP/apply")" "local cli |LOCAL_MODELS|llamacpp:org/M-GGUF:Q4_K_M"
  assert_eq "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$(local_job_file)")" done
  # the model gateway's entry: Chat Completions to it, with its key; a Mac's by host.docker.internal, Linux's by name
  printf 'LOCAL_MODELS=llamacpp:org/M-GGUF:Q4_K_M\n' >> "$ENV_FILE"
  local y; y="$(local_models_yaml)"
  assert_contains "$y" '- model_name: "lm/org/M-GGUF:Q4_K_M"'
  assert_contains "$y" 'model: "openai/org/M-GGUF:Q4_K_M"'
  assert_contains "$y" 'api_base: "http://host.docker.internal:11438/v1"'
  assert_contains "$y" "api_key: \"$k\""
  assert_contains "$y" "input_cost_per_token: 0"
  FAKE_OS=Linux; assert_contains "$(local_models_yaml)" 'api_base: "http://llamacpp:8080/v1"'; FAKE_OS=Darwin
  # the portal's file: llama.cpp ready, the model on disk and registered
  local_status_write
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); i=d["installed"][0]
assert d["runtime"]["kind"] == "llamacpp" and d["runtime"]["llamacpp"] == "ready", d["runtime"]
assert (i["runtime"], i["id"], i["present"], i["registered"], i["revision"]) == ("llamacpp", "org/M-GGUF:Q4_K_M", True, True, sys.argv[2]), i' "$(local_status_file)" "$SHA_A"
  # Remove: out of the gateway and llama.cpp, its files gone
  local_rm org/M-GGUF Q4_K_M > /dev/null 2>&1
  [ ! -e "$d/hub/models--org--M-GGUF" ]
  assert_eq "$(local_registry_rows)" ""
  assert_not_contains "$(cat "$d/etc/presets.ini")" "M-GGUF"
  assert_eq "$(tail -n 1 "$TMP/apply")" "local cli |LOCAL_MODELS|"
}

test_the_check_refuses_a_gated_model_a_missing_quantization_and_a_split_one_missing_a_part() {
  _lc_env; LC_PARTS=2 _lc_hub
  mkdir -p "$(local_dir)"
  echo 401 > "$TMP/hub-files/.api.code"
  assert_contains "$(_local_gguf_vet org/M-GGUF Q4_K_M "$TMP/man")" "no Hugging Face does not let this computer see it: a gated or private model needs a Hugging Face token"
  echo 404 > "$TMP/hub-files/.api.code"
  assert_eq "$(_local_gguf_vet org/M-GGUF Q4_K_M "$TMP/man")" "no Hugging Face has no model org/M-GGUF"
  rm "$TMP/hub-files/.api.code"
  assert_eq "$(_local_gguf_vet org/M-GGUF Q5_K_S "$TMP/man")" "no it has no GGUF file for Q5_K_S"
  assert_eq "$(_local_gguf_vet org/M-GGUF Q8_0 "$TMP/man")" "no it has 2 of the 3 parts of M-Q8_0"
  # every part of a whole split one, the first one named; the quantization in any case
  LC_PARTS=3 _lc_api
  local v; v="$(_local_gguf_vet org/M-GGUF q8_0 "$TMP/man")"
  assert_eq "${v%$'\t'*}" "$(printf 'sha %s\tQ8_0/M-Q8_0-00001-of-00003.gguf' "$SHA_A")"
  assert_eq "${v##*$'\t'}" 9000
  assert_eq "$(cut -f1 "$TMP/man" | tr '\n' ' ')" "Q8_0/M-Q8_0-00001-of-00003.gguf Q8_0/M-Q8_0-00002-of-00003.gguf Q8_0/M-Q8_0-00003-of-00003.gguf "
  [[ $(cut -f3 "$TMP/man" | head -n 1) =~ ^[0-9a-f]{64}$ ]]
  v="$(_local_gguf_vet org/M-GGUF Q4_K_M "$TMP/man")"
  assert_eq "$(cut -f1 "$TMP/man")" M-Q4_K_M.gguf
  kill "$HUB_PID"
}

test_cancel_deletes_what_arrived_but_never_another_quantization_of_the_same_repo() {
  _lc_env
  local h; h="$(rt_dir llamacpp)/hub/models--org--M-GGUF"
  mkdir -p "$h/blobs" "$(local_dir)"; printf x > "$h/blobs/$(printf '4%.0s' $(seq 64)).part"
  _local_discard llamacpp org/M-GGUF
  [ ! -e "$h" ]
  # with another quantization of it downloaded: only this download's parts
  mkdir -p "$h/blobs"; printf x > "$h/blobs/$(printf '4%.0s' $(seq 64)).part"; printf q4 > "$h/blobs/$(printf '1%.0s' $(seq 64))"
  printf 'Q8_0/M-Q8_0.gguf\t1\t%s\t\n' "$(printf '4%.0s' $(seq 64))" > "$(local_dir)/manifest.tsv"
  local_registry_put llamacpp org/M-GGUF:Q4_K_M org/M-GGUF Q4_K_M 2 - - - -
  _local_discard llamacpp org/M-GGUF
  [ ! -e "$h/blobs/$(printf '4%.0s' $(seq 64)).part" ] && [ -f "$h/blobs/$(printf '1%.0s' $(seq 64))" ]
}

# --- where downloads go ---

test_downloads_go_to_llamacpp_when_named_or_when_nothing_else_runs() {
  _lc_env
  export LOCAL_MLX=off
  assert_eq "$(local_runtime)" none
  assert_contains "$(local_how_text)" "Downloads go to llama.cpp (Settings › Local models › Runtimes), which is not running: install it in Settings › Local models › Runtimes (./stack runtimes install llamacpp)."
  rt_install llamacpp > /dev/null 2>&1
  assert_eq "$(local_runtime)" llamacpp
  rt_stop llamacpp > /dev/null 2>&1
  assert_eq "$(local_runtime)" none
  assert_contains "$(local_how_text)" "start it in Settings › Local models › Runtimes (./stack runtimes start llamacpp)."
  rt_start llamacpp > /dev/null 2>&1
  printf 'X=1\n' > "$ENV_FILE"   # (automatic: MLX off, no Docker Model Runner, no Ollama: llama.cpp)
  assert_eq "$(local_runtime)" llamacpp
  valid_local_entry llamacpp:org/M-GGUF:Q4_K_M
}

# --- Linux: the container ---

test_on_linux_it_is_a_profile_container_run_as_you_and_stop_stops_it() {
  _lc_env
  FAKE_OS=Linux
  docker() {
    printf '%s\n' "$*" >> "$TMP/docker"
    case "$*" in
      "info --format {{json .Runtimes}}") echo '{"runc":{}}' ;;
      "info -f {{.SecurityOptions}}") echo '[name=seccomp,profile=builtin]' ;;
      *" up -d llamacpp") : > "$TMP/lc-up" ;;
      *" ps --format {{.Health}} llamacpp") [ ! -f "$TMP/lc-up" ] || echo healthy ;;
      *" ps -a --format {{.State}} llamacpp") [ ! -f "$TMP/lc-up" ] || echo running ;;
      *" stop llamacpp") rm -f "$TMP/lc-up" ;;
    esac
  }
  : > "$TMP/docker"
  rt_install llamacpp > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  local d; d="$(rt_dir llamacpp)"
  assert_contains "$(cat "$TMP/docker")" "--profile llamacpp"
  assert_contains "$(cat "$TMP/docker")" " pull -q llamacpp"
  assert_contains "$(cat "$TMP/docker")" " up -d llamacpp"
  assert_eq "$(cat "$d/user")" "$(id -u):$(id -g)"
  [[ $(rt_llamacpp_key) =~ ^[0-9a-f]{64}$ ]] && [ -d "$d/hub" ] && [ ! -e "$d/gpu" ]
  assert_eq "$(rt_state llamacpp)" running
  assert_eq "$(rt_kind llamacpp)" container
  assert_eq "$(rt_address llamacpp)" "llamacpp:8080 (the model gateway's network only)"
  assert_eq "$(local_llamacpp_base)" "http://llamacpp:8080/v1"
  assert_contains " $(optional_services) " " llamacpp "
  # its models: through its container, with the header file mounted there
  : > "$TMP/docker"; _rt_ps llamacpp > /dev/null
  assert_contains "$(cat "$TMP/docker")" "exec -T llamacpp curl -s -m 3 -H @/etc/llamacpp/auth.hdr http://127.0.0.1:8080/models"
  : > "$TMP/docker"; rt_stop llamacpp > /dev/null 2>&1
  assert_contains "$(cat "$TMP/docker")" " stop llamacpp"
  assert_eq "$(rt_state llamacpp)" stopped
}
