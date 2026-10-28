# shellcheck shell=bash
# Local models (lib/local_models.sh, JON-816): the runtimes (Docker Model Runner first, Ollama second) behind a fake
# `docker` and a fake runner's HTTP API (both shell functions: nothing real runs), the download with progress, the
# registration (LOCAL_MODELS), LiteLLM's entries, the Code page's rows (Local, $0, tool use said honestly), the removal,
# and the Hugging Face token never in an argument or a log.
. "$STACK_DIR/lib/commands.sh"

TOKEN_FAKE="hf_$(printf 'abcdefghij%.0s' 1 2 3)"   # (built here, never a literal in the repo)

# the fake Docker Model Runner: its state in $TMP/dmr (running flag, models), every call logged to $TMP/docker.log
_fake_dmr() {   # _fake_dmr running|off|noplugin
  mkdir -p "$TMP/dmr"; : > "$TMP/dmr/models"; : > "$TMP/docker.log"
  printf '%s\n' "$1" > "$TMP/dmr/mode"
  curl() { return 7; }   # (no Ollama; a test that wants one defines curl itself, after this)
  docker() {
    local mode; mode="$(cat "$TMP/dmr/mode")"
    printf '%s\n' "$*" >> "$TMP/docker.log"
    case "$1" in
      info) printf 'Docker Desktop\n'; return 0 ;;
      model) shift ;;
      *) return 0 ;;
    esac
    [ "$mode" != noplugin ] || { echo "docker: 'docker model' is not a docker command" >&2; return 125; }
    case "$1" in
      version) echo "Client: v1.2.9"; return 0 ;;
      status) if [ "$mode" = running ]; then echo '{"running":true,"backends":{},"kind":"Docker Desktop","endpoint":"http://model-runner.docker.internal/v1/"}'; return 0
              else echo '{"running":false,"backends":{}}'; return 1; fi ;;
      pull) [ "$mode" = running ] || return 1
            printf 'HF_TOKEN set: %s\n' "$([ -n "${HF_TOKEN:-}" ] && echo yes || echo no)" >> "$TMP/docker.env"
            printf 'Downloaded: 20.00 MB\r' ; sleep 0.3; printf 'Downloaded: 60.50 MB\r'; sleep 0.3
            # (the runner lowercases the name)
            printf '%s\n' "$2" | tr 'A-Z' 'a-z' >> "$TMP/dmr/models"; echo "Model pulled successfully"; return 0 ;;
      list) printf '{"object":"list","data":['; awk 'NR > 1 { printf "," } { printf "{\"id\":\"%s\",\"object\":\"model\"}", $0 }' "$TMP/dmr/models"; printf ']}\n'; return 0 ;;
      rm) grep -vxF "$2" "$TMP/dmr/models" > "$TMP/dmr/m2" || true; mv "$TMP/dmr/m2" "$TMP/dmr/models"; return 0 ;;
    esac
    return 2
  }
}
# the fake config apply: writes LOCAL_MODELS into .env as ./stack config apply would (its own tests are elsewhere)
_fake_apply() { config_apply() { local k; for k in $CFG_ORDER; do printf '%s=%s\n' "$k" "$(cfg_new "$k")" >> "$TMP/applied.env"; grep -v "^$k=" "$ENV_FILE" > "$ENV_FILE.n" 2>/dev/null || true; printf '%s=%s\n' "$k" "$(cfg_new "$k")" >> "$ENV_FILE.n"; mv "$ENV_FILE.n" "$ENV_FILE"; done; CFG_ORDER=''; }; }
_lm_env() { mkdir -p "$STATE_DIR/status" "$STATE_DIR/requests" "$STATE_DIR/helper"; printf '%s' "${1:-}" > "$ENV_FILE"; LOCAL_POLL_S=0.1; export LOCAL_POLL_S LOCAL_MLX=off LOCAL_DMR_BASE=http://model-runner.docker.internal/engines/llama.cpp; }

test_ids_are_checked() {
  valid_hf_repo bartowski/SmolLM2-135M-Instruct-GGUF
  ! valid_hf_repo 'a/b/c'
  ! valid_hf_repo '../x/y'
  ! valid_hf_repo 'a b/c'
  valid_hf_quant Q4_K_M; valid_hf_quant 'SmolLM2-135M-Instruct-Q4_K_M.gguf'
  ! valid_hf_quant 'Q4;rm'
  valid_local_models ''
  valid_local_models 'dmr:hf.co/a/b:q4_k_m,ollama:hf.co/C/d:Q8_0'
  ! valid_local_models 'dmr:'
  ! valid_local_models 'dmr:a b'
  ! valid_local_models 'x:a'
  ! valid_local_models ',dmr:a'
  valid_hf_token ''; valid_hf_token "$TOKEN_FAKE"; ! valid_hf_token 'sk-abc'
  [ "$(local_model_name dmr:hf.co/bartowski/smollm2-gguf:q4_k_m)" = "lm/bartowski/smollm2-gguf:q4_k_m" ]
}

test_the_runtime_is_found_docker_first_then_ollama_else_none_with_how() {
  _lm_env; _fake_dmr running
  assert_eq "$(local_dmr_state)" ready
  assert_eq "$(local_runtime)" dmr
  _fake_dmr off
  assert_eq "$(local_dmr_state)" not-enabled
  curl() { case "$*" in *11434/api/version*) return 0 ;; esac; return 7; }
  assert_eq "$(local_runtime)" ollama                  # Docker's runner is off: Ollama answers
  curl() { return 7; }
  assert_eq "$(local_runtime)" none
  assert_contains "$(local_how_text)" "./stack local-models enable"
  assert_contains "$(local_how_text)" "Docker Desktop"
  _fake_dmr noplugin
  assert_eq "$(local_dmr_state)" plugin-missing
}

test_a_machine_with_no_runtime_gets_a_status_file_that_says_how_and_a_failed_pull_says_so() {
  _lm_env; _fake_dmr off; curl() { return 7; }
  local_status_write
  s="$(cat "$STATE_DIR/status/local-models.json")"
  assert_contains "$s" '"kind":"none"'
  assert_contains "$s" 'local-models enable'
  assert_contains "$s" '"installed":[]'
  ( local_pull bartowski/SmolLM2-135M-Instruct-GGUF Q4_K_M ) 2>/dev/null && return 1
  assert_contains "$(cat "$STATE_DIR/local-models/job.json")" '"state":"failed"'
}

test_a_pull_downloads_with_progress_registers_and_lands_in_the_pickers_at_zero() {
  _lm_env "HF_TOKEN=$TOKEN_FAKE
"; _fake_dmr running; _fake_apply
  CATALOG="$TMP/cat.tsv"; printf 'claude-big\tchat\tbedrock/invoke/us.anthropic.big\t-\t-\n' > "$CATALOG"
  : > "$TMP/prog"
  local_pull bartowski/SmolLM2-135M-Instruct-GGUF Q4_K_M --bytes 105000000 --tools yes --context 8192 --params-m 135 --license apache-2.0 2>/dev/null
  # the runner's own (lowercased) id is what is registered
  assert_eq "$(get_env LOCAL_MODELS)" "dmr:hf.co/bartowski/smollm2-135m-instruct-gguf:q4_k_m"
  grep -q 'model pull hf.co/bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M' "$TMP/docker.log"
  # the token reached the runner's environment, never an argument or a log
  assert_contains "$(cat "$TMP/docker.env")" "HF_TOKEN set: yes"
  ! grep -rq "$TOKEN_FAKE" "$TMP/docker.log" "$STATE_DIR" 2>/dev/null
  job="$(cat "$STATE_DIR/local-models/job.json")"
  assert_contains "$job" '"state":"done"'
  assert_contains "$job" '"done_bytes":105000000'
  st="$(cat "$STATE_DIR/status/local-models.json")"
  assert_contains "$st" '"kind":"dmr"'
  assert_contains "$st" '"disk_bytes":105000000'
  assert_contains "$st" '"registered":true'
  assert_contains "$st" '"license":"apache-2.0"'
  # LiteLLM: a docker_model_runner deployment, no key, $0
  y="$(local_models_yaml)"
  assert_contains "$y" 'model_name: "lm/bartowski/smollm2-135m-instruct-gguf:q4_k_m"'
  assert_contains "$y" 'model: "docker_model_runner/hf.co/bartowski/smollm2-135m-instruct-gguf:q4_k_m"'
  assert_contains "$y" 'api_base: "http://model-runner.docker.internal/engines/llama.cpp"'
  assert_contains "$y" 'input_cost_per_token: 0'
  assert_contains "$y" 'output_cost_per_token: 0'
  ! printf '%s' "$y" | grep -qi 'api_key'
}

test_a_progress_log_is_read_for_the_bytes_done() {
  printf 'Downloaded: 20.00 MB\rDownloaded: 60.50 MB\r' > "$TMP/p"
  assert_eq "$(_local_progress_bytes "$TMP/p")" "$((60 * 1048576 + 524288))"
  printf '1.5 GB / 3.0 GB\n' > "$TMP/p"
  assert_eq "$(_local_progress_bytes "$TMP/p")" "$((3 * 1073741824 / 2))"
  : > "$TMP/p"
  assert_eq "$(_local_progress_bytes "$TMP/p")" 0
}

test_the_code_page_rows_say_local_free_and_what_tools_can_do_honestly() {
  _lm_env; _fake_dmr running; _fake_apply
  CATALOG="$TMP/cat.tsv"; printf 'claude-big\tchat\tbedrock/invoke/us.anthropic.big\t-\t-\n' > "$CATALOG"
  CODE_COMPAT="$TMP/compat.tsv"; : > "$CODE_COMPAT"; CODE_DISPLAY_TSV=/dev/null; PRICES=/dev/null; export CODE_COMPAT CODE_DISPLAY_TSV PRICES CATALOG
  local_registry_put dmr hf.co/a/tiny-gguf:q4 a/tiny-GGUF Q4 100000000 apache-2.0 1 8192 135
  local_registry_put dmr hf.co/a/notools-gguf:q4 a/notools-GGUF Q4 4000000000 mit 0 32768 7000
  local_registry_put dmr hf.co/a/mid-gguf:q4 a/mid-GGUF Q4 3000000000 mit 1 32768 4000
  local_registry_put dmr hf.co/a/big-gguf:q4 a/big-GGUF Q4 8000000000 mit 1 131072 32000
  printf 'LOCAL_MODELS=dmr:hf.co/a/tiny-gguf:q4,dmr:hf.co/a/notools-gguf:q4,dmr:hf.co/a/mid-gguf:q4,dmr:hf.co/a/big-gguf:q4\n' > "$ENV_FILE"
  rows="$(code_models_rows "")"
  col() { printf '%s\n' "$rows" | awk -F'\t' -v i="lm/a/$1" -v c="$2" '$1 == i { print $c }'; }
  for m in tiny-gguf:q4 notools-gguf:q4 mid-gguf:q4 big-gguf:q4; do
    assert_eq "$(col "$m" 3)" Local             # provider
    assert_eq "$(col "$m" 9)" 1                 # free: $0 Actual, never spend
    assert_eq "$(col "$m" 5)" 0
    assert_eq "$(col "$m" 6)" 0
  done
  assert_eq "$(col tiny-gguf:q4 10)" chat-only       # under 3B parameters
  assert_contains "$(col tiny-gguf:q4 15)" "calls tools wrongly or repeats itself"
  assert_eq "$(col notools-gguf:q4 10)" chat-only    # its chat template has no tool support
  assert_contains "$(col notools-gguf:q4 15)" "no tool-call support"
  assert_eq "$(col mid-gguf:q4 10)" untested         # under 7B: warned
  assert_contains "$(col mid-gguf:q4 15)" "under 7B"
  assert_eq "$(col big-gguf:q4 10)" untested
  assert_contains "$(col big-gguf:q4 15)" "capped at 4096 tokens"
  assert_eq "$(col big-gguf:q4 13)" 4096              # a stuck local model stops: its answers are capped
  assert_eq "$(col tiny-gguf:q4 13)" 4096
  assert_eq "$(col tiny-gguf:q4 2)" "tiny (Q4)"
}

test_the_gateways_model_list_gets_the_local_model_and_the_bn_keys() {
  _lm_env; _fake_dmr running
  printf 'claude-big\tchat\tbedrock/invoke/us.anthropic.big\t-\t-\n' > "$TMP/cat.tsv"
  CATALOG="$TMP/cat.tsv"; CODE_COMPAT=/dev/null; CODE_DISPLAY_TSV=/dev/null; PRICES=/dev/null; export CATALOG CODE_COMPAT CODE_DISPLAY_TSV PRICES
  local_registry_put dmr hf.co/a/big-gguf:q4 a/big-GGUF Q4 8000000000 mit 1 131072 32000
  printf 'LOCAL_MODELS=dmr:hf.co/a/big-gguf:q4\nCLAUDE_BEDROCK_OPUS_MODEL=claude-big\n' > "$ENV_FILE"
  printf 'claude-big\n' > "$TMP/en"
  cfg="$(render_litellm_config "$TMP/en" us-east-1 false)"
  assert_contains "$cfg" 'model_name: "lm/a/big-gguf:q4"'
  assert_contains "$cfg" 'bn_id: "lm/a/big-gguf:q4"'
  assert_contains "$cfg" 'bn_vendor: "a"'
  assert_contains "$cfg" 'id: "bn-lm_2Fa_2Fbig-gguf_3Aq4"'
  # nothing when LOCAL_MODELS is empty
  printf 'CLAUDE_BEDROCK_OPUS_MODEL=claude-big\n' > "$ENV_FILE"
  ! render_litellm_config "$TMP/en" us-east-1 false | grep -q 'lm/'
}

test_ollama_pulls_over_its_api_with_progress_and_is_registered_with_its_own_provider() {
  _lm_env; _fake_dmr off; _fake_apply
  : > "$TMP/ollama.models"
  curl() {
    case "$*" in
      *api/version*) return 0 ;;
      *api/pull*) printf '{"status":"pulling manifest"}\n{"status":"pulling abc","digest":"sha256:a","total":1000,"completed":10}\n{"status":"pulling abc","digest":"sha256:a","total":105000000,"completed":52000000}\n{"status":"pulling tmpl","total":500,"completed":500}\n{"status":"success"}\n'
                  printf 'hf.co/bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M\n' >> "$TMP/ollama.models"; sleep 0.3; return 0 ;;
      *api/tags*) printf '{"models":['; awk 'NR > 1 { printf "," } { printf "{\"name\":\"%s\"}", $0 }' "$TMP/ollama.models"; printf ']}\n'; return 0 ;;
      *api/delete*) : > "$TMP/ollama.models"; return 0 ;;
    esac
    return 7
  }
  assert_eq "$(local_runtime)" ollama
  local_pull bartowski/SmolLM2-135M-Instruct-GGUF Q4_K_M --bytes 105000000 2>/dev/null
  assert_eq "$(get_env LOCAL_MODELS)" "ollama:hf.co/bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M"   # the case Ollama lists
  y="$(local_models_yaml)"
  assert_contains "$y" 'model: "ollama_chat/hf.co/bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M"'
  assert_contains "$y" 'api_base: "http://host.docker.internal:11434"'
  # removal: unregistered first, then deleted
  local_rm bartowski/SmolLM2-135M-Instruct-GGUF Q4_K_M 2>/dev/null
  assert_eq "$(get_env LOCAL_MODELS)" ""
  assert_eq "$(local_registry_rows)" ""
  assert_eq "$(cat "$TMP/ollama.models")" ""
}

test_a_removal_unregisters_then_deletes_and_a_failed_delete_is_said() {
  _lm_env; _fake_dmr running; _fake_apply
  local_pull a/b-GGUF Q4_K_M --bytes 1000 2>/dev/null
  assert_contains "$(get_env LOCAL_MODELS)" "dmr:hf.co/a/b-gguf:q4_k_m"
  local_rm a/b-GGUF Q4_K_M 2>/dev/null
  assert_eq "$(get_env LOCAL_MODELS)" ""
  assert_eq "$(cat "$TMP/dmr/models")" ""
  assert_contains "$(cat "$STATE_DIR/local-models/job.json")" '"message":"Removed"'
  # not a model this stack downloaded
  ( local_rm x/y Q4 ) 2>/dev/null && return 1
  return 0
}

test_a_failing_download_says_why_and_registers_nothing() {
  _lm_env; _fake_dmr running; _fake_apply
  docker() { case "$*" in "info "*) echo "Docker Desktop" ;; "model version"*) return 0 ;; "model status"*) echo '{"running":true}' ;; "model pull"*) echo "Error: unauthorized (HTTP 401)" >&2; return 1 ;; esac; }
  ( local_pull a/gated-GGUF Q4_K_M --bytes 1000 ) 2>/dev/null && return 1
  assert_eq "$(get_env LOCAL_MODELS)" ""
  j="$(cat "$STATE_DIR/local-models/job.json")"
  assert_contains "$j" '"state":"failed"'
  assert_contains "$j" 'Hugging Face token'
}

test_only_hf_repos_and_quant_names_reach_a_pull() {
  _lm_env; _fake_dmr running
  ( local_pull 'evil.com/x/y' Q4 ) 2>/dev/null && return 1
  ( local_pull 'a/b' 'Q4 --foo' ) 2>/dev/null && return 1
  ( local_pull 'a/b' '../../x' ) 2>/dev/null && return 1
  ! grep -q "model pull" "$TMP/docker.log"
}

test_the_helper_checks_a_local_request_field_by_field() {
  . "$STACK_DIR/lib/helper.sh"; . "$STACK_DIR/lib/settings_helper.sh"
  _lm_env; mkdir -p "$STATE_DIR/helper"
  now="$(date +%s)"; n="$(printf 'ab%.0s' $(seq 16))"; auth="$(printf 'correct horse battery' | openssl base64 -A)"
  mk() { printf '%s' "$1" > "$TMP/act-$n.json"; }
  base="\"requested_at\":$now,\"nonce\":\"$n\",\"auth\":\"$auth\""
  mk "{\"action\":\"local-pull\",$base,\"repo\":\"a/b-GGUF\",\"quant\":\"Q4_K_M\",\"bytes\":1000,\"tools\":\"yes\",\"context\":8192,\"params_m\":135,\"license\":\"apache-2.0\"}"
  out="$(act_check_request "$TMP/act-$n.json" "act-$n.json" 2>&1)" || { echo "$out" >&2; return 1; }
  assert_contains "$out" "local-pull $n"
  assert_contains "$out" "a/b-GGUF|Q4_K_M|1000|yes|8192|135|apache-2.0"
  mk "{\"action\":\"local-remove\",$base,\"repo\":\"a/b-GGUF\",\"quant\":\"Q4_K_M\"}"
  act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  # a URL, a path or an extra field is refused
  mk "{\"action\":\"local-pull\",$base,\"repo\":\"https://evil.com/x\",\"quant\":\"Q4_K_M\",\"bytes\":1,\"tools\":\"yes\",\"context\":1,\"params_m\":1,\"license\":\"mit\"}"
  ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  mk "{\"action\":\"local-pull\",$base,\"repo\":\"a/b\",\"quant\":\"../x\",\"bytes\":1,\"tools\":\"yes\",\"context\":1,\"params_m\":1,\"license\":\"mit\"}"
  ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  mk "{\"action\":\"local-remove\",$base,\"repo\":\"a/b\",\"quant\":\"Q4\",\"path\":\"/etc\"}"
  ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  # the model-server form's request: op, name, address, trust, key (base64), models, ref — and nothing else
  local k64; k64="$(printf 'secretkey123456' | openssl base64 -A)"
  mk "{\"action\":\"local-server\",$base,\"op\":\"save\",\"name\":\"lab\",\"url\":\"https://10.0.0.5:8000/x\",\"trust\":true,\"key\":\"$k64\",\"models\":\"qwen/Qwen3-8B,llama3:8b\",\"ref\":\"0123456789abcdef\"}"
  out="$(act_check_request "$TMP/act-$n.json" "act-$n.json" 2>&1)" || { echo "$out" >&2; return 1; }
  assert_contains "$out" " save|lab|https://10.0.0.5:8000/x|true|$k64|qwen/Qwen3-8B,llama3:8b|0123456789abcdef"
  mk "{\"action\":\"local-server\",$base,\"op\":\"probe\",\"name\":\"\",\"url\":\"http://[fd00::5]:8000\",\"trust\":false,\"key\":\"\",\"models\":\"\",\"ref\":\"0123456789abcdef\"}"
  act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  for bad in '"op":"probe","name":"","url":"http://a b","trust":false,"key":"","models":"","ref":"0123456789abcdef"' \
             '"op":"probe","name":"","url":"file:///etc/passwd","trust":false,"key":"","models":"","ref":"0123456789abcdef"' \
             '"op":"probe","name":"","url":"http://u:p@h","trust":false,"key":"","models":"","ref":"0123456789abcdef"' \
             '"op":"drop","name":"x","url":"","trust":false,"key":"","models":"","ref":"0123456789abcdef"' \
             '"op":"models","name":"x; rm","url":"","trust":false,"key":"","models":"","ref":"0123456789abcdef"' \
             '"op":"models","name":"x","url":"","trust":false,"key":"","models":"a b","ref":"0123456789abcdef"' \
             '"op":"models","name":"x","url":"","trust":false,"key":"","models":"","ref":"xyz"' \
             '"op":"key","name":"x","url":"","trust":false,"key":"a$b","models":"","ref":"0123456789abcdef"'; do
    mk "{\"action\":\"local-server\",$base,$bad}"
    ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  done
}

test_the_form_check_is_read_only_so_it_carries_no_password_and_nothing_else_may_go_without_one() {
  . "$STACK_DIR/lib/helper.sh"; . "$STACK_DIR/lib/settings_helper.sh"
  _lm_env; mkdir -p "$STATE_DIR/helper"
  now="$(date +%s)"; n="$(printf 'cd%.0s' $(seq 16))"; auth="$(printf 'correct horse battery' | openssl base64 -A)"
  mk() { printf '%s' "$1" > "$TMP/act-$n.json"; }
  local k64 out; k64="$(printf 'secretkey123456' | openssl base64 -A)"
  # local-probe: address, trust, key, ref and no auth: its fields come out packed for the same probe, with "-" for the password
  mk "{\"action\":\"local-probe\",\"requested_at\":$now,\"nonce\":\"$n\",\"url\":\"http://localhost:11434\",\"trust\":false,\"key\":\"$k64\",\"ref\":\"0123456789abcdef\"}"
  out="$(act_check_request "$TMP/act-$n.json" "act-$n.json" 2>&1)" || { echo "$out" >&2; return 1; }
  assert_contains "$out" "local-probe $n - "
  assert_contains "$out" "probe-local||http://localhost:11434|false|$k64||0123456789abcdef"
  # a password in it, another op, a path or any extra field is not a probe request
  mk "{\"action\":\"local-probe\",\"requested_at\":$now,\"nonce\":\"$n\",\"auth\":\"$auth\",\"url\":\"http://localhost:11434\",\"trust\":false,\"key\":\"\",\"ref\":\"0123456789abcdef\"}"
  ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  mk "{\"action\":\"local-probe\",\"requested_at\":$now,\"nonce\":\"$n\",\"url\":\"file:///etc/passwd\",\"trust\":false,\"key\":\"\",\"ref\":\"0123456789abcdef\"}"
  ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  mk "{\"action\":\"local-probe\",\"requested_at\":$now,\"nonce\":\"$n\",\"op\":\"save\",\"name\":\"lab\",\"url\":\"http://10.0.0.5:8000\",\"trust\":false,\"key\":\"\",\"models\":\"*\",\"ref\":\"0123456789abcdef\"}"
  ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  # (local-server with no password, whatever its op, is still refused: only the check is read-only)
  for op in probe save models key remove; do
    mk "{\"action\":\"local-server\",\"requested_at\":$now,\"nonce\":\"$n\",\"op\":\"$op\",\"name\":\"lab\",\"url\":\"http://10.0.0.5:8000\",\"trust\":false,\"key\":\"\",\"models\":\"\",\"ref\":\"0123456789abcdef\"}"
    ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
    mk "{\"action\":\"local-server\",\"requested_at\":$now,\"nonce\":\"$n\",\"auth\":\"\",\"op\":\"$op\",\"name\":\"lab\",\"url\":\"http://10.0.0.5:8000\",\"trust\":false,\"key\":\"\",\"models\":\"\",\"ref\":\"0123456789abcdef\"}"
    ! act_check_request "$TMP/act-$n.json" "act-$n.json" >/dev/null 2>&1
  done
  case " $LOCAL_HELPER_ACTIONS " in *" local-probe "*) ;; *) return 1 ;; esac
}

test_a_check_without_a_password_still_refuses_metadata_and_link_local_targets_and_never_saves_anything() {
  _lm_env; export BEDROCK_NOW_TESTING=1 MSRV_TEST_RESOLVE=''
  local_status_write() { :; }                                               # (the portal's file is not this test's business: no runtime is asked)
  local u rf before
  before="$(cat "$ENV_FILE")"
  for u in http://169.254.169.254 http://169.254.0.1:8080 'http://[fe80::1]' 'http://[::ffff:169.254.169.254]' http://metadata.google.internal http://0xa9fea9fe; do
   for op in probe-local probe; do
    rf="$TMP/req.$RANDOM"
    printf 'op=%s\nname=\nurl=%s\ntrust=false\nkey=\nmodels=\nref=0123456789abcdef\n' "$op" "$u" > "$rf"
    msrv_apply "$rf" >/dev/null 2>&1
    out="$(cat "$(local_dir)/server-result.json")"
    # (refused as blocked or numeric by the checker, or not taken as an address at all: never reached, never "ok")
    case "$out" in *'"status":"blocked"'* | *'"status":"numeric"'* | *'"ok":false'*) ;; *) echo "not refused: $u -> $out"; return 1 ;; esac
    case "$out" in *'"status":"ok"'*) echo "reached: $u -> $out"; return 1 ;; esac
   done
  done
  assert_eq "$(cat "$ENV_FILE")" "$before"                                  # (a check never writes the config)
}

test_the_password_free_check_reaches_this_computer_only_judged_on_the_pinned_address() {
  _lm_env; _fake_srv 0 200 "$VLLM"
  export MSRV_TEST_RESOLVE="$MSRV_TEST_RESOLVE;loop.example.org=127.0.0.1;rebind.example.org=192.168.1.9"
  local_status_write() { :; }
  local u rf out before
  before="$(cat "$ENV_FILE")"
  # another computer — by address, by name, or a name that answers a network address — is not checked without the password
  for u in http://192.168.1.9:11434 http://10.0.0.5:8000 http://box.lan:8000 http://gpu.example.org http://rebind.example.org:8000 'http://[fd00::5]:8000'; do
    rf="$TMP/req.$RANDOM"
    printf 'op=probe-local\nname=\nurl=%s\ntrust=false\nkey=\nmodels=\nref=0123456789abcdef\n' "$u" > "$rf"
    msrv_apply "$rf" >/dev/null 2>&1
    out="$(cat "$(local_dir)/server-result.json")"
    case "$out" in *'"status":"blocked"'*) ;; *) echo "checked without a password: $u -> $out"; return 1 ;; esac
    assert_contains "$out" "portal password"
  done
  assert_eq "$(cat "$TMP/curl.args")" ""                                    # (none of them was contacted)
  # this computer — localhost, 127.x, ::1, a name pinned to 127.0.0.1 — is
  for u in http://localhost:11434 http://127.0.0.1:1234 'http://[::1]:8000' http://loop.example.org:8000; do
    rf="$TMP/req.$RANDOM"
    printf 'op=probe-local\nname=\nurl=%s\ntrust=false\nkey=\nmodels=\nref=0123456789abcdef\n' "$u" > "$rf"
    msrv_apply "$rf" >/dev/null 2>&1
    out="$(cat "$(local_dir)/server-result.json")"
    case "$out" in *'"status":"ok"'*) ;; *) echo "not checked: $u -> $out"; return 1 ;; esac
  done
  assert_contains "$(cat "$TMP/curl.args")" "--resolve loop.example.org:8000:127.0.0.1"   # (the request goes where it was judged)
  # (the password's probe of another computer is unchanged)
  rf="$TMP/req.$RANDOM"; printf 'op=probe\nname=\nurl=http://192.168.1.9:11434\ntrust=false\nkey=\nmodels=\nref=0123456789abcdef\n' > "$rf"
  msrv_apply "$rf" >/dev/null 2>&1
  assert_contains "$(cat "$(local_dir)/server-result.json")" '"status":"ok"'
  assert_eq "$(cat "$ENV_FILE")" "$before"
}

test_the_helper_starts_a_server_request_through_a_private_file_and_the_key_is_never_on_a_command_line() {
  . "$STACK_DIR/lib/helper.sh"; . "$STACK_DIR/lib/settings_helper.sh"
  _lm_env; mkdir -p "$STATE_DIR/helper"
  STACK_DIR="$TMP/fakestack"; mkdir -p "$STACK_DIR"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/stack.args"; cp "$4" "%s/stack.req" 2>/dev/null; exit 0\n' "$TMP" "$TMP" > "$STACK_DIR/stack"; chmod +x "$STACK_DIR/stack"
  local_server_start "save|lab|http://10.0.0.5:8000|false|c2VjcmV0a2V5|llama3:8b|0123456789abcdef"
  sleep 1
  assert_contains "$(cat "$TMP/stack.args")" "local-models server apply"
  assert_not_contains "$(cat "$TMP/stack.args")" c2VjcmV0a2V5                          # (only a file's path is on the command line)
  assert_contains "$(cat "$TMP/stack.req")" "key=c2VjcmV0a2V5"
}

test_settings_know_the_local_models_and_the_token() {
  [ "$(setting_field LOCAL_MODELS 5)" = local_models ]
  [ "$(setting_field LOCAL_MODELS 6)" = litellm-cfg ]
  [ "$(setting_field HF_TOKEN 3)" = S ]
  [ "$(setting_field HF_TOKEN 6)" = - ]
  # the token is a secret: never printed by config get
  ( ./stack config get HF_TOKEN ) 2>&1 | grep -q "secret" || true
}

test_the_stack_command_is_in_help() {
  assert_contains "$(cmd_help)" "local-models"
}

# --- MLX (Apple silicon's primary runtime): a fake uv, launchctl and venv; nothing real runs ---
SHA_A="$(printf 'a%.0s' $(seq 40))"; SHA_B="$(printf 'b%.0s' $(seq 40))"   # (two commits of the same repo)
_fake_mlx() {   # _fake_mlx — VET_REASON / VET_SHA (set before) say what the vet answers; FAKE_DL_SHA / FAKE_CFG what the download writes
  local b; unset LOCAL_MLX; export LOCAL_MLX=force; mkdir -p "$TMP/home"; HOME="$TMP/home"; export HOME
  uname() { case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) command uname "$@" ;; esac; }
  command() { if [ "$1" = -v ] && [ "$2" = uv ]; then return 0; fi; builtin command "$@"; }
  b="$STATE_DIR/mlx/venv/bin"
  uv() {   # uv venv ... DIR / uv pip install ...: the venv's three programs
    case "$1" in
      venv) local d; for d in "$@"; do :; done; mkdir -p "$d/bin"
        printf '#!/bin/sh\nexit 0\n' > "$d/bin/mlx_lm.server"
        # the vet prints "sha <commit>" or "no <why>"; the fake hf writes the snapshot of $FAKE_DL_SHA (default: the revision it was asked for)
        printf '#!/bin/sh\nif [ -n "%s" ]; then echo "no %s"; else echo "sha %s"; fi\n' "$VET_REASON" "$VET_REASON" "${VET_SHA:-$SHA_A}" > "$d/bin/python"
        cat > "$d/bin/hf" <<'EOS'
#!/bin/sh
rev=''; prev=''; for a in "$@"; do [ "$prev" = --revision ] && rev="$a"; prev="$a"; done
mkdir -p "$HF_HOME"; echo "$*" > "$HF_HOME/hf-args"; echo "$HF_TOKEN" > "$HF_HOME/token-seen"
case "$*" in *"--exclude *.py"*) echo excluded > "$HF_HOME/excl";; esac
sha="${FAKE_DL_SHA:-$rev}"; r="$HF_HOME/hub/models--mlx-community--Tiny-4bit"
mkdir -p "$r/blobs" "$r/snapshots/$sha"; head -c 2000000 /dev/zero > "$r/blobs/w"
if [ -n "$FAKE_CFG" ]; then printf '%s' "$FAKE_CFG" > "$r/snapshots/$sha/config.json"; else printf '{"model_type":"llama"}' > "$r/snapshots/$sha/config.json"; fi
EOS
        chmod +x "$d/bin/"*; return 0 ;;
      pip) grep -q -- "--require-hashes" <<< "$*" && echo hashes > "$TMP/uv-pip" ; return 0 ;;
    esac
  }
  docker() { return 1; }
  launchctl() { echo "$*" >> "$TMP/launchctl.log"; return 0; }
  MLX_UP=0; curl() { [ "$MLX_UP" = 1 ] && return 0; return 7; }
}
test_mlx_is_the_runtime_on_apple_silicon_and_a_pull_installs_vets_downloads_serves_and_registers() {
  _lm_env; _fake_apply; _fake_mlx; VET_REASON=''
  assert_eq "$(local_runtime)" mlx
  assert_eq "$(local_mlx_state)" not-installed
  launchctl() { echo "$*" >> "$TMP/launchctl.log"; MLX_UP=1; return 0; }
  printf 'HF_TOKEN=%s\n' "$TOKEN_FAKE" >> "$ENV_FILE"
  local_pull mlx-community/Tiny-4bit mlx --bytes 2000000 --tools yes --params-m 500 --context 8192 --license apache-2.0 >/dev/null 2>&1
  assert_eq "$(get_env LOCAL_MODELS)" "mlx:mlx-community/Tiny-4bit"
  assert_contains "$(cat "$TMP/uv-pip")" hashes                          # installed from the hash-locked file
  assert_contains "$(cat "$TMP/launchctl.log")" bootstrap                # served as a launchd user agent
  assert_contains "$(cat "$HOME/Library/LaunchAgents/"dev.devos.ade.mlx.*.plist)" "<string>127.0.0.1</string>"
  assert_not_contains "$(cat "$HOME/Library/LaunchAgents/"dev.devos.ade.mlx.*.plist)" "trust-remote-code"
  assert_not_contains "$(cat "$HOME/Library/LaunchAgents/"dev.devos.ade.mlx.*.plist)" "$TOKEN_FAKE"   # the token never reaches the server
  assert_contains "$(cat "$HOME/Library/LaunchAgents/"dev.devos.ade.mlx.*.plist)" "HF_HUB_OFFLINE"
  assert_eq "$(cat "$STATE_DIR/mlx/hf/excl")" excluded                   # no .py file is ever fetched
  assert_contains "$(cat "$STATE_DIR/mlx/hf/hf-args")" "--revision $SHA_A"   # the download is pinned to the commit that was vetted
  assert_contains "$(local_registry_rows)" "$SHA_A"                         # and the registry keeps it
  local_status_write; assert_contains "$(cat "$(local_status_file)")" "\"revision\":\"$SHA_A\""
  assert_eq "$(local_models_yaml | grep -c 'openai/mlx-community/Tiny-4bit')" 1
  assert_contains "$(local_models_yaml)" 'api_base: "http://host.docker.internal:18765/v1"'
  assert_contains "$(local_models_yaml)" 'input_cost_per_token: 0'
  assert_contains "$(local_models_code_rows)" "lm/mlx-community/Tiny-4bit"
  # a removal deletes the files exactly
  local_rm mlx-community/Tiny-4bit mlx >/dev/null 2>&1
  [ ! -d "$STATE_DIR/mlx/hf/hub/models--mlx-community--Tiny-4bit" ]
  assert_eq "$(get_env LOCAL_MODELS)" ""
}
test_mlx_refuses_a_repo_that_runs_custom_code_and_deletes_what_it_fetched() {
  _lm_env; _fake_apply; _fake_mlx; VET_REASON="its config.json asks to run custom code (model_file)"
  mkdir -p "$STATE_DIR/mlx/hf/hub/models--evil--Model"
  ! ( local_pull evil/Model mlx ) >/dev/null 2>&1
  assert_contains "$(cat "$(local_job_file)")" '"state":"failed"'
  assert_contains "$(cat "$(local_job_file)")" "never runs a model"
  [ ! -d "$STATE_DIR/mlx/hf/hub/models--evil--Model" ]
  assert_eq "$(get_env LOCAL_MODELS)" ""
}
test_mlx_without_uv_says_how_and_uninstall_removes_the_agent_and_venv() {
  _lm_env; _fake_mlx
  command() { if [ "$1" = -v ] && [ "$2" = uv ]; then return 1; fi; builtin command "$@"; }
  assert_eq "$(local_mlx_state)" no-uv
  assert_contains "$(local_how_text)" "brew install uv"
  _fake_mlx; mkdir -p "$STATE_DIR/mlx/venv/bin" "$STATE_DIR/mlx/hf"; : > "$STATE_DIR/mlx/venv/bin/mlx_lm.server"
  mkdir -p "$HOME/Library/LaunchAgents"; : > "$HOME/Library/LaunchAgents/$(local_mlx_label).plist"
  local_mlx_uninstall
  [ ! -e "$STATE_DIR/mlx/venv" ] && [ ! -e "$HOME/Library/LaunchAgents/$(local_mlx_label).plist" ] && [ -d "$STATE_DIR/mlx/hf" ]   # the models stay without --models
  local_mlx_uninstall --models
  [ ! -e "$STATE_DIR/mlx" ]
}

# --- model servers: any OpenAI-compatible endpoint (a fake curl answers; nothing is contacted) ---
_fake_srv() {   # _fake_srv RC HTTP BODY — what curl returns for the next probes; records its arguments and its stdin config
  docker() { return 1; }
  _fake_apply
  export BEDROCK_NOW_TESTING=1 MSRV_TEST_RESOLVE='localhost=127.0.0.1;gpu.example.org=203.0.113.7;nas.lan=203.0.113.8;lab.example.org=203.0.113.7;box.lan=192.168.1.9'   # (no real DNS)
  FAKE_RC="$1"; FAKE_HTTP="$2"; FAKE_BODY="${3:-}"
  : > "$TMP/curl.args"; : > "$TMP/curl.stdin"
  curl() {
    local out='' a prev=''
    for a in "$@"; do [ "$prev" = -o ] && out="$a"; prev="$a"; done
    printf '%s\n' "$*" >> "$TMP/curl.args"; cat >> "$TMP/curl.stdin" 2>/dev/null || true
    [ -z "$out" ] || printf '%s' "$FAKE_BODY" > "$out"
    printf '%s' "$FAKE_HTTP"; return "$FAKE_RC"
  }
}
VLLM='{"object":"list","data":[{"id":"qwen/Qwen3-8B","object":"model","max_model_len":32768},{"id":"llama3:8b","object":"model"}]}'

test_server_urls_are_normalized_and_localhost_means_this_computer() {
  assert_eq "$(msrv_norm_url 10.0.0.5:8000)" "http://10.0.0.5:8000"
  assert_eq "$(msrv_norm_url https://gpu.example.org/v1/)" "https://gpu.example.org"
  assert_eq "$(msrv_norm_url http://lab.local:1234/api/v1)" "http://lab.local:1234/api"
  assert_eq "$(msrv_norm_url 'http://[::1]:8080')" "http://[::1]:8080"
  ! msrv_norm_url 'http://user:pw@10.0.0.5' ; ! msrv_norm_url 'http://h/?key=1' ; ! msrv_norm_url 'ftp://h' ; ! msrv_norm_url 'http://h:99999999'
  _lm_env 'MODEL_SERVERS=a=http://localhost:11434,b=http://127.0.0.1:8080/x,c=http://[::1]:9,d=http://10.1.2.3:8000,e=https://gpu.example.org;trust
'
  _fake_srv 0 200 "$VLLM"; msrv_probe_all
  assert_eq "$(msrv_gateway_url a)" "http://host.docker.internal:11434/v1"
  assert_eq "$(msrv_gateway_url b)" "http://host.docker.internal:8080/x/v1"
  assert_eq "$(msrv_gateway_url c)" "http://host.docker.internal:9/v1"
  assert_eq "$(msrv_gateway_url d)" "http://10.1.2.3:8000/v1"
  assert_contains "$(msrv_reached_as a)" "reached from the gateway as http://host.docker.internal:11434/v1"
  assert_eq "$(msrv_gateway_url e)" "https://gpu.example.org/v1"   # https keeps the name (SNI); http uses the checked address
  assert_eq "$(msrv_trust e)" 1; assert_eq "$(msrv_trust d)" 0
  # plain http to a public address is allowed with a warning; private, loopback and tailnet addresses are not warned about
  assert_contains "$(msrv_warn http://203.0.113.9:8000)" "unencrypted"
  assert_eq "$(msrv_warn http://192.168.1.4:8000)" ""; assert_eq "$(msrv_warn http://127.0.0.1:1)" ""
  assert_eq "$(msrv_warn http://box.tail1234.ts.net:8000)" ""; assert_eq "$(msrv_warn https://gpu.example.org)" ""
}

test_a_probe_lists_what_a_server_serves_with_its_context_and_says_each_failure_exactly() {
  _lm_env 'MODEL_SERVERS=lab=http://10.0.0.5:8000
'
  _fake_srv 0 200 "$VLLM"
  assert_eq "$(msrv_probe lab)" "$(printf 'ok\tqwen/Qwen3-8B|32768;llama3:8b|0\t10.0.0.5')"
  assert_contains "$(cat "$TMP/curl.args")" "http://10.0.0.5:8000/v1/models"
  _fake_srv 0 200 '{"data":[]}';   assert_contains "$(msrv_probe lab)" "lists no models"
  _fake_srv 6 000;  assert_contains "$(msrv_probe lab)" "does not resolve (DNS)"
  _fake_srv 7 000;  assert_contains "$(msrv_probe lab)" "connection refused"
  _fake_srv 28 000; assert_contains "$(msrv_probe lab)" "no answer in time"
  _fake_srv 60 000; assert_contains "$(msrv_probe lab)" "certificate is not trusted"
  _fake_srv 0 401;  assert_contains "$(msrv_probe lab)" "401: the server wants an API key"
  _fake_srv 0 404;  assert_contains "$(msrv_probe lab)" "no /v1/models at that address"
  _fake_srv 0 502;  assert_contains "$(msrv_probe lab)" "HTTP 502"
}

test_a_servers_key_goes_to_curl_on_stdin_and_never_in_an_argument_or_the_status_file_and_trust_is_per_server() {
  _lm_env "MODEL_SERVERS=lab=http://10.0.0.5:8000,self=https://nas.lan:8443;trust
MODEL_SERVER_KEYS=lab=$(_msrv_hash http://10.0.0.5:8000 0):secretkey123456
"
  _fake_srv 0 200 "$VLLM"
  msrv_probe lab >/dev/null; msrv_probe self >/dev/null
  assert_not_contains "$(cat "$TMP/curl.args")" secretkey123456
  assert_contains "$(cat "$TMP/curl.stdin")" "Authorization: Bearer secretkey123456"
  assert_eq "$(grep -c -- ' -k ' "$TMP/curl.args")" 1                 # -k for the one server that is trusted, not for lab
  msrv_probe_all; local_status_write
  assert_not_contains "$(cat "$(local_status_file)")" secretkey123456
  assert_contains "$(cat "$(local_status_file)")" '"key":true'
}

test_enabled_models_are_registered_at_zero_namespaced_per_server_and_an_unreachable_one_is_marked() {
  _lm_env "MODEL_SERVERS=lab=http://10.0.0.5:8000,mac=http://localhost:8080
MODEL_SERVER_MODELS=lab:*,mac:phi
MODEL_SERVER_KEYS=lab=$(_msrv_hash http://10.0.0.5:8000 0):secretkey123456
"
  _fake_srv 0 200 "$VLLM"
  msrv_probe_all
  local y; y="$(local_models_yaml)"
  assert_contains "$y" 'model_name: "ms/lab/qwen/Qwen3-8B"'
  assert_contains "$y" 'model_name: "ms/lab/llama3:8b"'
  assert_contains "$y" 'model_name: "ms/mac/phi"'
  assert_contains "$y" 'api_base: "http://host.docker.internal:8080/v1"'
  assert_contains "$y" 'input_cost_per_token: 0'
  _fake_srv 7 000; msrv_probe_all
  assert_contains "$(local_models_code_rows)" "UNAVAILABLE at the last check: connection refused"
  assert_contains "$(local_models_code_rows)" "Tool use is not known"
  assert_contains "$(local_models_code_rows | head -n 1)" "ms/mac/phi"
}

test_adding_enabling_and_removing_a_server_apply_live_and_a_removal_takes_its_models_and_key() {
  _lm_env ''; _fake_apply; _fake_srv 0 200 "$VLLM"
  msrv_add lab 10.0.0.5:8000 >/dev/null 2>&1
  assert_eq "$(get_env MODEL_SERVERS)" "lab=http://10.0.0.5:8000"
  ! ( msrv_add lab http://x ) >/dev/null 2>&1                    # a name is used once
  ! ( msrv_add 'Bad Name' http://x ) >/dev/null 2>&1
  msrv_enable lab 'llama3:8b' on >/dev/null 2>&1
  assert_eq "$(get_env MODEL_SERVER_MODELS)" "lab:llama3:8b"
  assert_contains "$(local_models_yaml)" 'model_name: "ms/lab/llama3:8b"'
  printf 'abcdef123456\n' | msrv_set_key lab >/dev/null 2>&1
  assert_eq "$(get_env MODEL_SERVER_KEYS)" "lab=$(_msrv_hash http://10.0.0.5:8000 0):abcdef123456"
  msrv_rm lab >/dev/null 2>&1
  assert_eq "$(get_env MODEL_SERVERS)" ""; assert_eq "$(get_env MODEL_SERVER_MODELS)" ""; assert_eq "$(get_env MODEL_SERVER_KEYS)" ""
  assert_eq "$(local_models_yaml)" ""
}

# --- SSRF: no model server lives at a cloud-metadata or link-local address; the checked address is the one used ---
_tgt() { msrv_target "$1" | cut -f1; }
test_every_form_of_a_metadata_or_link_local_address_is_refused_and_loopback_and_private_stay_allowed() {
  local u
  export BEDROCK_NOW_TESTING=1 MSRV_TEST_RESOLVE=''
  for u in http://169.254.169.254 http://169.254.0.1:8080 http://100.100.100.200 http://0.1.2.3 http://224.0.0.1 http://255.255.255.255 http://240.0.0.1 http://0.0.0.0 \
           'http://[fe80::1]' 'http://[febf::1]:80' 'http://[fd00:ec2::254]' 'http://[fd00:0ec2:0:0:0:0:0:254]' 'http://[ff02::1]' 'http://[::]' \
           'http://[::ffff:169.254.169.254]' 'http://[::a9fe:a9fe]' 'http://[64:ff9b::a9fe:a9fe]' 'http://[64:ff9b:1::a9fe:a9fe]' 'http://[2002:a9fe:a9fe::]' \
           'http://[2001:0:a9fe:a9fe:8000:63bf:3fff:fdd2]' 'http://[2001:0:4136:e378:8000:63bf:5601:5601]' http://metadata.google.internal http://METADATA.AZURE.INTERNAL. http://instance-data; do
    [ "$(_tgt "$u")" = blocked ] || { echo "not refused: $u -> $(msrv_target "$u")"; return 1; }
  done
  # (the Teredo form above carries 169.254.169.254 as the CLIENT: ~0xa9fea9fe = 0x56015601)
  # non-canonical IPv4 (octal, short, hex, decimal, leading zeros) is refused as it is: curl would read them as another address
  for u in http://0251.0376.0251.0376 http://169.254.43518 http://169.16689662 http://0xa9fea9fe http://0xA9.0xFE.0xA9.0xFE http://2852039166 http://010.0.0.1 http://192.168.001.020 http://127.1 http://1; do
    [ "$(_tgt "$u")" = numeric ] || { echo "not refused as numeric: $u -> $(msrv_target "$u")"; return 1; }
  done
  assert_contains "$(msrv_target http://0251.0376.0251.0376)" "standard form (e.g. 192.168.1.20)"
  for u in http://127.0.0.1:8080 http://10.1.2.3 http://192.168.0.5:8000 http://172.16.0.1 http://172.31.255.254 http://100.64.1.1 http://100.100.100.201 http://8.8.8.8 'http://[::1]:80' 'http://[fd12:3456::1]' 'http://[2001:db8::1]' 'http://[::ffff:10.0.0.1]' 'http://[64:ff9b::808:808]' 'http://[2002:c0a8:0101::]'; do
    [ "$(_tgt "$u")" = ok ] || { echo "wrongly refused: $u -> $(msrv_target "$u")"; return 1; }
  done
  assert_eq "$(msrv_target https://10.0.0.5)" "$(printf 'ok\t10.0.0.5\t10.0.0.5\t443')"
  # a name: every address it resolves to is checked, a mix is refused, none is a DNS failure
  export MSRV_TEST_RESOLVE='ok.example.org=203.0.113.7;mix.example.org=203.0.113.7,169.254.169.254;wrapped.example.org=203.0.113.7,::a9fe:a9fe;none.example.org='
  assert_eq "$(_tgt http://ok.example.org)" ok
  assert_eq "$(_tgt http://mix.example.org)" blocked
  assert_eq "$(_tgt http://wrapped.example.org)" blocked
  assert_eq "$(_tgt http://none.example.org)" dns
}

test_a_probe_is_pinned_to_the_address_it_checked_so_dns_rebinding_cannot_swap_the_target() {
  _lm_env 'MODEL_SERVERS=gpu=https://gpu.example.org:8443
'
  _fake_srv 0 200 "$VLLM"
  assert_contains "$(msrv_probe gpu)" "ok"
  assert_contains "$(cat "$TMP/curl.args")" "--resolve gpu.example.org:8443:203.0.113.7"   # the request goes to the address that was checked
  : > "$TMP/curl.args"
  export MSRV_TEST_RESOLVE='gpu.example.org=169.254.169.254'                              # the name now answers the metadata address
  local r; r="$(msrv_probe gpu)"
  assert_contains "$r" "blocked"; assert_contains "$r" "no model server lives there"
  assert_eq "$(cat "$TMP/curl.args")" ""                                                    # and curl was never run
  export MSRV_TEST_RESOLVE='gpu.example.org=2001:db8::5'
  msrv_probe gpu >/dev/null
  assert_contains "$(cat "$TMP/curl.args")" "--resolve gpu.example.org:8443:[2001:db8::5]"
}

test_a_server_is_registered_only_when_its_address_was_validated_and_http_uses_the_checked_address() {
  _lm_env 'MODEL_SERVERS=lab=http://lab.example.org:8000,box=http://box.lan:9000,gone=http://nope.example.org,num=http://0xa9fea9fe,imds=http://169.254.169.254
MODEL_SERVER_MODELS=lab:*,box:*,box:phi,gone:x,num:x,imds:x,missing:x
'
  _fake_srv 0 200 "$VLLM"; export MSRV_TEST_RESOLVE="$MSRV_TEST_RESOLVE;nope.example.org="
  msrv_probe_all
  local y; y="$(local_models_yaml)"
  assert_contains "$y" 'model_name: "ms/lab/qwen/Qwen3-8B"'
  assert_contains "$y" 'api_base: "http://203.0.113.7:8000/v1"'            # http: the validated address, not the name
  assert_contains "$y" 'api_base: "http://192.168.1.9:9000/v1"'
  assert_not_contains "$y" 'lab.example.org'
  # not registered: a DNS failure, a non-canonical number, a metadata address, and a name with no status at all
  assert_not_contains "$y" 'ms/gone/'; assert_not_contains "$y" 'ms/num/'; assert_not_contains "$y" 'ms/imds/'; assert_not_contains "$y" 'ms/missing/'
  # a missing state file registers nothing either
  rm -f "$(msrv_state_file)"
  assert_eq "$(local_models_yaml)" ""
  # validated but not answering: still registered, and marked unavailable
  _fake_srv 7 000; msrv_probe_all
  assert_contains "$(local_models_yaml)" 'ms/box/phi'
  assert_contains "$(local_models_code_rows)" 'UNAVAILABLE at the last check'
}

test_a_blocked_server_is_not_added_and_one_that_turns_blocked_leaves_the_gateway() {
  _lm_env ''; _fake_apply; _fake_srv 0 200 "$VLLM"
  ! ( msrv_add imds http://169.254.169.254 ) >/dev/null 2>&1
  ! ( msrv_add meta http://metadata.google.internal ) >/dev/null 2>&1
  ! ( msrv_add hex http://0xa9fea9fe ) >/dev/null 2>&1
  assert_eq "$(get_env MODEL_SERVERS)" ""
  _lm_env 'MODEL_SERVERS=lab=http://lab.example.org:8000
MODEL_SERVER_MODELS=lab:*
'
  msrv_probe_all
  assert_contains "$(local_models_yaml)" 'ms/lab/'
  : > "$TMP/applied.env"
  export MSRV_TEST_RESOLVE='lab.example.org=169.254.169.254'
  msrv_probe_all
  assert_eq "$(local_models_yaml)" ""                                          # unregistered
  assert_contains "$(cat "$TMP/applied.env")" "MODEL_SERVER_MODELS"            # and the gateway was told, live
}

test_probe_errors_never_echo_what_a_server_sent_and_the_key_stays_out_of_every_output() {
  _lm_env "MODEL_SERVERS=lab=http://10.0.0.5:8000
MODEL_SERVER_KEYS=lab=$(_msrv_hash http://10.0.0.5:8000 0):secretkey123456
"
  local out
  _fake_srv 0 500 'TOPSECRET-BODY {"error":"internal path /etc/shadow"}'
  out="$(msrv_probe lab 2>&1)"; assert_not_contains "$out" TOPSECRET; assert_not_contains "$out" shadow; assert_contains "$out" "HTTP 500"
  _fake_srv 0 200 'TOPSECRET-BODY not json at all'
  out="$(msrv_probe lab 2>&1)"; assert_not_contains "$out" TOPSECRET
  _fake_srv 0 401 'TOPSECRET-BODY secretkey123456 echoed'
  out="$(msrv_probe lab 2>&1)"; assert_not_contains "$out" TOPSECRET; assert_not_contains "$out" secretkey123456
  msrv_probe_all; local_status_write
  assert_not_contains "$(cat "$(local_status_file)" "$(msrv_state_file)")" TOPSECRET
  assert_not_contains "$(cat "$(local_status_file)" "$(msrv_state_file)")" secretkey123456
  # the commands that handle the key print nothing of it either
  _fake_apply; out="$(printf 'abcdef123456\n' | msrv_set_key lab 2>&1)" || true; assert_not_contains "$out" abcdef123456
  out="$(msrv_enable lab '*' on 2>&1)" || true; assert_not_contains "$out" abcdef123456
  assert_not_contains "$(cat "$TMP/curl.args")" abcdef123456                    # (the stdin config carries it, never an argument)
}




# --- the Settings form's host side: ./stack local-models server apply FILE (probe a candidate, save with models, toggle, key, remove) ---
_apply() {   # _apply OP NAME URL TRUST KEY MODELS [REF] — a request file as the update helper writes it, then the apply
  local f="$TMP/server-req"
  printf 'op=%s\nname=%s\nurl=%s\ntrust=%s\nkey=%s\nmodels=%s\nref=%s\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | base64 | tr -d '\n')" "$6" "${7:-0123456789abcdef}" > "$f"
  [ -n "$5" ] || sed -i.bak 's/^key=.*/key=/' "$f"
  msrv_apply "$f" >/dev/null 2>&1
}
_result() { cat "$(local_dir)/server-result.json"; }

test_the_form_probe_reports_models_context_and_each_failure_and_saves_nothing() {
  _lm_env ''; _fake_srv 0 200 "$VLLM"
  _apply probe '' http://10.0.0.5:8000 false secretkey123456 '' aaaaaaaa11111111
  local r; r="$(_result)"
  assert_contains "$r" '"ref":"aaaaaaaa11111111"'; assert_contains "$r" '"ok":true'; assert_contains "$r" '"status":"ok"'
  assert_contains "$r" 'qwen/Qwen3-8B|32768;llama3:8b|0'; assert_contains "$r" '"key":true'
  assert_not_contains "$r" secretkey123456                                  # the key is never in what the page reads
  assert_not_contains "$(cat "$TMP/curl.args")" secretkey123456
  assert_contains "$(cat "$TMP/curl.stdin")" "Authorization: Bearer secretkey123456"
  assert_eq "$(get_env MODEL_SERVERS)" ""; [ ! -e "$TMP/server-req" ]       # (nothing saved; the request file is gone)
  _apply probe '' http://203.0.113.9:8000 false '' ''; assert_contains "$(_result)" "plain http to a public address"
  _fake_srv 7 000; _apply probe '' 10.0.0.5:8000 false '' ''
  assert_contains "$(_result)" '"status":"down"'; assert_contains "$(_result)" "connection refused"
  _apply probe '' http://169.254.169.254 false '' ''; assert_contains "$(_result)" '"status":"blocked"'
  _apply probe '' 'ftp://x' false '' ''; assert_contains "$(_result)" '"ok":false'
}

test_the_form_save_registers_the_ticked_models_live_with_the_key_and_a_blocked_or_duplicate_one_changes_nothing() {
  _lm_env ''; _fake_srv 0 200 "$VLLM"
  _apply save lab http://10.0.0.5:8000 false secretkey123456 'llama3:8b'
  assert_contains "$(_result)" '"ok":true'
  assert_eq "$(get_env MODEL_SERVERS)" "lab=http://10.0.0.5:8000"
  assert_eq "$(get_env MODEL_SERVER_KEYS)" "lab=$(_msrv_hash http://10.0.0.5:8000 0):secretkey123456"
  assert_eq "$(get_env MODEL_SERVER_MODELS)" "lab:llama3:8b"
  assert_contains "$(local_models_yaml)" 'model_name: "ms/lab/llama3:8b"'
  assert_not_contains "$(local_models_yaml)" 'qwen/Qwen3-8B'                # (only what was ticked)
  assert_not_contains "$(_result) $(cat "$(local_status_file)")" secretkey123456
  _apply save bad http://169.254.169.254 false '' '*'; assert_contains "$(_result)" "refused"
  assert_eq "$(get_env MODEL_SERVERS)" "lab=http://10.0.0.5:8000"
  _apply save 'Bad Name' http://10.0.0.7:8000 false '' '*'; assert_contains "$(_result)" '"ok":false'
}

test_the_form_changes_models_and_key_and_removes_a_server_and_its_models_and_key() {
  _lm_env ''; _fake_srv 0 200 "$VLLM"
  _apply save lab https://nas.lan:8443 true secretkey123456 'llama3:8b'
  assert_eq "$(get_env MODEL_SERVERS)" "lab=https://nas.lan:8443;trust"
  _apply models lab '' false '' 'llama3:8b,qwen/Qwen3-8B'
  assert_eq "$(get_env MODEL_SERVER_MODELS)" "lab:llama3:8b,lab:qwen/Qwen3-8B"
  assert_contains "$(local_models_yaml)" 'model_name: "ms/lab/qwen/Qwen3-8B"'
  _apply models lab '' false '' ''; assert_eq "$(get_env MODEL_SERVER_MODELS)" ""   # (none on)
  _apply models lab '' false '' '*'; assert_eq "$(get_env MODEL_SERVER_MODELS)" "lab:*"
  _apply key lab '' false newkey7654321 '';  assert_eq "$(get_env MODEL_SERVER_KEYS)" "lab=$(_msrv_hash https://nas.lan:8443 1):newkey7654321"
  _apply key lab '' false '' '';  assert_eq "$(get_env MODEL_SERVER_KEYS)" ""
  _apply models nope '' false '' '*'; assert_contains "$(_result)" "no server named nope"
  _apply remove lab '' false '' ''
  assert_contains "$(_result)" '"ok":true'
  assert_eq "$(get_env MODEL_SERVERS)" ""; assert_eq "$(get_env MODEL_SERVER_MODELS)" ""; assert_eq "$(local_models_yaml)" ""
  assert_not_contains "$(cat "$(local_status_file)")" newkey7654321
}

test_a_stored_key_goes_only_to_its_own_saved_address_and_a_changed_address_drops_it() {
  _lm_env ''; _fake_srv 0 200 "$VLLM"
  _apply save lab http://10.0.0.5:8000 false oldkey123456789 'llama3:8b'
  assert_eq "$(get_env MODEL_SERVER_KEYS)" "lab=$(_msrv_hash http://10.0.0.5:8000 0):oldkey123456789"
  # probing the saved address (under the server's name, no key typed) reuses the stored key
  : > "$TMP/curl.stdin"; _apply probe lab http://10.0.0.5:8000 false '' ''
  assert_contains "$(cat "$TMP/curl.stdin")" "Authorization: Bearer oldkey123456789"
  # probing another address under the same name sends no key at all (what the fake server received: no Authorization header)
  : > "$TMP/curl.stdin"; : > "$TMP/curl.args"
  _apply probe lab http://10.0.0.99:8000 false '' ''
  assert_not_contains "$(cat "$TMP/curl.stdin")" oldkey123456789
  assert_not_contains "$(cat "$TMP/curl.stdin")" Authorization
  assert_not_contains "$(cat "$TMP/curl.args")" oldkey123456789
  # a key typed with the request is the one used for a new address
  : > "$TMP/curl.stdin"; _apply probe lab http://10.0.0.99:8000 false typedkey123456 ''
  assert_contains "$(cat "$TMP/curl.stdin")" "Bearer typedkey123456"; assert_not_contains "$(cat "$TMP/curl.stdin")" oldkey123456789
  # saving the same address keeps its key; saving a changed address without a key clears it (and sends it nowhere)
  _apply save lab http://10.0.0.5:8000 false '' 'llama3:8b'
  assert_eq "$(get_env MODEL_SERVER_KEYS)" "lab=$(_msrv_hash http://10.0.0.5:8000 0):oldkey123456789"
  : > "$TMP/curl.stdin"; : > "$TMP/curl.args"
  _apply save lab http://10.0.0.99:8000 false '' 'llama3:8b'
  assert_eq "$(get_env MODEL_SERVERS)" "lab=http://10.0.0.99:8000"
  assert_eq "$(get_env MODEL_SERVER_KEYS)" ""
  assert_not_contains "$(cat "$TMP/curl.stdin" "$TMP/curl.args")" oldkey123456789
  assert_contains "$(local_models_yaml)" 'api_base: "http://10.0.0.99:8000/v1"'
  # saving a changed address with a new key keeps the new one
  _apply save lab http://10.0.0.77:8000 false newkey987654321 'llama3:8b'
  assert_eq "$(get_env MODEL_SERVER_KEYS)" "lab=$(_msrv_hash http://10.0.0.77:8000 0):newkey987654321"
  assert_not_contains "$(_result) $(cat "$(local_status_file)")" newkey987654321
}

# --- the download is the revision that was vetted, and what landed on disk is checked again before it is served ---
test_a_download_is_pinned_to_the_vetted_commit_and_a_different_one_at_download_time_is_refused() {
  _lm_env; _fake_apply; VET_REASON=''; VET_SHA="$SHA_A"; unset FAKE_CFG; export FAKE_DL_SHA="$SHA_B"; _fake_mlx
  launchctl() { echo "$*" >> "$TMP/launchctl.log"; MLX_UP=1; return 0; }
  # the Hub answers another commit than the one that was checked (a push in between, or anything else): refused, not served
  ! ( local_pull mlx-community/Tiny-4bit mlx --bytes 2000000 ) >/dev/null 2>&1
  assert_contains "$(cat "$STATE_DIR/mlx/hf/hf-args")" "--revision $SHA_A"
  assert_contains "$(cat "$(local_job_file)")" '"state":"failed"'
  assert_contains "$(cat "$(local_job_file)")" "not the revision that was checked"
  [ ! -d "$STATE_DIR/mlx/hf/hub/models--mlx-community--Tiny-4bit" ]
  assert_eq "$(get_env LOCAL_MODELS)" ""; assert_eq "$(local_registry_rows)" ""
  # a vet that gives no commit at all downloads nothing
  unset FAKE_DL_SHA; rm -f "$STATE_DIR/mlx/hf/hf-args"
  printf '#!/bin/sh\necho garbage\n' > "$STATE_DIR/mlx/venv/bin/python"; chmod +x "$STATE_DIR/mlx/venv/bin/python"
  ! ( local_pull mlx-community/Tiny-4bit mlx --bytes 2000000 ) >/dev/null 2>&1
  [ ! -e "$STATE_DIR/mlx/hf/hf-args" ]
  assert_eq "$(get_env LOCAL_MODELS)" ""
}
test_a_config_that_fails_the_check_after_the_download_is_deleted_and_never_registered() {
  _lm_env; _fake_apply; VET_REASON=''; VET_SHA="$SHA_A"; unset FAKE_DL_SHA; export FAKE_CFG='{"model_type":"llama","auto_map":{"AutoModel":"x.Y"}}'; _fake_mlx
  launchctl() { echo "$*" >> "$TMP/launchctl.log"; MLX_UP=1; return 0; }
  ! ( local_pull mlx-community/Tiny-4bit mlx --bytes 2000000 ) >/dev/null 2>&1
  assert_contains "$(cat "$(local_job_file)")" "Deleted, not registered"
  assert_contains "$(cat "$(local_job_file)")" "custom code (auto_map)"
  [ ! -d "$STATE_DIR/mlx/hf/hub/models--mlx-community--Tiny-4bit" ]
  assert_eq "$(get_env LOCAL_MODELS)" ""; assert_eq "$(local_registry_rows)" ""
  [ ! -e "$TMP/launchctl.log" ] || assert_not_contains "$(cat "$TMP/launchctl.log")" bootstrap   # (never served)
  export FAKE_CFG='{"model_file":"x.py"}'
  ! ( local_pull mlx-community/Tiny-4bit mlx --bytes 2000000 ) >/dev/null 2>&1
  assert_contains "$(cat "$(local_job_file)")" "model_file"
  assert_eq "$(local_registry_rows)" ""
  unset FAKE_CFG
}

# --- a key follows only the address it was saved for, by whatever path the address changed ---
test_a_key_is_bound_to_its_address_so_a_changed_address_from_any_path_sends_it_nowhere() {
  local u=http://10.0.0.5:8000 y
  _lm_env "MODEL_SERVERS=lab=$u
MODEL_SERVER_MODELS=lab:*
MODEL_SERVER_KEYS=lab=$(_msrv_hash $u 0):secretkey123456
"
  _fake_srv 0 200 "$VLLM"; msrv_probe_all
  assert_eq "$(msrv_key lab)" secretkey123456; assert_eq "$(msrv_key_state lab)" ok
  assert_contains "$(local_models_yaml 2>/dev/null)" 'api_key: "secretkey123456"'
  # ./stack config set MODEL_SERVERS (or the generic Settings row, or a hand edit): the address changes, the keys line does not
  sed -i.bak 's#10.0.0.5#10.0.0.99#' "$ENV_FILE"
  assert_eq "$(msrv_key lab)" ""; assert_eq "$(msrv_key_state lab)" moved
  assert_eq "$(msrv_key_note lab)" "key cleared: the address changed"
  : > "$TMP/curl.stdin"; : > "$TMP/curl.args"
  msrv_probe lab >/dev/null; msrv_probe_all
  assert_not_contains "$(cat "$TMP/curl.stdin" "$TMP/curl.args")" secretkey123456        # not in the probe's curl stdin or arguments
  assert_not_contains "$(cat "$TMP/curl.stdin")" Authorization
  y="$(local_models_yaml 2>"$TMP/yaml.err")"
  assert_not_contains "$y" secretkey123456; assert_contains "$y" 'api_base: "http://10.0.0.99:8000/v1"'; assert_contains "$y" 'api_key: "none"'
  assert_contains "$(cat "$TMP/yaml.err")" "key cleared: the address changed"            # setup/apply says it
  local_status_write
  assert_not_contains "$(cat "$(local_status_file)")" secretkey123456
  assert_contains "$(cat "$(local_status_file)")" '"key":false'; assert_contains "$(cat "$(local_status_file)")" '"key_note":"key cleared: the address changed"'
  # the form's probe under that name sends no key either
  : > "$TMP/curl.stdin"; _apply probe lab http://10.0.0.99:8000 false '' ''
  assert_not_contains "$(cat "$TMP/curl.stdin")" secretkey123456
  # turning trust on for the same address is a change too (an unverified certificate would hand the key to anyone on the path)
  sed -i.bak 's#10.0.0.99:8000#10.0.0.5:8000#' "$ENV_FILE"; assert_eq "$(msrv_key lab)" secretkey123456
  sed -i.bak 's#lab=http://10.0.0.5:8000#lab=http://10.0.0.5:8000;trust#' "$ENV_FILE"; assert_eq "$(msrv_key lab)" ""
  # another server's key does not apply, and a key that is not bound at all (saved before this existed) is not used
  _lm_env "MODEL_SERVERS=lab=$u,other=http://10.0.0.6:8000
MODEL_SERVER_MODELS=lab:*
MODEL_SERVER_KEYS=lab=legacykey123456,other=$(_msrv_hash $u 0):stolenkey1234
"
  assert_eq "$(msrv_key lab)" ""; assert_eq "$(msrv_key_state lab)" old; assert_contains "$(msrv_key_note lab)" "enter it again"
  assert_eq "$(msrv_key other)" ""                                                        # (a hash of lab's address does not unlock other's)
  msrv_probe_all; : > "$TMP/curl.stdin"; msrv_probe lab >/dev/null
  assert_not_contains "$(cat "$TMP/curl.stdin")" legacykey123456
  # both forms are valid values for the setting
  valid_msrv_keys "lab=legacykey123456,b=$(_msrv_hash $u 0):k1"
  ! valid_msrv_keys "lab=abc:def:ghi"
}

# --- https: the gateway resolves the name itself; the re-probe takes out a server whose name turns to a refused address ---
test_an_https_server_whose_name_now_resolves_to_a_metadata_address_is_unregistered_at_the_next_probe() {
  _lm_env 'MODEL_SERVERS=gpu=https://gpu.example.org:8443
MODEL_SERVER_MODELS=gpu:*
'
  _fake_srv 0 200 "$VLLM"; msrv_probe_all
  assert_contains "$(local_models_yaml)" 'api_base: "https://gpu.example.org:8443/v1"'    # (the gateway is given the name, for SNI and the certificate)
  : > "$TMP/applied.env"
  export MSRV_TEST_RESOLVE='gpu.example.org=169.254.169.254'                               # the name now answers the IMDS address
  msrv_probe_all
  assert_eq "$(local_models_yaml)" ""
  assert_contains "$(cat "$TMP/applied.env")" "MODEL_SERVER_MODELS"                        # the gateway was told, live
}

test_a_self_signed_certificate_trusted_on_a_public_address_is_warned_about_in_the_form_and_the_cli() {
  _lm_env ''; _fake_srv 0 200 "$VLLM"
  assert_contains "$(msrv_warn https://gpu.example.org 1 203.0.113.7)" "cannot be told apart from an impostor"
  assert_eq "$(msrv_warn https://gpu.example.org 1 192.168.1.9)" ""; assert_eq "$(msrv_warn https://gpu.example.org 1 100.101.2.3)" ""
  assert_eq "$(msrv_warn https://gpu.example.org 1 127.0.0.1)" ""; assert_eq "$(msrv_warn https://gpu.example.org 1 fd12::5)" ""
  assert_eq "$(msrv_warn https://gpu.example.org 0 203.0.113.7)" ""                         # (no trust: a CA-checked certificate)
  _apply probe '' https://gpu.example.org true '' ''
  assert_contains "$(_result)" "cannot be told apart from an impostor"; assert_contains "$(_result)" '"status":"ok"'   # (a warning, not a block)
  _apply probe '' https://box.lan true '' ''; assert_not_contains "$(_result)" impostor    # (box.lan is 192.168.1.9)
  local out; out="$(msrv_add pub https://gpu.example.org --trust 2>&1)"
  assert_contains "$out" "cannot be told apart from an impostor"
  assert_eq "$(get_env MODEL_SERVERS)" "pub=https://gpu.example.org;trust"                  # (saved all the same)
  local_status_write; assert_contains "$(cat "$(local_status_file)")" impostor
}

# --- the model-server rate limit counts what the helper starts ---
test_model_server_requests_are_counted_so_the_per_day_and_interval_caps_bite() {
  . "$STACK_DIR/lib/helper.sh"; . "$STACK_DIR/lib/settings_helper.sh"
  _lm_env; mkdir -p "$STATE_DIR/helper"
  STACK_DIR="$TMP/fakestack"; mkdir -p "$STACK_DIR"; printf '#!/bin/sh\nexit 0\n' > "$STACK_DIR/stack"; chmod +x "$STACK_DIR/stack"
  LOCAL_SERVER_MIN_INTERVAL_S=0; LOCAL_SERVER_MAX_PER_DAY=3
  local i f="probe||http://localhost:11434|false||0123456789abcdef"
  for i in 1 2 3; do
    _act_limits local-probe 2>/dev/null || { echo "refused too early at $i" >&2; return 1; }
    local_helper_start local-probe "$f" "$(printf 'ab%.0s' $(seq 16))"
  done
  assert_eq "$(wc -l < "$STATE_DIR/helper/server-jobs" | tr -d ' ')" 3                       # (counted, as local-jobs are)
  local why; why="$(_act_limits local-probe 2>&1)" && { echo "the cap did not bite" >&2; return 1; }
  assert_contains "$why" "limit of 3 a day is reached"
  why="$(_act_limits local-server 2>&1)" && { echo "the cap did not bite for local-server" >&2; return 1; }
  assert_contains "$why" "limit of 3 a day is reached"
  [ ! -e "$STATE_DIR/helper/local-jobs" ]                                                    # (downloads have their own count)
  # the interval too
  rm -f "$STATE_DIR/helper/server-jobs"; LOCAL_SERVER_MIN_INTERVAL_S=3600; LOCAL_SERVER_MAX_PER_DAY=600
  _act_limits local-server 2>/dev/null
  local_helper_start local-server "save|lab|http://10.0.0.5:8000|false||*|0123456789abcdef" "$(printf 'cd%.0s' $(seq 16))"
  why="$(_act_limits local-server 2>&1)" && { echo "the interval did not bite" >&2; return 1; }
  assert_contains "$why" "too soon after the last one"
}
