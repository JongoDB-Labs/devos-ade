# shellcheck shell=bash
# lib/litellm_live.sh (JON-533): LiteLLM's model list changed without a restart — the stable ids the renderer gives
# each model, the checksum Compose sees once a config was taken live, the wrapper (docker stubbed: nothing runs for
# real) and the script that runs in LiteLLM's container, against a stand-in of LiteLLM's model admin API on an
# ephemeral port of this test's own (python3 with PyYAML, as LiteLLM's image has; skipped without).
. "$STACK_DIR/lib/commands.sh"

test_every_model_gets_one_stable_id() {
  local out
  out="$(printf '%s\n' 'model_list:' '  - model_name: "claude-haiku-5-5"' '    litellm_params:' '      model: "x"' '    model_info:' '      mode: "chat"' \
    '  - model_name: "or/openai/gpt-4o:free"' '    litellm_params:' '      model: "y"' '    model_info:' '      mode: "chat"' \
    '  - model_name: "xl/qwen3.8-27b"' '    model_info:' '      mode: "chat"' '' 'search_tools:' '  - search_tool_name: "s"' '    litellm_params:' \
    '      search_provider: "searxng"' | litellm_model_ids)"
  assert_eq "$(printf '%s\n' "$out" | sed -n 's/^      id: //p' | tr '\n' ' ')" '"bn-claude-haiku-5-5" "bn-or_2Fopenai_2Fgpt-4o_3Afree" "bn-xl_2Fqwen3.8-27b" '
  # right under model_info:, before its other keys; nothing outside the model list
  assert_contains "$out" "$(printf '    model_info:\n      id: "bn-claude-haiku-5-5"\n      mode: "chat"')"
  assert_eq "$(printf '%s\n' "$out" | grep -c 'id: ')" 3
  # one id per name, never two: names that differ only in a character _XX could stand for
  assert_eq "$(printf '%s\n' '  - model_name: "a/b"' '    model_info:' '  - model_name: "a_2Fb"' '    model_info:' | litellm_model_ids | sed -n 's/^      id: //p' | tr '\n' ' ')" \
    '"bn-a_2Fb" "bn-a_5F2Fb" '
}

test_the_rendered_config_has_the_ids() {
  local en="$TMP/enabled" cfg="$TMP/config.yaml"
  printf 'claude-haiku-5-5\ntitan-embed-v2\n' > "$en"
  : > "$ENV_FILE"; set_env AWS_REGION_NAME us-east-1
  render_litellm_config "$en" us-east-1 false > "$cfg"
  assert_eq "$(grep -c '^  - model_name: ' "$cfg")" "$(grep -c '^      id: "bn-' "$cfg")"
  assert_contains "$(cat "$cfg")" "$(printf '  - model_name: "claude-haiku-5-5"')"
  assert_contains "$(cat "$cfg")" 'id: "bn-claude-haiku-5-5"'
}

test_compose_sees_the_checksum_of_the_container_that_took_a_config_live() {
  STACK_DIR="$TMP/co"; mkdir -p "$STACK_DIR/litellm" "$STATE_DIR"
  printf 'a\n' > "$STACK_DIR/litellm/config.yaml"
  local a b
  a="$(litellm_config_sum_now)"
  assert_eq "$(litellm_compose_sum)" "$a"
  printf 'b\n' > "$STACK_DIR/litellm/config.yaml"; b="$(litellm_config_sum_now)"
  printf '%s %s\n' "$b" "$a" > "$(litellm_live_sum_file)"     # b given live to the container started with a
  assert_eq "$(litellm_compose_sum)" "$a"                         # Compose: nothing to recreate
  assert_contains "$(config_sums '')" "BN_LITELLM_CONFIG_SUM=$a"
  printf 'c\n' > "$STACK_DIR/litellm/config.yaml"                # rendered, not given live: its own checksum
  assert_eq "$(litellm_compose_sum)" "$(litellm_config_sum_now)"
}

# the wrapper: docker stubbed — LiteLLM's and Postgres's containers, the env the first was started with, the exec
_stub_docker() {   # _stub_docker PY_RC PY_OUT BASE
  STUB_RC="$1"; STUB_OUT="$2"; STUB_BASE="$3"
  docker() {
    echo "docker $*" >> "$TMP/calls"
    case "$1 $*" in
      "ps "*service=litellm*) echo cid-litellm ;;
      "ps "*service=postgres*) echo cid-pg ;;
      "inspect "*) printf 'PATH=/x\nBN_CONFIG_SUM=%s\nLITELLM_MASTER_KEY=sk-never-printed\n' "$STUB_BASE" ;;
      "exec "*cid-pg*) return 0 ;;
      "exec "*cid-litellm*) cat > "$TMP/stdin"; printf '%s\n' "$STUB_OUT"; return "$STUB_RC" ;;
    esac
  }
}

test_the_wrapper_takes_only_the_config_litellm_serves() {
  STACK_DIR="$TMP/co"; mkdir -p "$STACK_DIR/litellm" "$STATE_DIR"; : > "$ENV_FILE"
  printf 'old\n' > "$TMP/old"; printf 'new\n' > "$STACK_DIR/litellm/config.yaml"
  _stub_docker 0 '{"result": "ok", "said": "1 added, 0 changed, 0 removed"}' base-1
  # it serves another config than the one this change started from: not live (the caller restarts it)
  if litellm_live_sync other-sum "$TMP/old"; then return 1; else assert_eq "$?" 3; fi
  assert_contains "$LITELLM_LIVE_ERR" "does not run the config this change started from"
  assert_not_contains "$(cat "$TMP/calls")" "exec"
  # it does: the script gets the old config on stdin, the rows go before and after, the new checksum is noted
  : > "$TMP/calls"
  litellm_live_sync base-1 "$TMP/old"
  assert_eq "$LITELLM_LIVE_SAID" "1 added, 0 changed, 0 removed"
  assert_eq "$(cat "$TMP/stdin")" old
  assert_eq "$(grep -c 'exec cid-pg psql' "$TMP/calls")" 2
  assert_contains "$(cat "$TMP/calls")" "DELETE FROM \"LiteLLM_ProxyModelTable\" WHERE model_id LIKE 'bn-%'"
  assert_eq "$(cat "$(litellm_live_sum_file)")" "$(litellm_config_sum_now) base-1"
  # the next change starts from that one: it is what LiteLLM serves now
  assert_eq "$(litellm_serving_sum cid-litellm)" "$(litellm_config_sum_now)"
  assert_not_contains "$(cat "$TMP/calls")" "sk-never-printed"
}

test_the_wrapper_says_why_it_is_not_live_or_failed() {
  STACK_DIR="$TMP/co"; mkdir -p "$STACK_DIR/litellm" "$STATE_DIR"; : > "$ENV_FILE"
  printf 'old\n' > "$TMP/old"; printf 'new\n' > "$STACK_DIR/litellm/config.yaml"
  _stub_docker 3 '{"result": "restart", "why": "settings besides the model list changed"}' base-1
  if litellm_live_sync base-1 "$TMP/old"; then return 1; else assert_eq "$?" 3; fi
  assert_eq "$LITELLM_LIVE_ERR" "settings besides the model list changed"
  [ ! -e "$(litellm_live_sum_file)" ]
  _stub_docker 1 '{"result": "failed", "why": "LiteLLM refused xl/x (HTTP 400): bad"}' base-1
  if litellm_live_sync base-1 "$TMP/old"; then return 1; else assert_eq "$?" 1; fi
  assert_eq "$LITELLM_LIVE_ERR" "LiteLLM refused xl/x (HTTP 400): bad"
  [ ! -e "$(litellm_live_sum_file)" ]
  assert_eq "$(grep -c 'exec cid-pg psql' "$TMP/calls")" 4   # (its rows cleared even so)
  docker() { :; }                                                # no LiteLLM running
  if litellm_live_sync base-1 "$TMP/old"; then return 1; else assert_eq "$?" 3; fi
}

# --- the script in LiteLLM's container, against a stand-in of its model admin API ---
# The stand-in keeps a router: the old config's deployments by id; POST /model/new upserts one and then reconciles as
# LiteLLM does (every deployment config.yaml no longer lists goes); POST /config/update reconciles only; GET
# /model/info lists the router. Every request is logged (path, body) for the checks.
STANDIN_PY='
import json, os, sys, threading, yaml
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
old = yaml.safe_load(open(sys.argv[1])) or {}
cfg, log, portf = sys.argv[2], sys.argv[3], sys.argv[4]
router = {str(m["model_info"].get("id", m["model_name"])): m for m in old.get("model_list") or []}
fail = os.environ.get("STANDIN_FAIL", "")
def reconcile():
    want = {str(m["model_info"].get("id", m["model_name"])) for m in (yaml.safe_load(open(cfg)) or {}).get("model_list") or []}
    for i in [i for i in router if i not in want]:
        del router[i]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, st, d):
        b = json.dumps(d).encode(); self.send_response(st); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        with open(log, "a") as f: f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization")}) + "\n")
        data = [{"model_name": m["model_name"], "litellm_params": m.get("litellm_params") or {}, "model_info": m.get("model_info") or {}} for m in router.values()]
        if fail == "info":
            data = data[1:]
        self._send(200, {"data": data})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"null")
        with open(log, "a") as f: f.write(json.dumps({"path": self.path, "body": body, "auth": self.headers.get("Authorization")}) + "\n")
        if self.path == "/model/new":
            if fail == "new":
                return self._send(400, {"error": "nope"})
            router[str(body["model_info"]["id"])] = body
            reconcile()
            return self._send(200, {"model_id": body["model_info"]["id"]})
        if self.path == "/config/update":
            reconcile()
            return self._send(200, {"message": "ok"})
        self._send(404, {})
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(portf, "w").write(str(s.server_address[1]))
s.serve_forever()
'

_needs_yaml() { python3 -I -c 'import yaml' 2>/dev/null || { echo "python3 has no PyYAML here (LiteLLM's image has it)" >&2; return 77; }; }

# _sync_py OLD NEW [MAX] — the script with OLD on stdin and NEW as config.yaml, the stand-in started from OLD;
# -> PY_RC, PY_OUT, the stand-in's log in $TMP/standin.log
_sync_py() {
  local p n=0
  : > "$TMP/standin.log"; rm -f "$TMP/port"
  python3 -I -c "$STANDIN_PY" "$1" "$2" "$TMP/standin.log" "$TMP/port" & local pid=$!
  while [ ! -s "$TMP/port" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  p="$(cat "$TMP/port")"
  PY_RC=0
  PY_OUT="$(LITELLM_LIVE_URL="http://127.0.0.1:$p" LITELLM_LIVE_CONFIG="$2" LITELLM_MASTER_KEY=sk-master-test \
    python3 -I -c "$LITELLM_LIVE_PY" "${3:-40}" < "$1" 2>&1)" || PY_RC=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
}

_cfg2() {   # _cfg2 FILE MODEL… — a config with these models (NAME or NAME=MODEL[@PRICE]); the rest fixed
  local f="$1" m; shift
  { printf 'model_list:\n'
    for m in "$@"; do
      printf '  - model_name: "%s"\n    litellm_params:\n      model: "%s"\n      api_key: os.environ/EXPLABS_API_KEY\n      drop_params: true\n' "${m%%=*}" "$(m="${m#*=}"; printf '%s' "${m%%@*}")"
      printf '    model_info:\n      id: "bn-%s"\n      mode: "chat"\n' "$(printf '%s' "${m%%=*}" | tr '/' '_')"
      case "$m" in *@*) printf '      input_cost_per_token: %s\n' "${m##*@}" ;; esac
      printf '      bn_xl: true\n'
    done
    printf '\nrouter_settings:\n  model_group_alias: {}\n\ngeneral_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY\n'; } > "$f"
}

test_the_script_adds_changes_and_removes_models_as_config_yaml_says() {
  _needs_yaml || return 77
  _cfg2 "$TMP/old.yaml" "xl/a=openai/a@0.000001" "xl/b=openai/b"
  _cfg2 "$TMP/new.yaml" "xl/a=openai/a@0.000002" "xl/c=openai/c"
  _sync_py "$TMP/old.yaml" "$TMP/new.yaml"
  assert_eq "$PY_RC" 0
  assert_eq "$PY_OUT" '{"result": "ok", "said": "1 added, 1 changed, 1 removed"}'
  # /model/new for the changed and the added one, each exactly as config.yaml has it — its prices on litellm_params too
  assert_eq "$(grep -c '"/model/new"' "$TMP/standin.log")" 2
  python3 -I - "$TMP/standin.log" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
new = {r["body"]["model_name"]: r["body"] for r in rows if r["path"] == "/model/new"}
a = new["xl/a"]
assert a["litellm_params"] == {"model": "openai/a", "api_key": "os.environ/EXPLABS_API_KEY", "drop_params": True, "input_cost_per_token": 2e-06}, a
assert a["model_info"] == {"id": "bn-xl_a", "mode": "chat", "input_cost_per_token": 2e-06, "bn_xl": True}, a
assert new["xl/c"]["model_info"]["id"] == "bn-xl_c"
assert all(r["auth"] == "Bearer sk-master-test" for r in rows)
assert not any(r["path"] == "/config/update" for r in rows)   # (a /model/new reconciles: xl/b went with it)
PY
}

test_the_script_asks_for_a_reconcile_when_models_only_go() {
  _needs_yaml || return 77
  _cfg2 "$TMP/old.yaml" "xl/a=openai/a" "xl/b=openai/b"
  _cfg2 "$TMP/new.yaml" "xl/a=openai/a"
  _sync_py "$TMP/old.yaml" "$TMP/new.yaml"
  assert_eq "$PY_RC" 0
  assert_eq "$PY_OUT" '{"result": "ok", "said": "0 added, 0 changed, 1 removed"}'
  assert_eq "$(grep -o '"path": "[^"]*"' "$TMP/standin.log" | tr '\n' ' ')" '"path": "/config/update" "path": "/model/info" '
}

test_the_script_leaves_anything_else_to_a_restart() {
  _needs_yaml || return 77
  _cfg2 "$TMP/old.yaml" "xl/a=openai/a"
  _cfg2 "$TMP/new.yaml" "xl/a=openai/a" "xl/b=openai/b"
  printf 'litellm_settings:\n  drop_params: true\n' >> "$TMP/new.yaml"
  _sync_py "$TMP/old.yaml" "$TMP/new.yaml"
  assert_eq "$PY_RC" 3
  assert_contains "$PY_OUT" '"why": "settings besides the model list changed"'
  [ ! -s "$TMP/standin.log" ]
  # a config rendered before the ids: restart (nothing to replace by id)
  _cfg2 "$TMP/new.yaml" "xl/a=openai/a" "xl/b=openai/b"
  sed '/id: "bn-xl_a"/d' "$TMP/old.yaml" > "$TMP/old2.yaml"
  _sync_py "$TMP/old2.yaml" "$TMP/new.yaml"
  assert_eq "$PY_RC" 3
  assert_contains "$PY_OUT" "has no stable id"
  # more models at once than LITELLM_LIVE_MAX
  _sync_py "$TMP/old.yaml" "$TMP/new.yaml" 0
  assert_eq "$PY_RC" 3
  assert_contains "$PY_OUT" "more than 0 at once"
  # nothing changed in the model list: nothing to do
  _sync_py "$TMP/old.yaml" "$TMP/old.yaml"
  assert_eq "$PY_RC" 0
  assert_contains "$PY_OUT" "no model changed"
  [ ! -s "$TMP/standin.log" ]
}

test_the_script_fails_when_litellm_refuses_or_serves_something_else() {
  _needs_yaml || return 77
  _cfg2 "$TMP/old.yaml" "xl/a=openai/a"
  _cfg2 "$TMP/new.yaml" "xl/a=openai/a" "xl/b=openai/b"
  STANDIN_FAIL=new _sync_py "$TMP/old.yaml" "$TMP/new.yaml"
  assert_eq "$PY_RC" 1
  assert_contains "$PY_OUT" '"why": "LiteLLM refused xl/b (HTTP 400)'
  STANDIN_FAIL=info _sync_py "$TMP/old.yaml" "$TMP/new.yaml"
  assert_eq "$PY_RC" 1
  assert_contains "$PY_OUT" "LiteLLM serves other models than config.yaml: missing bn-xl_a"
}
