# shellcheck shell=bash
# shellcheck disable=SC2016,SC2329  # literal $ in expected output; stubs are called by the code under test
# The model runtimes DevOS ADE installs and runs (lib/runtimes.sh, JON-829: Ollama). On a Mac: the pinned release
# downloaded (a stand-in curl serves it), checked against its SHA-256, unpacked only when it holds plain files and links
# beside them, run as a launchd user agent (a stand-in launchctl) on 127.0.0.1 with the stack's own folders, stopped,
# started, watched (a restart, a stop, a return: Activity), cancelled, removed with its models. On Linux: the "ollama"
# compose profile, its GPU overlay and the gateway's address. The helper's two requests, field by field. Nothing here
# reaches launchd, Docker or the network; tests/e2e/runtimes-mac.sh installs the real one.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/local_models.sh and lib/runtimes.sh

_rt_env() {
  mkdir -p "$STATE_DIR/status" "$STATE_DIR/requests" "$STATE_DIR/helper" "$TMP/bin" "$TMP/pkg"
  printf 'X=1\n' > "$ENV_FILE"
  export RT_POLL_S=0.1 RT_START_WAIT=5 ASSUME_YES=1 PATH="$TMP/bin:$PATH"
  FAKE_OS=Darwin; FAKE_ARCH=arm64
  uname() { case "${1:-}" in -s) echo "$FAKE_OS" ;; -m) echo "$FAKE_ARCH" ;; *) command uname "$@" ;; esac; }
  # launchd: an agent is loaded from bootstrap to bootout; while loaded, its Ollama answers (TMP/up holds its version)
  launchctl() {
    printf '%s\n' "$*" >> "$TMP/launchctl.args"
    case "$1" in
      print) [ -f "$TMP/loaded" ] || return 113
        printf '%s = {\n\tactive count = 1\n\tstate = running\n\truns = %s\n\tlast exit code = %s\n\tpid = 4242\n}\n' "$2" \
          "$(cat "$TMP/runs" 2>/dev/null || echo 1)" "$(cat "$TMP/lastexit" 2>/dev/null || echo '(never exited)')" ;;
      bootstrap) [ -f "$3" ] || return 5; : > "$TMP/loaded"; echo 0.40.11 > "$TMP/up" ;;
      bootout) rm -f "$TMP/loaded" "$TMP/up" ;;
    esac
  }
  # curl: GitHub's release file (TMP/slow: the first KB, then it hangs), its size, and the Ollama that answers
  cat > "$TMP/bin/curl" <<EOF
#!/bin/sh
T="$TMP"; out=''; url=''; head=0; prev=''
printf '%s\n' "\$*" >> "\$T/curl.args"
for a in "\$@"; do
  [ "\$prev" = -o ] && out="\$a"
  case "\$a" in -sSIL) head=1 ;; http://* | https://*) url="\$a" ;; esac
  prev="\$a"
done
case "\$url" in
  */api/version) [ -f "\$T/up" ] || exit 7; printf '{"version":"%s"}' "\$(cat "\$T/up")" ;;
  */api/ps) [ -f "\$T/up" ] || exit 7; cat "\$T/ps.json" 2>/dev/null || printf '{"models":[]}' ;;
  https://github.com/ollama/ollama/releases/download/v*/ollama-darwin.tgz)
    if [ "\$head" = 1 ]; then printf 'HTTP/2 302\r\nlocation: https://objects.example/x\r\n\r\nHTTP/2 200\r\ncontent-length: %s\r\n\r\n' "\$(wc -c < "\$T/ollama-darwin.tgz" | tr -d ' ')"; exit 0; fi
    if [ -f "\$T/slow" ]; then head -c 1024 "\$T/ollama-darwin.tgz" > "\$out"; exec sleep 30; fi
    cat "\$T/ollama-darwin.tgz" > "\$out" ;;
  *) exit 6 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  # the release: an ollama program, a library and a link to it beside it (as Ollama's own archive has)
  printf '#!/bin/sh\necho "ollama version is 0.40.11"\n' > "$TMP/pkg/ollama"; chmod +x "$TMP/pkg/ollama"
  printf 'lib' > "$TMP/pkg/libggml-base.0.dylib"; ln -sf libggml-base.0.dylib "$TMP/pkg/libggml-base.dylib"
  head -c 300000 /dev/urandom > "$TMP/pkg/llama-server"      # (bulk: the download takes more than one look)
  tar -czf "$TMP/ollama-darwin.tgz" -C "$TMP/pkg" ollama libggml-base.0.dylib libggml-base.dylib llama-server
  _rt_sha256 "$TMP/ollama-darwin.tgz" > "$TMP/sha"
  rt_pin() { case "$1" in OLLAMA_VERSION) echo 0.40.11 ;; OLLAMA_SHA256_DARWIN) cat "$TMP/sha" ;; esac; }
  config_apply() { printf '%s|%s|%s\n' "$*" "$CFG_ORDER" "$(cfg_new LOCAL_MODELS)" >> "$TMP/apply"; }   # (what it would write)
}
_job() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(rt_job_file)" "$1"; }
_events() { cut -f2- "$(rt_events_file)" 2>/dev/null | tr '\t' ' '; }

# --- the pins ---

test_the_pins_are_a_version_and_a_sha256_and_linux_pins_the_same_version_by_digest() {
  [[ $(rt_pin OLLAMA_VERSION) =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [[ $(rt_pin OLLAMA_SHA256_DARWIN) =~ ^[0-9a-f]{64}$ ]]
  grep -Eq '^    image: ollama/ollama:[0-9.]+@sha256:[0-9a-f]{64}$' "$STACK_DIR/compose.yaml"
  uname() { case "${1:-}" in -s) echo Linux ;; *) command uname "$@" ;; esac; }
  assert_eq "$(rt_pinned_version ollama)" "$(rt_pin OLLAMA_VERSION)"
}

# Linux: Ollama publishes nothing and shares an internal network with LiteLLM alone; its gate publishes 127.0.0.1:11434
# alone (and lets only loopback names through: tests/caddy-validate.sh runs it), both hardened like the others
test_the_container_is_reached_through_its_gate_on_loopback_only_and_drops_its_privileges() {
  local svc gate
  svc="$(awk '/^  ollama:/{s=1;print;next} s&&/^  [a-z]/{exit} s' "$STACK_DIR/compose.yaml")"
  gate="$(awk '/^  ollama-gate:/{s=1;print;next} s&&/^  [a-z]/{exit} s' "$STACK_DIR/compose.yaml")"
  assert_contains "$svc" 'profiles: ["ollama"]'
  assert_not_contains "$svc" "ports:"
  assert_contains "$svc" "networks: [ollama, ollama-out]"
  assert_contains "$svc" "cap_drop: [ALL]"
  assert_contains "$svc" "no-new-privileges"
  assert_contains "$svc" 'OLLAMA_NO_CLOUD: "1"'
  assert_contains "$gate" 'profiles: ["ollama"]'
  assert_contains "$gate" '"127.0.0.1:11434:11434"'
  assert_contains "$gate" "networks: [ollama-out]"
  assert_contains "$gate" '"/etc/caddy/ollama-gate.caddy"'
  assert_contains "$gate" "image: $(awk '/^  caddy:$/,/^    image:/' "$STACK_DIR/compose.yaml" | sed -n 's/^    image: //p')"   # (the main Caddy's, bumped with it)
  assert_contains "$gate" "read_only: true"
  assert_contains "$gate" "cap_drop: [ALL]"
  assert_contains "$gate" "no-new-privileges"
  assert_contains "$gate" 'BN_CONFIG_SUM: ${BN_OLLAMA_GATE_CONFIG_SUM:-}'
  assert_contains "$(status_url ollama-gate)" "http://127.0.0.1:11434"
  assert_contains "$(status_url ollama)" "LiteLLM's alone"
  # its gate checks the Host; nothing in the main Caddy names Ollama (the gate's file is not imported there)
  local g; g="$(grep -v '^[[:space:]]*#' "$STACK_DIR/caddy/ollama-gate.caddy" | tr -d '\t')"
  assert_contains "$g" "@loopback host 127.0.0.1 localhost"
  assert_contains "$g" "reverse_proxy ollama:11434"
  assert_contains "$g" "respond \"Forbidden: this Ollama answers only requests for 127.0.0.1 or localhost\" 403"
  for g in "$STACK_DIR"/caddy/Caddyfile "$STACK_DIR"/caddy/*.caddy; do
    [ "${g##*/}" = ollama-gate.caddy ] || assert_not_contains "$(cat "$g")" "ollama"
  done
}

# compose.yaml as Docker Compose renders it with the profile (no daemon): who is on Ollama's networks, and what is published
test_compose_renders_ollama_isolated_behind_its_gate() {
  [ -n "${BN_REAL_DOCKER:-}" ] && "$BN_REAL_DOCKER" compose version >/dev/null 2>&1 || { echo "no docker compose" >&2; return 77; }
  docker() { case "$*" in *" config --format json") "$BN_REAL_DOCKER" "$@" ;; *) echo "unexpected docker $*" >&2; return 97 ;; esac; }
  printf 'POSTGRES_PASSWORD=p\nRUSTFS_ACCESS_KEY=a\nRUSTFS_SECRET_KEY=s\nLITELLM_MASTER_KEY=m\nLITELLM_SALT_KEY=s\nLITELLM_UI_PASSWORD=u\nWEBUI_SECRET_KEY=w\nOPENWEBUI_ADMIN_EMAIL=a@b.c\nOPENWEBUI_ADMIN_PASSWORD=p\nSHARED_MCP_TOKEN=t\nSTT_PROVIDER=bedrock\n' > "$ENV_FILE"
  local out; out="$(_RT_PROFILE=ollama dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c '
import json, sys
d = json.load(sys.stdin); s = d["services"]
on = lambda n: sorted(k for k, v in s.items() if n in (v.get("networks") or {}))
assert on("ollama") == ["litellm", "ollama"], on("ollama")
assert on("ollama-out") == ["ollama", "ollama-gate"], on("ollama-out")
assert d["networks"]["ollama"]["internal"] is True and not d["networks"]["ollama-out"].get("internal"), d["networks"]
assert "ports" not in s["ollama"], s["ollama"].get("ports")
assert [(p["host_ip"], str(p["published"]), p["target"]) for p in s["ollama-gate"]["ports"]] == [("127.0.0.1", "11434", 11434)], s["ollama-gate"]["ports"]
assert s["ollama-gate"]["user"] == "65534:65534" and s["ollama-gate"]["read_only"] is True and s["ollama-gate"]["cap_drop"] == ["ALL"], s["ollama-gate"]
# published on 11434: no other service
assert not [k for k, v in s.items() if k != "ollama-gate" and any(str(p.get("published")) == "11434" for p in v.get("ports") or [])]
'
  # without the profile: neither service (and nothing on 11434)
  out="$(dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); assert not {"ollama", "ollama-gate"} & set(d["services"]), sorted(d["services"])'
}

# --- macOS: install, the agent, stop, start, the watch ---

test_status_the_watch_and_the_hooks_run_under_errexit_with_nothing_installed_or_it_stopped() {
  _rt_env                                     # (this suite runs with errexit and pipefail, as ./stack does: called directly)
  cmd_runtimes status > "$TMP/out"
  assert_contains "$(cat "$TMP/out")" "Ollama      not installed (./stack runtimes install ollama: about 180 MB)"
  runtimes_watch; runtimes_up_hook; runtimes_down_hook; rt_status_write
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d["runtimes"][0]
assert (r["state"], r["managed"], r["version"], r["pinned"], r["restarts"], r["last_exit"]) == ("not-installed", False, "", "0.40.11", None, None), r
assert d["job"] == {"state": "idle"} and d["events"] == [], d' "$(rt_status_file)"
  rt_install ollama > /dev/null 2>&1
  rt_stop ollama > /dev/null 2>&1
  rm -f "$(rt_dir ollama)/watch" "$(rt_dir ollama)/server.log"
  runtimes_watch; cmd_runtimes status > "$TMP/out"; cmd_runtimes logs ollama > /dev/null; cmd_runtimes logs ollama --portal
  assert_contains "$(cat "$TMP/out")" "Ollama      stopped (./stack runtimes start ollama)"
  ( cmd_runtimes bogus ) 2>/dev/null && return 1
  return 0
}

test_install_downloads_the_pinned_file_checks_it_and_runs_it_as_this_stacks_agent() {
  _rt_env
  assert_eq "$(rt_state ollama)" not-installed
  rt_install ollama > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_eq "$(rt_state ollama)" running
  assert_eq "$(rt_installed_version ollama)" 0.40.11
  local d; d="$(rt_dir ollama)"
  [ -x "$d/bin/ollama" ] && [ -L "$d/bin/libggml-base.dylib" ] && [ ! -e "$d/ollama-darwin-0.40.11.tgz.part" ] && [ ! -e "$d/bin.new" ]
  assert_contains "$(cat "$TMP/curl.args")" "--proto =https --proto-redir =https"
  assert_contains "$(cat "$TMP/curl.args")" "https://github.com/ollama/ollama/releases/download/v0.40.11/ollama-darwin.tgz"
  # the agent: this stack's label, 127.0.0.1 only, its own models folder and HOME, Ollama's cloud off, mode 600
  local p; p="$(rt_plist ollama)"
  assert_contains "$p" "$HOME/Library/LaunchAgents/dev.devos.ade.ollama."
  assert_eq "$(stat -f %Lp "$p" 2>/dev/null || stat -c %a "$p")" 600
  assert_contains "$(cat "$p")" "<string>$d/bin/ollama</string><string>serve</string>"
  assert_contains "$(cat "$p")" "<key>OLLAMA_HOST</key><string>127.0.0.1:11434</string>"
  assert_contains "$(cat "$p")" "<key>OLLAMA_MODELS</key><string>$d/models</string>"
  assert_contains "$(cat "$p")" "<key>OLLAMA_NO_CLOUD</key><string>1</string>"
  assert_contains "$(cat "$p")" "<key>HOME</key><string>$d/home</string>"
  ! command -v plutil >/dev/null 2>&1 || plutil -lint "$p" >/dev/null
  assert_contains "$(cat "$TMP/launchctl.args")" "bootstrap gui/$(id -u) $p"
  # the job, the event, the portal's file
  assert_eq "$(_job state)" done
  assert_eq "$(_events)" "ollama installed Ollama 0.40.11 was installed and runs on 127.0.0.1:11434"
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); r=d["runtimes"][0]
assert (r["id"], r["state"], r["managed"], r["kind"], r["version"], r["address"], r["restarts"]) == ("ollama", "running", True, "agent", "0.40.11", "127.0.0.1:11434", 0), r
assert d["os"] == "mac" and d["job"]["state"] == "done" and d["events"][0]["kind"] == "installed"' "$(rt_status_file)"
  ( rt_install ollama ) > /dev/null 2>&1   # (again: the same version is fetched and swapped in; still running)
  assert_eq "$(rt_state ollama)" running
  # Update (Settings' "Update to …": an install over an older version): the pinned one in its place, its models kept,
  # the running agent ended and started again on the new program
  echo 0.40.10 > "$d/installed"; echo m > "$d/models/kept"; : > "$TMP/launchctl.args"
  rt_install ollama > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_eq "$(rt_installed_version ollama)" 0.40.11
  [ -f "$d/models/kept" ] && [ ! -e "$d/bin.old" ]
  assert_contains "$(cat "$TMP/launchctl.args")" "bootout gui/$(id -u)/$(rt_label ollama)"
  assert_contains "$(cat "$TMP/launchctl.args")" "bootstrap gui/$(id -u) $p"
  assert_eq "$(rt_state ollama)" running
}

test_a_file_that_does_not_match_its_sha256_is_deleted_and_nothing_is_installed() {
  _rt_env
  printf '%064d\n' 0 > "$TMP/sha"
  ! ( rt_install ollama ) > "$TMP/out" 2>&1
  assert_contains "$(cat "$TMP/out")" "does not match the SHA-256 DevOS ADE pins"
  ! rt_installed ollama
  [ ! -e "$(rt_dir ollama)/ollama-darwin-0.40.11.tgz.part" ] && [ ! -e "$(rt_dir ollama)/bin" ] && [ ! -e "$(rt_plist ollama)" ]
  assert_eq "$(_job state)" failed
  assert_contains "$(_events)" "ollama failed What arrived does not match"
  [ ! -e "$(rt_root)/job.pid" ]
}

test_an_archive_with_anything_but_plain_files_and_links_beside_them_is_refused() {
  _rt_env
  python3 -I - "$TMP" <<'PY'
import io, sys, tarfile
T = sys.argv[1]
def make(name, extra):
    with tarfile.open(f"{T}/bad-{name}.tgz", "w:gz") as t:
        i = tarfile.TarInfo("ollama"); i.size = 3; i.mode = 0o755; t.addfile(i, io.BytesIO(b"#!x"))
        for n, typ, link in extra:
            i = tarfile.TarInfo(n); i.type = typ; i.linkname = link; i.mode = 0o644
            i.size = 1 if typ == tarfile.REGTYPE else 0
            t.addfile(i, io.BytesIO(b"x") if typ == tarfile.REGTYPE else None)
R, S, H, F, C = tarfile.REGTYPE, tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE
make("dotdot", [("../evil", R, "")])
make("deep", [("lib/../../evil", R, "")])
make("linkout", [("libx.dylib", S, "/etc/passwd")])
make("linkup", [("libx.dylib", S, "../evil")])
make("linksub", [("libx.dylib", S, "lib/x")])
make("hard", [("libx.dylib", H, "ollama")])
make("fifo", [("pipe", F, "")])
make("dev", [("tty", C, "")])
make("ok", [("libx.0.dylib", R, ""), ("libx.dylib", S, "libx.0.dylib")])
PY
  local c
  for c in dotdot deep linkout linkup linksub hard fifo dev; do
    ! _rt_unpack "$TMP/bad-$c.tgz" "$TMP/out-$c" || { echo "unpacked: $c" >&2; return 1; }
  done
  [ ! -e "$TMP/evil" ] && [ ! -e "$TMP/out-dotdot" ]
  _rt_unpack "$TMP/bad-ok.tgz" "$TMP/out-ok"
  [ -x "$TMP/out-ok/ollama" ] && [ -L "$TMP/out-ok/libx.dylib" ]
}

test_cancel_stops_the_download_and_keeps_what_arrived_for_the_next_install() {
  _rt_env
  : > "$TMP/slow"
  ( rt_install ollama ) > "$TMP/out" 2>&1 &
  local bg=$! part; part="$(rt_dir ollama)/ollama-darwin-0.40.11.tgz.part"
  _wait_for '[ "$(wc -c < "$part" 2>/dev/null | tr -d " ")" = 1024 ] && [ -s "$(rt_root)/dl.pid" ]'
  assert_eq "$(rt_state ollama)" installing
  assert_eq "$(_job op)" install
  rt_cancel > /dev/null
  wait "$bg" || true
  assert_eq "$(_job state)" cancelled
  [ -f "$part" ] && ! rt_installed ollama && [ ! -e "$(rt_root)/job.pid" ] && [ ! -e "$(rt_root)/dl.pid" ] && [ ! -e "$(_rt_cancel_file)" ]
  # the next install continues from it (curl -C -)
  rm -f "$TMP/slow"; : > "$TMP/curl.args"
  rt_install ollama > /dev/null 2>&1
  assert_contains "$(cat "$TMP/curl.args")" "-C - -o $part"
  assert_eq "$(rt_state ollama)" running
  # (nothing to cancel: it says so)
  assert_contains "$(rt_cancel 2>&1)" "No install is running"
}

test_stop_start_down_and_up_take_the_agent_away_and_bring_it_back() {
  _rt_env
  rt_install ollama > /dev/null 2>&1
  rt_stop ollama > /dev/null 2>&1
  assert_eq "$(rt_state ollama)" stopped
  [ ! -e "$(rt_plist ollama)" ]                                     # (a login does not start it again)
  assert_contains "$(cat "$TMP/launchctl.args")" "bootout gui/$(id -u)/$(rt_label ollama)"
  rt_start ollama > /dev/null 2>&1
  assert_eq "$(rt_state ollama)" running
  runtimes_down_hook
  assert_eq "$(rt_state ollama)" stopped
  runtimes_up_hook
  assert_eq "$(rt_state ollama)" running
  assert_eq "$(cut -f3 "$(rt_events_file)" | tr '\n' ' ')" "installed stopped started "
  # (on Linux the hooks leave it to compose)
  FAKE_OS=Linux; : > "$TMP/launchctl.args"
  runtimes_down_hook; runtimes_up_hook
  [ ! -s "$TMP/launchctl.args" ]
}

test_the_watch_records_an_end_a_stop_answering_and_a_return_but_not_our_own_changes() {
  _rt_env
  rt_install ollama > /dev/null 2>&1
  : > "$(rt_events_file)"
  runtimes_watch
  [ ! -s "$(rt_events_file)" ]                                       # (installed and marked: nothing new)
  echo 3 > "$TMP/runs"; echo 2 > "$TMP/lastexit"                     # launchd started it again twice
  runtimes_watch
  assert_eq "$(_events)" "ollama restart Ollama ended (exit code 2) and was started again"
  rm -f "$TMP/up"; : > "$(rt_events_file)"                           # loaded, but nothing answers
  runtimes_watch
  assert_eq "$(_events)" "ollama down Ollama stopped answering on 127.0.0.1:11434"
  echo 0.40.11 > "$TMP/up"; : > "$(rt_events_file)"
  runtimes_watch
  assert_eq "$(_events)" "ollama up Ollama answers again on 127.0.0.1:11434"
  : > "$(rt_events_file)"
  rt_stop ollama > /dev/null 2>&1; : > "$(rt_events_file)"
  runtimes_watch; rt_start ollama > /dev/null 2>&1; : > "$(rt_events_file)"; runtimes_watch
  [ ! -s "$(rt_events_file)" ]                                       # (a stop and a start of ours are not news)
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["runtimes"][0]; assert r["restarts"] == 2 and r["last_exit"] == 2, r' "$(rt_status_file)"
}

test_an_ollama_of_yours_is_never_installed_over_stopped_or_removed() {
  _rt_env
  echo 0.39.0 > "$TMP/up"                                            # (the Ollama app, say)
  assert_eq "$(rt_state ollama)" external
  ! ( rt_install ollama ) > "$TMP/out" 2>&1
  assert_contains "$(cat "$TMP/out")" "already answers on 127.0.0.1:11434"
  ! ( rt_stop ollama ) 2>/dev/null
  ! ( rt_uninstall ollama ) 2>/dev/null
  [ ! -e "$(rt_dir ollama)/bin" ] && [ ! -s "$TMP/launchctl.args" ] && [ -f "$TMP/up" ]
  rt_status_write
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["runtimes"][0]; assert (r["state"], r["managed"], r["version"]) == ("external", False, "0.39.0"), r' "$(rt_status_file)"
}

test_uninstall_takes_its_models_out_of_the_gateway_and_deletes_it_with_them() {
  _rt_env
  rt_install ollama > /dev/null 2>&1
  printf 'X=1\nLOCAL_MODELS=dmr:hf.co/a/b:q4_k_m,ollama:hf.co/c/d:Q8_0\n' > "$ENV_FILE"
  mkdir -p "$(rt_dir ollama)/models/blobs"; printf 'w' > "$(rt_dir ollama)/models/blobs/sha256-1"
  rt_uninstall ollama > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_eq "$(cat "$TMP/apply")" "local cli |LOCAL_MODELS|dmr:hf.co/a/b:q4_k_m"   # (one change: the gateway lets them go)
  [ ! -e "$(rt_dir ollama)" ] && [ ! -e "$(rt_plist ollama)" ] && [ ! -f "$TMP/loaded" ]
  assert_eq "$(rt_state ollama)" not-installed
  assert_contains "$(_events)" "ollama removed Ollama was removed with its models"
  ! ( rt_uninstall ollama ) 2>/dev/null                              # (nothing of ours left)
}

test_logs_are_printable_and_the_portal_gets_a_copy() {
  _rt_env
  mkdir -p "$(rt_dir ollama)"
  printf 'time=1 level=INFO msg=up\n\033[31mred\033[0m\001\n' > "$(rt_dir ollama)/server.log"
  assert_eq "$(rt_logs_text ollama)" "$(printf 'time=1 level=INFO msg=up\nred')"
  cmd_runtimes logs ollama --portal
  assert_eq "$(cat "$STATE_DIR/status/runtime-logs/ollama.txt")" "$(printf 'time=1 level=INFO msg=up\nred')"
  ! ( cmd_runtimes logs ../x ) 2>/dev/null
}

# the models loaded now, from Ollama's /api/ps as it answers (each model's details are an object of their own, before
# size_vram): name, size and the part in GPU memory; a name is printable, a broken answer is nothing
test_the_models_loaded_are_read_with_their_gpu_memory() {
  _rt_env
  rt_install ollama > /dev/null 2>&1 || return 1
  cat > "$TMP/ps.json" <<'JSON'
{"models":[{"name":"qwen3:8b","model":"qwen3:8b","size":6000000000,"digest":"2ae6","details":{"parent_model":"","format":"gguf","family":"qwen3","families":["qwen3"],"parameter_size":"8.2B","quantization_level":"Q4_K_M"},"expires_at":"2026-10-28T14:38:31.83753-07:00","size_vram":5000000000,"context_length":4096},
 {"name":"hf.co/bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M\u001b[31m","model":"x","size":100000000,"details":{"format":"gguf"},"size_vram":0}]}
JSON
  assert_eq "$(_rt_ollama_ps)" "$(printf 'qwen3:8b\t6000000000\t5000000000\nhf.co/bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M31m\t100000000\t0')"
  rt_status_write
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["runtimes"][0]
assert r["loaded"][0] == {"name": "qwen3:8b", "bytes": 6000000000, "gpu_bytes": 5000000000}, r["loaded"]
assert (r["memory_bytes"], r["gpu_bytes"]) == (6100000000, 5000000000), r' "$(rt_status_file)"
  printf 'not json' > "$TMP/ps.json"; assert_eq "$(_rt_ollama_ps)" ""
}

# --- Linux: the compose profile ---

test_on_linux_it_is_a_profile_container_with_its_gpu_and_the_gateway_reaches_it_by_name() {
  _rt_env
  FAKE_OS=Linux
  docker() { printf '%s\n' "$*" >> "$TMP/docker"; }
  : > "$TMP/docker"; dc ps >/dev/null
  assert_not_contains "$(cat "$TMP/docker")" "--profile ollama"
  assert_eq "$(local_ollama_base)" "http://host.docker.internal:11434"
  mkdir -p "$(rt_dir ollama)"; echo 0.40.11 > "$(rt_dir ollama)/installed"
  : > "$TMP/docker"; dc ps >/dev/null
  assert_contains "$(cat "$TMP/docker")" "--profile ollama"
  assert_contains " $(optional_services) " " ollama ollama-gate "
  assert_eq "$(local_ollama_base)" "http://ollama:11434"
  assert_not_contains "$(compose_overlays | tr '\n' ' ')" "compose.ollama-gpu.yaml"
  echo nvidia > "$(rt_dir ollama)/gpu"
  assert_contains "$(compose_overlays | tr '\n' ' ')" "compose.ollama-gpu.yaml"
  assert_eq "$(rt_kind ollama)" container
  # Stop stops Ollama and its gate (nothing answers on 11434 then)
  : > "$TMP/docker"; rt_stop ollama > /dev/null 2>&1
  assert_contains "$(cat "$TMP/docker")" " stop ollama ollama-gate"
  # (a Mac never has the profile, whatever is in the folder)
  FAKE_OS=Darwin; : > "$TMP/docker"; dc ps >/dev/null
  assert_not_contains "$(cat "$TMP/docker")" "--profile ollama"
}

# --- where downloads go ---

test_local_runtime_sends_downloads_to_the_one_named() {
  _rt_env
  local_mlx_capable() { return 0; }; local_dmr_state() { echo ready; }; local_ollama_state() { echo ready; }
  assert_eq "$(local_runtime)" mlx
  for v in mlx dmr ollama; do printf 'LOCAL_RUNTIME=%s\n' "$v" > "$ENV_FILE"; assert_eq "$(local_runtime)" "$v"; done
  printf 'LOCAL_RUNTIME=auto\n' > "$ENV_FILE"; assert_eq "$(local_runtime)" mlx
  local_ollama_state() { echo not-installed; }
  printf 'LOCAL_RUNTIME=ollama\n' > "$ENV_FILE"
  assert_eq "$(local_runtime)" none
  assert_contains "$(local_how_text)" "Downloads go to Ollama (Settings › Local models › Runtimes), which is not running: install it"
  _sv_local_runtime "" && _sv_local_runtime auto && _sv_local_runtime ollama
  ! _sv_local_runtime lmstudio 2>/dev/null && ! _sv_local_runtime 'ollama;x' 2>/dev/null
}

# --- the update helper's requests ---

test_the_helper_takes_a_runtime_request_field_by_field() {
  . "$STACK_DIR/lib/helper.sh"; . "$STACK_DIR/lib/settings_helper.sh"
  _rt_env
  local now n auth out op bad
  now="$(date +%s)"; n="$(printf 'cd%.0s' $(seq 16))"; auth="$(printf 'correct horse battery' | openssl base64 -A)"
  mk() { printf '%s' "$1" > "$TMP/act-$n.json"; }
  for op in install start uninstall; do
    mk "{\"action\":\"local-runtime\",\"requested_at\":$now,\"nonce\":\"$n\",\"auth\":\"$auth\",\"op\":\"$op\",\"id\":\"ollama\"}"
    out="$(act_check_request "$TMP/act-$n.json" "act-$n.json" 2>&1)" || { echo "$out" >&2; return 1; }
    assert_contains "$out" "local-runtime $n"
    assert_contains "$out" "$op|ollama"
  done
  for op in stop cancel logs; do
    mk "{\"action\":\"local-runtime-stop\",\"requested_at\":$now,\"nonce\":\"$n\",\"op\":\"$op\",\"id\":\"ollama\"}"
    out="$(act_check_request "$TMP/act-$n.json" "act-$n.json" 2>&1)" || { echo "$out" >&2; return 1; }
    assert_contains "$out" "local-runtime-stop $n - - $op|ollama"
  done
  # no password for a change, a password on a stop, another op or id, or anything more: not a request
  for bad in "\"action\":\"local-runtime\",\"requested_at\":$now,\"nonce\":\"$n\",\"op\":\"install\",\"id\":\"ollama\"" \
             "\"action\":\"local-runtime\",\"requested_at\":$now,\"nonce\":\"$n\",\"auth\":\"$auth\",\"op\":\"stop\",\"id\":\"ollama\"" \
             "\"action\":\"local-runtime\",\"requested_at\":$now,\"nonce\":\"$n\",\"auth\":\"$auth\",\"op\":\"install\",\"id\":\"vllm\"" \
             "\"action\":\"local-runtime\",\"requested_at\":$now,\"nonce\":\"$n\",\"auth\":\"$auth\",\"op\":\"install\",\"id\":\"ollama\",\"url\":\"https://evil\"" \
             "\"action\":\"local-runtime-stop\",\"requested_at\":$now,\"nonce\":\"$n\",\"auth\":\"$auth\",\"op\":\"stop\",\"id\":\"ollama\"" \
             "\"action\":\"local-runtime-stop\",\"requested_at\":$now,\"nonce\":\"$n\",\"op\":\"uninstall\",\"id\":\"ollama\"" \
             "\"action\":\"local-runtime-stop\",\"requested_at\":$now,\"nonce\":\"$n\",\"op\":\"stop\",\"id\":\"ollama; rm -rf /\""; do
    mk "{$bad}"
    ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1 || { echo "taken: $bad" >&2; return 1; }
  done
  case " $LOCAL_HELPER_ACTIONS " in *" local-runtime "*) ;; *) return 1 ;; esac
  case " $LOCAL_HELPER_ACTIONS " in *" local-runtime-stop "*) ;; *) return 1 ;; esac
}

test_a_runtime_request_runs_the_stack_command_and_waits_for_a_running_job() {
  . "$STACK_DIR/lib/helper.sh"; . "$STACK_DIR/lib/settings_helper.sh"
  _rt_env
  STACK_DIR="$TMP/fakestack"; mkdir -p "$STACK_DIR"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/stack.args"\n' "$TMP" > "$STACK_DIR/stack"; chmod +x "$STACK_DIR/stack"
  runtime_helper_start local-runtime-stop 'stop|ollama' "$(printf 'a%.0s' $(seq 32))"
  _wait_for '[ -s "$TMP/stack.args" ]'
  assert_eq "$(cat "$TMP/stack.args")" "runtimes stop ollama"
  : > "$TMP/stack.args"
  runtime_helper_start local-runtime-stop 'logs|ollama' "$(printf 'b%.0s' $(seq 32))"
  _wait_for '[ -s "$TMP/stack.args" ]'
  assert_eq "$(cat "$TMP/stack.args")" "runtimes logs ollama --portal"
  # while a job runs, only a cancel or a log read goes through
  mkdir -p "$(rt_root)"; printf '%s\n' "$$" > "$(rt_root)/job.pid"; printf '{"id":"ollama","op":"install","state":"running"}\n' > "$(rt_job_file)"
  _refuse_diag() { printf '%s\n' "$1" >> "$TMP/refused"; }
  : > "$TMP/stack.args"
  runtime_helper_start local-runtime 'uninstall|ollama' "$(printf 'c%.0s' $(seq 32))"
  assert_contains "$(cat "$TMP/refused")" "a runtime job is already running"
  runtime_helper_start local-runtime-stop 'cancel|ollama' "$(printf 'd%.0s' $(seq 32))"
  _wait_for '[ -s "$TMP/stack.args" ]'
  assert_eq "$(cat "$TMP/stack.args")" "runtimes cancel ollama"
}

_wait_for() { local n=0; until eval "$1"; do sleep 0.1; n=$((n + 1)); [ "$n" -lt 150 ] || { echo "timed out waiting for: $1" >&2; return 1; }; done; }
