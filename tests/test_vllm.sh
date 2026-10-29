# shellcheck shell=bash
# shellcheck disable=SC2016,SC2329  # literal $ in expected output; stubs are called by the code under test
# vLLM as a runtime DevOS ADE installs and runs on Linux (lib/runtimes.sh, JON-829) and its downloads
# (lib/local_models.sh): the pins; the container's isolation, as Compose renders it; where it runs (NVIDIA GPUs, or the
# CPU build on x86-64 with AVX2); an install with no model yet ("waiting", no container); a model's safetensors weights
# downloaded for real (lib/hf_fetch.py and curl, against the stand-in Hub on 127.0.0.1: tests/fixtures/hf_hub_server.py),
# only the files that load it, then served — etc/serve.yaml with its name, key, capped context and tool-call parser —
# and registered as the one vLLM model; another one switching it, Serve switching back without a download, one it cannot
# load leaving the one before served; the refusals (code of its own, MLX, no weights); Remove. Nothing here reaches
# Docker or the network.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/local_models.sh and lib/runtimes.sh

SHA_A="$(printf 'a%.0s' $(seq 40))"
SHA_B="$(printf 'b%.0s' $(seq 40))"

_vl_env() {
  mkdir -p "$STATE_DIR/status" "$STATE_DIR/requests" "$STATE_DIR/helper" "$TMP/bin"
  printf 'X=1\nLOCAL_RUNTIME=vllm\n' > "$ENV_FILE"
  export RT_POLL_S=0.1 RT_START_WAIT=5 RT_VLLM_WAIT=8 LOCAL_POLL_S=0.1 ASSUME_YES=1 LOCAL_MLX=off
  export RT_NVIDIA_DEV="$TMP/no-nvidiactl" RT_CPUINFO="$TMP/cpuinfo" PATH="$TMP/bin:$PATH"
  # curl: the stand-in Hub on its own port only (the real curl: the shim guards this computer's addresses for a live
  # DevOS ADE, and that one is the test's own server)
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in http://127.0.0.1:*) exec "%s" "$@" ;; esac; done\nexit 6\n' "${BN_REAL_CURL:?}" > "$TMP/bin/curl"
  chmod +x "$TMP/bin/curl"
  printf 'processor\t: 0\nflags\t\t: fpu sse2 avx avx2 fma\n' > "$TMP/cpuinfo"
  FAKE_OS=Linux; FAKE_ARCH=x86_64
  uname() { case "${1:-}" in -s) echo "$FAKE_OS" ;; -m) echo "$FAKE_ARCH" ;; *) command uname "$@" ;; esac; }
  # Docker: its runtimes, the image's pull, and vLLM's container — up (TMP/vl-up), healthy unless TMP/vl-fail (then it
  # ends and Docker starts it again: RestartCount 1), removed, stopped; its log
  docker() {
    printf '%s\n' "$*" >> "$TMP/docker"
    case "$*" in
      "info --format {{json .Runtimes}}") if [ -f "$TMP/nvidia" ]; then echo '{"nvidia":{},"runc":{}}'; else echo '{"runc":{}}'; fi ;;
      "info -f {{.SecurityOptions}}") echo '[name=seccomp,profile=builtin]' ;;
      *" pull -q vllm") : ;;
      *" up -d --force-recreate vllm" | *" up -d vllm")
        if [ -f "$TMP/vl-upfail" ]; then echo "Error response from daemon: no such image: vllm/vllm-openai-cpu" >&2; return 1; fi
        : > "$TMP/vl-up"; cp "$(rt_dir vllm)/etc/serve.yaml" "$TMP/served.yaml" 2>/dev/null || true ;;
      *" ps --format {{.Health}} vllm") [ -f "$TMP/vl-up" ] && { [ -f "$TMP/vl-fail" ] && echo starting || echo healthy; } ;;
      *" ps -a --format {{.State}} vllm") [ ! -f "$TMP/vl-up" ] || echo running ;;
      *" ps -aq vllm") [ ! -f "$TMP/vl-up" ] || echo cid-vllm ;;
      "inspect -f {{.RestartCount}} cid-vllm") [ -f "$TMP/vl-fail" ] && echo 1 || echo 0 ;;
      *" rm -sf vllm" | *" stop vllm") rm -f "$TMP/vl-up" ;;
      *" config --images vllm") if [ -f "$(rt_dir vllm)/gpu" ]; then echo vllm/vllm-openai:gpu; else echo vllm/vllm-openai-cpu:cpu; fi ;;
      *" logs --no-color --tail "*" vllm") [ -f "$TMP/vl-up" ] || return 0   # (no container, no log)
        if [ -f "$TMP/vl-log" ]; then cat "$TMP/vl-log"; else echo "ValueError: Qwen9ForCausalLM is not supported"; fi ;;
    esac
  }
  config_apply() { printf '%s|%s|%s\n' "$*" "$CFG_ORDER" "$(cfg_new LOCAL_MODELS)" >> "$TMP/apply"; }   # (what it would write)
  local_dmr_state() { echo not-installed; }   # (no Docker Model Runner here)
  : > "$TMP/docker"
}
_wait_for() { local n=0; until eval "$1"; do sleep 0.1; n=$((n + 1)); [ "$n" -lt 150 ] || { echo "timed out waiting for: $1" >&2; return 1; }; done; }
_reg() { local_registry_rows | awk -F'\t' -v i="$1" '$1 == "vllm" && $2 == i { print $2 "|" $7 "|" $8 "|" $11 }'; }

# The stand-in Hub serving one repo (it answers the same for every name): ID at SHA, with TAGS. Its files: the weights,
# their config, the tokenizer's (TOOLS=1: Qwen's <tool_call> among its tokens), a generation config, merges — and what is
# never fetched: a pickle, a folder of other weights, a README. CTX: config.json's max_position_embeddings
_vl_repo() {
  local id="$1" sha="$2" tags="${3:-}" ctx="${CTX:-32768}" am=''
  rm -rf "$TMP/hub-files"; mkdir -p "$TMP/hub-files/original"
  head -c 300000 /dev/urandom > "$TMP/hub-files/model.safetensors"
  [ -z "${AUTO_MAP:-}" ] || am=', "auto_map": {"AutoModel": "m.M"}'
  printf '{"model_type": "qwen2", "architectures": ["Qwen2ForCausalLM"], "max_position_embeddings": %s%s}\n' "$ctx" "$am" > "$TMP/hub-files/config.json"
  if [ "${TOOLS:-1}" = 1 ]; then printf '{"added_tokens_decoder": {"151657": {"content": "<tool_call>"}}}\n' > "$TMP/hub-files/tokenizer_config.json"
  else printf '{"chat_template": "{{ messages }}"}\n' > "$TMP/hub-files/tokenizer_config.json"; fi
  printf '{"version": "1.0"}\n' > "$TMP/hub-files/tokenizer.json"
  printf '{"temperature": 0.7}\n' > "$TMP/hub-files/generation_config.json"
  printf 'a b\n' > "$TMP/hub-files/merges.txt"
  head -c 3000 /dev/urandom > "$TMP/hub-files/pytorch_model.bin"; head -c 3000 /dev/urandom > "$TMP/hub-files/original/consolidated.safetensors"
  printf '# M\n' > "$TMP/hub-files/README.md"
  python3 -I -c '
import hashlib, json, os, sys
root, rid, sha, tags = sys.argv[1], sys.argv[2], sys.argv[3], [t for t in sys.argv[4].split(",") if t]
sib = []
for n in ("README.md", "config.json", "generation_config.json", "merges.txt", "model.safetensors", "original/consolidated.safetensors",
          "pytorch_model.bin", "tokenizer.json", "tokenizer_config.json"):
    b = open(os.path.join(root, n), "rb").read()
    e = {"rfilename": n, "size": len(b), "blobId": hashlib.sha1(b"blob %d\0" % len(b) + b).hexdigest()}
    if n.endswith((".safetensors", ".bin")):
        e["lfs"] = {"sha256": hashlib.sha256(b).hexdigest(), "size": len(b), "pointerSize": 134}
    sib.append(e)
json.dump({"id": rid, "sha": sha, "tags": tags, "siblings": sib}, open(os.path.join(root, ".api.json"), "w"))' "$TMP/hub-files" "$id" "$sha" "$tags"
}
_vl_hub() {
  rm -f "$TMP/hub.port" "$TMP/hub.log"
  python3 -I "$STACK_DIR/tests/fixtures/hf_hub_server.py" "$TMP/hub-files" "$TMP/hub.port" "$TMP/hub.log" </dev/null >/dev/null 2>&1 &
  HUB_PID=$!
  _wait_for '[ -s "$TMP/hub.port" ]'
  export HF_ENDPOINT="http://127.0.0.1:$(cat "$TMP/hub.port")"
}

# --- the pins, and the container ---

test_the_pins_name_one_release_for_both_images() {
  local v; v="$(rt_pin VLLM_VERSION)"; [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  grep -Eq "^    image: vllm/vllm-openai-cpu:v$v-x86_64@sha256:[0-9a-f]{64}\$" "$STACK_DIR/compose.yaml"
  grep -Eq "^    image: vllm/vllm-openai:v$v@sha256:[0-9a-f]{64}\$" "$STACK_DIR/compose.vllm-gpu.yaml"
  assert_eq "$(rt_pinned_version vllm)" "$v"
  assert_contains "$(cat "$STACK_DIR/bin/bump-core-services")" "vLLM "
  assert_contains "$(cat "$STACK_DIR/bin/bump-core-services")" "compose.vllm-gpu.yaml) are bumped by hand"
}

test_the_container_publishes_nothing_reaches_nothing_runs_no_model_code_and_drops_its_privileges() {
  local svc; svc="$(awk '/^  vllm:/{s=1;print;next} s&&/^  [a-z]/{exit} s' "$STACK_DIR/compose.yaml")"
  assert_contains "$svc" 'profiles: ["vllm"]'
  assert_not_contains "$svc" "ports:"
  assert_contains "$svc" "networks: [vllm]"
  assert_contains "$svc" 'user: "${BN_VLLM_USER:-65534:65534}"'
  assert_contains "$svc" "read_only: true"
  assert_contains "$svc" "cap_drop: [ALL]"
  assert_contains "$svc" "no-new-privileges"
  # (its /tmp allows exec, and is capped: vLLM loads the kernels it compiles there at its start)
  assert_contains "$svc" 'tmpfs: ["/tmp:exec,size=2g,mode=1777"]'
  assert_not_contains "$svc" "seccomp=unconfined"
  assert_not_contains "$svc" "cap_add"
  assert_contains "$svc" 'entrypoint: ["vllm", "serve"]'
  assert_contains "$svc" 'command: ["/models/current", "--config", "/etc/vllm/serve.yaml"]'
  assert_contains "$svc" '/hub:/models:ro,z'
  assert_contains "$svc" '/etc:/etc/vllm:ro,z'
  assert_contains "$svc" 'HF_HUB_OFFLINE: "1"'
  assert_contains "$svc" 'VLLM_NO_USAGE_STATS: "1"'
  assert_not_contains "$(cat "$STACK_DIR/compose.yaml" "$STACK_DIR/compose.vllm-gpu.yaml" "$STACK_DIR/lib/runtimes.sh")" "trust-remote-code:"
  assert_contains "$(awk '/^networks:/,0' "$STACK_DIR/compose.yaml")" "$(printf '  vllm:\n    internal: true')"
  assert_contains "$(status_url vllm)" "LiteLLM's alone"
}

# compose.yaml as Docker Compose renders it with the profile (no daemon): who is on vLLM's network, its user and mounts,
# and the NVIDIA image with the GPUs
test_compose_renders_vllm_on_an_internal_network_with_the_gateway_alone() {
  [ -n "${BN_REAL_DOCKER:-}" ] && "$BN_REAL_DOCKER" compose version >/dev/null 2>&1 || { echo "no docker compose" >&2; return 77; }
  docker() { case "$*" in *" config --format json") "$BN_REAL_DOCKER" "$@" ;; *) echo "unexpected docker $*" >&2; return 97 ;; esac; }
  printf 'POSTGRES_PASSWORD=p\nRUSTFS_ACCESS_KEY=a\nRUSTFS_SECRET_KEY=s\nLITELLM_MASTER_KEY=m\nLITELLM_SALT_KEY=s\nLITELLM_UI_PASSWORD=u\nWEBUI_SECRET_KEY=w\nOPENWEBUI_ADMIN_EMAIL=a@b.c\nOPENWEBUI_ADMIN_PASSWORD=p\nSHARED_MCP_TOKEN=t\nSTT_PROVIDER=bedrock\n' > "$ENV_FILE"
  mkdir -p "$STATE_DIR/runtimes/vllm"; echo 1234:5678 > "$STATE_DIR/runtimes/vllm/user"
  local out; out="$(_RT_PROFILE=vllm dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c '
import json, sys
d = json.load(sys.stdin); s = d["services"]; v = s["vllm"]; root = sys.argv[1]
on = lambda n: sorted(k for k, x in s.items() if n in (x.get("networks") or {}))
assert on("vllm") == ["litellm", "vllm"], on("vllm")
assert d["networks"]["vllm"]["internal"] is True, d["networks"]["vllm"]
assert "ports" not in v and list(v["networks"]) == ["vllm"], v
assert v["user"] == "1234:5678" and v["read_only"] is True and v["cap_drop"] == ["ALL"], v
assert v["tmpfs"] == ["/tmp:exec,size=2g,mode=1777"], v["tmpfs"]
assert "vllm-openai-cpu" in v["image"] and "deploy" not in v, v
assert v["entrypoint"] == ["vllm", "serve"] and v["command"] == ["/models/current", "--config", "/etc/vllm/serve.yaml"], v
m = {x["target"]: (x["source"], x.get("read_only")) for x in v["volumes"]}
assert m == {"/models": (root + "/hub", True), "/etc/vllm": (root + "/etc", True), "/cache": (root + "/cache", None)}, m
' "$STATE_DIR/runtimes/vllm"
  echo nvidia > "$STATE_DIR/runtimes/vllm/gpu"
  out="$(_RT_PROFILE=vllm dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c '
import json, sys
v = json.load(sys.stdin)["services"]["vllm"]
assert v["image"].startswith("vllm/vllm-openai:v") and "cpu" not in v["image"], v["image"]
assert v["deploy"]["resources"]["reservations"]["devices"][0]["driver"] == "nvidia", v["deploy"]'
  rm -f "$STATE_DIR/runtimes/vllm/gpu"
  out="$(dc config --format json 2>&1)" || { echo "$out" >&2; return 1; }
  printf '%s' "$out" | python3 -I -c 'import json, sys; d = json.load(sys.stdin); assert "vllm" not in d["services"], sorted(d["services"])'
}

# --- where it runs ---

test_it_runs_on_linux_with_nvidia_gpus_or_an_x86_64_cpu_with_avx2() {
  _vl_env
  assert_eq "$(rt_why_not vllm)" ""
  assert_eq "$(rt_kind vllm)" container
  assert_eq "$(rt_size vllm)" "about 1.7 GB to download, 7.4 GB once unpacked (its image)"
  assert_eq "$(rt_address vllm)" "vllm:8000 (the model gateway's network only)"
  printf 'flags\t\t: fpu sse2 avx\n' > "$TMP/cpuinfo"
  assert_contains "$(rt_why_not vllm)" "vLLM needs NVIDIA GPUs, or a processor with AVX2"
  assert_eq "$(rt_state vllm)" unsupported
  : > "$TMP/no-nvidiactl"   # (this computer's NVIDIA driver)
  assert_eq "$(rt_why_not vllm)" ""
  assert_eq "$(rt_size vllm)" "about 9.2 GB to download (its image, with NVIDIA's libraries)"
  rm -f "$TMP/no-nvidiactl"; FAKE_ARCH=aarch64
  assert_contains "$(rt_why_not vllm)" "an x86-64 processor"
  FAKE_OS=Darwin; FAKE_ARCH=arm64
  assert_contains "$(rt_why_not vllm)" "vLLM runs on Linux"
  assert_eq "$(rt_kind vllm)" none
  FAKE_OS=Linux; FAKE_ARCH=x86_64; printf 'flags\t\t: avx512f\n' > "$TMP/cpuinfo"
  docker() { return 1; }; unset -f docker
  PATH="$TMP/bin" assert_contains "$(PATH="$TMP/bin" rt_why_not vllm)" "Docker is not installed"
}

# --- install: no model yet ---

test_install_pulls_its_image_and_waits_for_a_model_without_a_container() {
  _vl_env
  rt_install vllm > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  local d; d="$(rt_dir vllm)"
  assert_contains "$(cat "$TMP/docker")" "--profile vllm"
  assert_contains "$(cat "$TMP/docker")" " pull -q vllm"
  assert_not_contains "$(cat "$TMP/docker")" " up -d"
  assert_eq "$(cat "$d/installed")" "$(rt_pin VLLM_VERSION)"
  assert_eq "$(cat "$d/user")" "$(id -u):$(id -g)"
  [[ $(rt_api_key vllm) =~ ^[0-9a-f]{64}$ ]] && [ -d "$d/hub" ] && [ -d "$d/cache" ] && [ ! -e "$d/gpu" ]
  assert_eq "$(stat -f %Lp "$d/etc/api-key" 2>/dev/null || stat -c %a "$d/etc/api-key")" 600
  assert_eq "$(rt_state vllm)" waiting
  assert_contains "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$(rt_job_file)")" "It serves one model at a time: download one to it"
  assert_contains "$(cut -f3- "$(rt_events_file)")" "it starts with the first model downloaded to it"
  # no container while it waits: ./stack up leaves it out, Start says why
  assert_not_contains " $(optional_services) " " vllm "
  assert_not_contains "$(runtime_profiles)" vllm
  assert_contains "$(rt_start vllm 2>&1)" "vLLM has no model to serve yet"
  assert_contains "$(_rt_status_lines)" "installed, with no model to serve yet"
  # a download can go to it all the same (named, or automatic when nothing else runs)
  assert_eq "$(local_vllm_state)" waiting
  assert_eq "$(local_runtime)" vllm
  printf 'X=1\n' > "$ENV_FILE"; assert_eq "$(local_runtime)" vllm
  rt_status_write
  python3 -I -c 'import json,sys; r=[x for x in json.load(open(sys.argv[1]))["runtimes"] if x["id"] == "vllm"][0]
assert (r["state"], r["managed"], r["kind"], r["loaded"]) == ("waiting", True, "container", []), r' "$(rt_status_file)"
}

test_without_nvidia_or_avx2_nothing_is_installed() {
  _vl_env
  printf 'flags\t\t: fpu sse2\n' > "$TMP/cpuinfo"
  : > "$TMP/no-nvidiactl"   # (a driver, but Docker has no NVIDIA runtime)
  ( rt_install vllm ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "this processor has no AVX2 for vLLM's CPU build: nothing was installed"
  ! rt_installed vllm
  # with Docker's NVIDIA runtime: the GPU image
  : > "$TMP/nvidia"
  rt_install vllm > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_eq "$(cat "$(rt_dir vllm)/gpu")" nvidia
  assert_contains "$(_RT_PROFILE=vllm runtime_overlays)" compose.vllm-gpu.yaml   # (its pull; then while it serves a model)
}

# --- a download: its safetensors, served ---

test_a_download_fetches_only_what_loads_it_then_vllm_serves_it_with_its_key_context_and_parser() {
  _vl_env
  rt_install vllm > /dev/null 2>&1
  _vl_repo org/A "$SHA_A" "transformers,safetensors"; _vl_hub
  ( local_pull org/A safetensors --context 131072 --tools yes --params-m 500 --license apache-2.0 ) > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" "$(local_dir)/pull.log" >&2; return 1; }
  kill "$HUB_PID"
  local d s k; d="$(rt_dir vllm)"; s="$d/hub/models--org--A/snapshots/$SHA_A"; k="$(rt_api_key vllm)"
  cmp -s "$s/model.safetensors" "$TMP/hub-files/model.safetensors"
  # its top-level files that load it: never the pickle, another folder or the README
  assert_eq "$(cd "$s" && find . -type l | sort | tr '\n' ' ')" "./config.json ./generation_config.json ./merges.txt ./model.safetensors ./tokenizer.json ./tokenizer_config.json "
  assert_contains "$(cat "$TMP/hub.log")" "/org/A/resolve/$SHA_A/model.safetensors"
  assert_not_contains "$(cat "$TMP/hub.log")" "pytorch_model.bin"
  # serve.yaml: its name, the key, the context capped for a CPU, Qwen's parser (<tool_call> in its tokenizer)
  assert_eq "$(stat -f %Lp "$d/etc/serve.yaml" 2>/dev/null || stat -c %a "$d/etc/serve.yaml")" 600
  local y; y="$(cat "$d/etc/serve.yaml")"
  assert_contains "$y" 'served-model-name: "org/A"'
  assert_contains "$y" "api-key: \"$k\""
  assert_contains "$y" "max-model-len: 8192"
  assert_contains "$y" "$(printf 'enable-auto-tool-choice: true\ntool-call-parser: "hermes"')"
  assert_eq "$(readlink "$d/hub/current")" "models--org--A/snapshots/$SHA_A"
  assert_contains "$(cat "$TMP/docker")" " up -d --force-recreate vllm"
  assert_eq "$(rt_vllm_serving)" org/A
  assert_eq "$(rt_state vllm)" running
  assert_eq "$(_rt_ps vllm)" "$(printf 'org/A\t%s\t0' "$(_reg org/A >/dev/null; local_registry_rows | awk -F'\t' '$2 == "org/A" { print $5 }')")"
  # the registry (its revision), LOCAL_MODELS (vLLM's one model), the job
  assert_eq "$(_reg org/A)" "org/A|1|131072|$SHA_A"
  assert_eq "$(tail -n 1 "$TMP/apply")" "local cli |LOCAL_MODELS|vllm:org/A"
  assert_contains "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["state"], d["message"])' "$(local_job_file)")" "done Ready: lm/org/A is in Chat"
  # the model gateway's entry: Chat Completions to its container on their network, with its key
  printf 'LOCAL_MODELS=vllm:org/A\n' >> "$ENV_FILE"
  y="$(local_models_yaml)"
  assert_contains "$y" '- model_name: "lm/org/A"'
  assert_contains "$y" 'model: "openai/org/A"'
  assert_contains "$y" 'api_base: "http://vllm:8000/v1"'
  assert_contains "$y" "api_key: \"$k\""
  assert_contains "$y" "input_cost_per_token: 0"
  # the portal's file: vLLM ready, the model on disk and served
  local_status_write
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); i=d["installed"][0]
assert d["runtime"]["kind"] == "vllm" and d["runtime"]["vllm"] == "ready", d["runtime"]
assert (i["runtime"], i["id"], i["quant"], i["present"], i["registered"]) == ("vllm", "org/A", "safetensors", True, True), i' "$(local_status_file)"
  assert_contains "$(_rt_status_lines)" "running $(rt_pin VLLM_VERSION) on vllm:8000"
}

test_another_download_switches_vllm_to_it_and_serve_switches_back_without_downloading() {
  _vl_env
  rt_install vllm > /dev/null 2>&1
  _vl_repo org/A "$SHA_A"; _vl_hub
  ( local_pull org/A safetensors ) > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" >&2; return 1; }
  cp -R "$TMP/hub-files" "$TMP/hub-A"
  printf 'LOCAL_MODELS=lmstudio:x/y:Q4,vllm:org/A\n' >> "$ENV_FILE"
  # B: no tool tokens (no parser: tool use is "no"), a short context of its own
  TOOLS=0 CTX=2048 _vl_repo org/B "$SHA_B"
  ( local_pull org/B safetensors --tools yes ) > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" >&2; return 1; }
  local d; d="$(rt_dir vllm)"
  assert_eq "$(rt_vllm_serving)" org/B
  assert_contains "$(cat "$d/etc/serve.yaml")" "max-model-len: 2048"
  assert_not_contains "$(cat "$d/etc/serve.yaml")" "tool-call-parser"
  assert_eq "$(_reg org/B)" "org/B|0|-|$SHA_B"
  # one vLLM model in LOCAL_MODELS: B in A's place, the others kept
  assert_eq "$(tail -n 1 "$TMP/apply")" "local cli |LOCAL_MODELS|lmstudio:x/y:Q4,vllm:org/B"
  assert_contains "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$(local_job_file)")" "org/A stays downloaded, not served"
  printf 'LOCAL_MODELS=vllm:org/B\n' >> "$ENV_FILE"
  local_status_write
  python3 -I -c 'import json,sys; d={i["id"]: i for i in json.load(open(sys.argv[1]))["installed"]}
assert d["org/A"]["present"] and not d["org/A"]["registered"] and d["org/B"]["registered"], d' "$(local_status_file)"
  # Serve A again (the same download): checked against the Hub, nothing fetched again
  rm -rf "$TMP/hub-files"; cp -R "$TMP/hub-A" "$TMP/hub-files"; : > "$TMP/hub.log"   # (the Hub as it was)
  ( local_pull org/A safetensors ) > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" >&2; return 1; }
  kill "$HUB_PID"
  assert_eq "$(rt_vllm_serving)" org/A
  assert_eq "$(readlink "$d/hub/current")" "models--org--A/snapshots/$SHA_A"
  assert_not_contains "$(cat "$TMP/hub.log")" "/resolve/"
  assert_eq "$(tail -n 1 "$TMP/apply")" "local cli |LOCAL_MODELS|vllm:org/A"
}

test_a_model_vllm_cannot_load_leaves_the_one_before_served_and_stays_downloaded() {
  _vl_env
  rt_install vllm > /dev/null 2>&1
  _vl_repo org/A "$SHA_A"; _vl_hub
  ( local_pull org/A safetensors ) > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" >&2; return 1; }
  printf 'LOCAL_MODELS=vllm:org/A\n' >> "$ENV_FILE"
  _vl_repo org/B "$SHA_B"; : > "$TMP/vl-fail"; : > "$TMP/apply"
  ( local_pull org/B safetensors ) > "$TMP/out" 2>&1 && { kill "$HUB_PID"; return 1; }
  kill "$HUB_PID"
  local d; d="$(rt_dir vllm)"
  assert_contains "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["state"], d["message"])' "$(local_job_file)")" \
    "failed Downloaded, but vLLM could not serve it (ValueError: Qwen9ForCausalLM is not supported). It stays downloaded (Remove deletes it); vLLM serves org/A again."
  # A again: its serve.yaml and link back, started again; B kept, listed, not in the gateway
  assert_eq "$(rt_vllm_serving)" org/A
  assert_eq "$(readlink "$d/hub/current")" "models--org--A/snapshots/$SHA_A"
  assert_contains "$(cat "$TMP/served.yaml")" 'served-model-name: "org/A"'
  [ ! -e "$d/etc/serve.yaml.prev" ] && [ ! -e "$d/serving.prev" ] && [ ! -e "$d/current.prev" ]
  [ -f "$d/hub/models--org--B/snapshots/$SHA_B/config.json" ]
  assert_eq "$(_reg org/B | cut -d'|' -f1)" org/B
  [ ! -s "$TMP/apply" ]
  # with none before: no container, waiting again — and its log is that start's, said so (Settings' Log, ./stack runtimes logs)
  rm -f "$d/etc/serve.yaml" "$d/serving" "$d/hub/current" "$TMP/vl-up"
  ! rt_vllm_serve org/B org/B "$SHA_B" "" > /dev/null 2>&1
  assert_eq "$(rt_state vllm)" waiting
  assert_contains "$(cat "$TMP/docker")" " rm -sf vllm"
  assert_eq "$_RT_VLLM_HINT" "ValueError: Qwen9ForCausalLM is not supported"
  assert_eq "$(rt_logs_text vllm)" "$(printf '(no container now: the log of its last start, which failed)\nValueError: Qwen9ForCausalLM is not supported')"
  # Docker would not start it: Docker's words, from the download's job to its last line
  rm -f "$TMP/vl-fail"; : > "$TMP/vl-upfail"
  _vl_hub
  ( local_pull org/B safetensors ) > "$TMP/out" 2>&1 && { kill "$HUB_PID"; return 1; }
  kill "$HUB_PID"
  assert_contains "$(cat "$TMP/out")" "vLLM could not serve it: Docker could not start it: Error response from daemon: no such image: vllm/vllm-openai-cpu"
  assert_contains "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$(local_job_file)")" "(Docker could not start it: Error response from daemon: no such image"
  assert_eq "$(rt_state vllm)" waiting
  # a start that works again: its log is its container's, the failed one's is gone
  rm -f "$TMP/vl-upfail"; _vl_hub
  ( local_pull org/B safetensors ) > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" >&2; return 1; }
  kill "$HUB_PID"
  [ ! -e "$d/failed.log" ]
  assert_not_contains "$(rt_logs_text vllm)" "no container now"
}

test_its_log_never_shows_its_key() {
  _vl_env
  rt_install vllm > /dev/null 2>&1
  local k; k="$(rt_api_key vllm)"; : > "$TMP/vl-up"
  printf "INFO [utils.py] non-default args: {'model_tag': '/models/current', 'api_key': ['%s']}\nValueError: no\n" "$k" > "$TMP/vl-log"
  assert_contains "$(rt_logs_text vllm)" "'api_key': ['[its API key]']"
  assert_not_contains "$(rt_logs_text vllm)" "$k"
  assert_not_contains "$(_rt_log_hint vllm)" "$k"
  # any runtime's key, wherever a container's log is shown (setup's report of a service that did not come up)
  assert_eq "$(printf 'a %s b %s\n' "$k" "$k" | rt_key_redact)" "a [its API key] b [its API key]"
  assert_contains "$(cat "$STACK_DIR/lib/commands.sh")" 'dc logs --no-color --tail 30 "$s" 2>&1 | { if declare -F rt_key_redact >/dev/null; then rt_key_redact; else cat; fi; }'
}

test_remove_of_the_model_it_serves_stops_it_and_deletes_the_files() {
  _vl_env
  rt_install vllm > /dev/null 2>&1
  _vl_repo org/A "$SHA_A"; _vl_hub
  ( local_pull org/A safetensors ) > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" >&2; return 1; }
  kill "$HUB_PID"
  printf 'LOCAL_MODELS=vllm:org/A\n' >> "$ENV_FILE"
  local_rm org/A safetensors > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  local d; d="$(rt_dir vllm)"
  [ ! -e "$d/hub/models--org--A" ] && [ ! -e "$d/hub/current" ] && [ ! -e "$d/etc/serve.yaml" ]
  assert_eq "$(local_registry_rows)" ""
  assert_eq "$(tail -n 1 "$TMP/apply")" "local cli |LOCAL_MODELS|"
  assert_eq "$(rt_state vllm)" waiting
  assert_contains "$(cut -f3- "$(rt_events_file)")" "vLLM was stopped: the model it served was removed"
}

# --- what is refused ---

test_uninstall_removes_it_with_its_models_and_its_image() {
  _vl_env
  rt_install vllm > /dev/null 2>&1
  _vl_repo org/A "$SHA_A"; _vl_hub
  ( local_pull org/A safetensors ) > "$TMP/out" 2>&1 || { kill "$HUB_PID"; cat "$TMP/out" >&2; return 1; }
  kill "$HUB_PID"
  printf 'LOCAL_MODELS=lmstudio:x/y:Q4,vllm:org/A\n' >> "$ENV_FILE"; : > "$TMP/docker"
  rt_uninstall vllm > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_contains "$(cat "$TMP/docker")" " rm -sf vllm"
  assert_contains "$(cat "$TMP/docker")" "image rm vllm/vllm-openai-cpu:cpu"
  [ ! -e "$(rt_dir vllm)" ]
  assert_eq "$(rt_state vllm)" not-installed
  assert_eq "$(tail -n 1 "$TMP/apply" | cut -d'|' -f3)" "lmstudio:x/y:Q4"
  [ -z "$(local_registry_rows | awk -F'\t' '$1 == "vllm"')" ]
}

test_the_check_refuses_code_of_its_own_mlx_weights_no_weights_and_a_gguf_quantization() {
  _vl_env
  mkdir -p "$(local_dir)"
  _vl_repo org/C "$SHA_A" "transformers,custom_code"; _vl_hub
  assert_eq "$(_local_st_vet org/C "$TMP/man")" "no it asks to run code of its own (custom_code), and DevOS ADE never runs a model's own code"
  _vl_repo org/C "$SHA_A" "mlx"
  assert_contains "$(_local_st_vet org/C "$TMP/man")" "no it is an MLX model"
  _vl_repo org/C "$SHA_A"; python3 -I -c '
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["siblings"] = [s for s in d["siblings"] if not s["rfilename"].endswith(".safetensors")]; json.dump(d, open(p, "w"))' "$TMP/hub-files/.api.json"
  assert_contains "$(_local_st_vet org/C "$TMP/man")" "no it has no safetensors weights"
  _vl_repo org/C "$SHA_A"
  local v; v="$(_local_st_vet org/C "$TMP/man")"
  kill "$HUB_PID"
  assert_eq "${v%%$'\t'*}" "sha $SHA_A"
  assert_eq "$(cut -f1 "$TMP/man" | tr '\n' ' ')" "config.json generation_config.json merges.txt model.safetensors tokenizer.json tokenizer_config.json "
  rt_install vllm > /dev/null 2>&1
  ( local_pull org/C Q4_K_M ) > "$TMP/out" 2>&1 && return 1
  assert_contains "$(cat "$TMP/out")" "vLLM takes safetensors: ./stack local-models pull org/C safetensors"
}

test_a_download_whose_config_asks_for_its_own_code_is_deleted_and_never_served() {
  _vl_env
  rt_install vllm > /dev/null 2>&1
  AUTO_MAP=1 _vl_repo org/A "$SHA_A"; _vl_hub   # (the Hub did not tag it: the files on disk are checked again)
  ( local_pull org/A safetensors ) > "$TMP/out" 2>&1 && { kill "$HUB_PID"; return 1; }
  kill "$HUB_PID"
  assert_contains "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["message"])' "$(local_job_file)")" "Not served: its config.json asks to run custom code (auto_map). The download was deleted."
  [ ! -e "$(rt_dir vllm)/hub/models--org--A" ]
  assert_eq "$(rt_state vllm)" waiting
  assert_not_contains "$(cat "$TMP/docker")" " up -d"
}

test_cancel_deletes_what_arrived_but_never_a_model_downloaded_before() {
  _vl_env
  local h; h="$(rt_dir vllm)/hub/models--org--A"
  mkdir -p "$h/blobs" "$(local_dir)"; printf x > "$h/blobs/$(printf '4%.0s' $(seq 64)).part"
  _local_discard vllm org/A
  [ ! -e "$h" ]
  # downloaded before (Serve fetching it again): only this download's parts
  mkdir -p "$h/blobs"; printf x > "$h/blobs/$(printf '4%.0s' $(seq 64)).part"; printf w > "$h/blobs/$(printf '1%.0s' $(seq 64))"
  printf 'model.safetensors\t1\t%s\t\n' "$(printf '4%.0s' $(seq 64))" > "$(local_dir)/manifest.tsv"
  local_registry_put vllm org/A org/A safetensors 2 - - - - "$SHA_A"
  _local_discard vllm org/A
  [ ! -e "$h/blobs/$(printf '4%.0s' $(seq 64)).part" ] && [ -f "$h/blobs/$(printf '1%.0s' $(seq 64))" ]
  printf 'vllm\n' > "$(local_dir)/job.rt"; assert_eq "$(_local_job_runtime safetensors)" vllm
}

test_its_tool_call_parser_comes_from_its_own_tokens() {
  mkdir -p "$TMP/m"
  printf '{"max_position_embeddings": 4096}' > "$TMP/m/config.json"
  printf '{"x": "<tool_call>"}' > "$TMP/m/tokenizer_config.json"
  assert_eq "$(_rt_vllm_facts "$TMP/m")" "$(printf 'hermes\t4096')"
  printf '{"x": "[TOOL_CALLS]"}' > "$TMP/m/tokenizer_config.json"
  assert_eq "$(_rt_vllm_facts "$TMP/m")" "$(printf 'mistral\t4096')"
  printf '{"x": "<|python_tag|>"}' > "$TMP/m/tokenizer_config.json"
  printf '{"text_config": {"max_position_embeddings": 131072}}' > "$TMP/m/config.json"
  assert_eq "$(_rt_vllm_facts "$TMP/m")" "$(printf 'llama3_json\t131072')"
  printf '{}' > "$TMP/m/tokenizer_config.json"; printf 'not json' > "$TMP/m/config.json"
  assert_eq "$(_rt_vllm_facts "$TMP/m")" "$(printf 'none\t0')"
}
