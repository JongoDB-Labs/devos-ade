#!/usr/bin/env bash
# Opt-in harness parity suite (run by hand; not part of tests/run.sh, CI or tests/e2e/run.sh): REAL Claude Code sessions
# (devos-claude -p … --output-format stream-json, as the Code page and the terminal run them) on each provider
# family's models, in a throwaway pair of this checkout's LiteLLM and sandbox: does a model of another vendor work as
# Claude Code's model with no difference but what the model was trained on? Each scenario (tests/e2e/harness-parity.py)
# records PASS or FAIL with the exact error, per model.
#
#   tests/e2e/harness-parity.sh --aws-env FILE   AWS_* keys from FILE (only those lines are read; values never printed)
#   tests/e2e/harness-parity.sh                  AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION_NAME from the
#                                                environment
# Options:
#   --families LIST   control,bedrock,openrouter,explabs (default: all four)
#   --models LIST     these models instead of the families' own (ids as Claude Code's picker lists them)
#   --scenarios LIST  only these scenarios (tests/e2e/harness-parity.py --list names them); an entry MODEL:SCENARIO
#                     gives that model its own list (e.g. mistral-large-3:image-read,mistral-large-3:websearch)
#   --out DIR         results (default tests/e2e/out): harness-parity.tsv (one line per scenario and model),
#                     harness-parity.json, harness-parity-logs/ (each session's stream-json)
#   --keep / --reuse / --teardown   leave the throwaway running, run against a kept one, only remove it
#   E2E_PARITY_JOBS=N  models run side by side, N at a time (default 3; each model's scenarios one after another)
#   E2E_PARITY_MINUTES=M  no scenario starts after M minutes (SKIP; for a run that must end in time: a shared lock)
#   E2E_WEBSEARCH=B   the search backend Claude Code's WebSearch gets (lib/websearch.sh): stand-in (the default: the
#                     stand-in's SearXNG-shaped /search with fixed results), off (none: WebSearch must say so), agentcore
#                     (Amazon Bedrock AgentCore Web Search: E2E_AGENTCORE_GATEWAY, its MCP URL, and E2E_AGENTCORE_TOOL
#                     when its target is not named web-search-tool; one real search per WebSearch call, on this AWS key)
#                     or searxng (a real SearXNG at E2E_SEARXNG_URL, reachable from the LiteLLM container), or builtin
#                     (the built-in SearXNG, as compose.yaml runs it: its pinned image and this checkout's settings.yml,
#                     with a secret of the run's own, on an internal network with LiteLLM alone and one of its own to the
#                     internet — real results from the search engines it asks, free)
#
# The families and their models:
#   control     claude-haiku-5-5 (Anthropic's on Bedrock: what Claude Code expects)
#   bedrock     gpt-6-luna, mistral-large-3, llama-3-3-70b (another vendor's model through Bedrock's Converse)
#   openrouter  with E2E_OPENROUTER_API_KEY: OpenRouter's free models (E2E_OPENROUTER_MODELS, default
#               openai/gpt-oss-120b:free,qwen/qwen3-coder:free; their list read keyless from openrouter.ai). Without it:
#               a stand-in for OpenRouter (tests/e2e/explabs-mock.py, MOCK_FLAVOR=openrouter) answered by gpt-6-luna on
#               Bedrock, so LiteLLM's OpenRouter translation is what is tested, not OpenRouter's models.
#   explabs     the stand-in for the Experiential Labs gateway (tests/e2e/explabs-mock.py: the gateway's refusals,
#               answered by gpt-6-luna on Bedrock) on xl/qwen3.8-27b and xl/deepseek-v4.1-flash. With
#               E2E_EXPLABS_API_KEY and --explabs-real: the real gateway (E2E_EXPLABS_MODELS, default qwen3.8-27b),
#               credits spent on every turn. Never run by default.
#
# What runs (docker; on a machine with a shared heavy-job lock, run the whole script inside it): three containers named
# bne2e-parity-litellm, -gateway and -sandbox (label io.bedrock-now.e2e=parity), networks bne2e-parity-term, -link
# (both internal) and -out — with E2E_WEBSEARCH=builtin also bne2e-parity-searxng and its networks -ws (internal) and
# -wsout —, all removed afterwards by those names; nothing is pruned. LiteLLM runs this checkout's
# rendered config (lib/models.sh with its OpenRouter and Experiential Labs entries and the bn_* model info), its hook
# (lib/litellm-hooks/bn_hooks.py) and the code-models.tsv the hook reads — no Postgres: the master key stands in for the
# terminal's key. The gateway is this checkout's caddy/terminal-gateway.caddy (the only paths Claude Code may reach).
# The sandbox is the terminal image (built from terminal/, or E2E_PARITY_TERMINAL_IMAGE) with compose.terminal.yaml's
# environment and this checkout's terminal/bin/devos-claude, read-only, its home and /workspace in memory; its way
# out (WebFetch) is a plain bridge network, as TERMINAL_EGRESS=host. Claude Code's tools may touch only
# /workspace/<family>-<n>/<scenario> (--permission-mode acceptEdits with an allow list).
# Bedrock spend: a few cents per model (cheap models, short prompts); every call LiteLLM books is logged and summed in
# the results. Keys: only in this process's environment and the LiteLLM container's (-e NAME, never a value on a
# command line); never in a file, the results or the logs (checked at the end).
set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NAME=bne2e-parity
OUT="$ROOT/tests/e2e/out"; AWS_ENV_FILE=''; FAMILIES="control,bedrock,openrouter,explabs"; MODELS=''; SCENARIOS=''
KEEP=0; REUSE=0; TEARDOWN_ONLY=0; XL_REAL=0
AVOID_PORTS=" 80 443 3000 3009 4000 8080 8081 8090 8765 8787 8788 8800 "
XL_PORT=18471; OR_PORT=18472
while [ $# -gt 0 ]; do
  case "$1" in
    --aws-env) AWS_ENV_FILE="${2:?--aws-env FILE}"; shift 2 ;;
    --out) OUT="${2:?--out DIR}"; shift 2 ;;
    --families) FAMILIES="${2:?--families LIST}"; shift 2 ;;
    --models) MODELS="${2:?--models LIST}"; shift 2 ;;
    --scenarios) SCENARIOS="${2:?--scenarios LIST}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --reuse) REUSE=1; KEEP=1; shift ;;
    --teardown) TEARDOWN_ONLY=1; shift ;;
    --explabs-real) XL_REAL=1; shift ;;
    -h | --help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (tests/e2e/harness-parity.sh --help)" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/ports.sh
. "$ROOT/lib/ports.sh"   # port_in_use, the check ./stack uses
say() { printf '==> %s\n' "$*" >&2; }
die() { printf 'xx  %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || die "needs docker"
command -v python3 >/dev/null 2>&1 || die "needs python3"
WORK="$ROOT/tests/e2e/work/$NAME"
NETS="$NAME-term $NAME-link $NAME-out $NAME-ws $NAME-wsout"
CONTAINERS="$NAME-sandbox $NAME-gateway $NAME-litellm $NAME-searxng"

# _ours KIND NAME -> 0 when the container or network NAME exists and carries this suite's label
_ours() {
  local labels=.Labels; [ "$1" = network ] || labels=.Config.Labels
  [ "$(docker "$1" inspect -f "{{index $labels \"io.bedrock-now.e2e\"}}" "$2" 2>/dev/null)" = parity ]
}
_exists() { docker "$1" inspect "$2" >/dev/null 2>&1; }
teardown() {
  local c n
  for c in $CONTAINERS; do
    if _exists container "$c"; then
      if _ours container "$c"; then docker rm -f "$c" >/dev/null 2>&1; else say "$c is not this suite's: left alone"; fi
    fi
  done
  for n in $NETS; do
    if _exists network "$n"; then
      if _ours network "$n"; then docker network rm "$n" >/dev/null 2>&1; else say "network $n is not this suite's: left alone"; fi
    fi
  done
}
if [ "$TEARDOWN_ONLY" = 1 ]; then teardown; rm -rf "$WORK"; say "removed"; exit 0; fi

# --- keys: AWS from --aws-env (AWS_* lines only) or the environment; OpenRouter's and Experiential Labs' only when given
if [ -n "$AWS_ENV_FILE" ]; then
  [ -r "$AWS_ENV_FILE" ] || die "cannot read $AWS_ENV_FILE"
  while IFS= read -r line; do
    case "$line" in
      AWS_ACCESS_KEY_ID=* | AWS_SECRET_ACCESS_KEY=* | AWS_SESSION_TOKEN=* | AWS_REGION_NAME=*)
        k="${line%%=*}"; v="${line#*=}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"; export "$k=$v" ;;
    esac
  done < <(tr -d '\r' < "$AWS_ENV_FILE")
fi
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || die "no AWS key (--aws-env FILE, or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)"
export AWS_REGION_NAME="${AWS_REGION_NAME:-us-east-1}"
OR_REAL=0; [ -z "${E2E_OPENROUTER_API_KEY:-}" ] || OR_REAL=1
WS="${E2E_WEBSEARCH:-stand-in}"
case "$WS" in
  stand-in | off | builtin) ;;
  agentcore) [ -n "${E2E_AGENTCORE_GATEWAY:-}" ] || die "E2E_WEBSEARCH=agentcore needs E2E_AGENTCORE_GATEWAY (the gateway's MCP URL)" ;;
  searxng) [ -n "${E2E_SEARXNG_URL:-}" ] || die "E2E_WEBSEARCH=searxng needs E2E_SEARXNG_URL" ;;
  *) die "E2E_WEBSEARCH must be stand-in, off, builtin, agentcore or searxng" ;;
esac
if [ "$XL_REAL" = 1 ] && [ -z "${E2E_EXPLABS_API_KEY:-}" ]; then die "--explabs-real needs E2E_EXPLABS_API_KEY"; fi
OPENROUTER_API_KEY="${E2E_OPENROUTER_API_KEY:-stand-in-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')}"
EXPLABS_API_KEY="stand-in-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
[ "$XL_REAL" = 0 ] || EXPLABS_API_KEY="$E2E_EXPLABS_API_KEY"
unset E2E_OPENROUTER_API_KEY E2E_EXPLABS_API_KEY
export OPENROUTER_API_KEY EXPLABS_API_KEY
for k in "$OPENROUTER_API_KEY" "$EXPLABS_API_KEY"; do case "$k" in *[!A-Za-z0-9_-]*) die "a key holds characters no key has" ;; esac; done

# --- the models of each family
OR_MODELS="${E2E_OPENROUTER_MODELS:-openai/gpt-oss-120b:free,qwen/qwen3-coder:free}"
[ "$OR_REAL" = 1 ] || OR_MODELS="openai/gpt-oss-120b:free"
XL_MODELS="qwen3.8-27b,deepseek-v4.1-flash"; [ "$XL_REAL" = 0 ] || XL_MODELS="${E2E_EXPLABS_MODELS:-qwen3.8-27b}"
RELAY_MODEL=gpt-6-luna   # the stand-ins' real model
if [ -z "$MODELS" ]; then
  for f in $(printf '%s' "$FAMILIES" | tr ',' ' '); do
    case "$f" in
      control) MODELS="$MODELS,claude-haiku-5-5" ;;
      bedrock) MODELS="$MODELS,gpt-6-luna,mistral-large-3,llama-3-3-70b" ;;
      openrouter) MODELS="$MODELS,$(printf '%s' "$OR_MODELS" | tr ',' '\n' | sed 's#^#or/#' | paste -sd, -)" ;;
      explabs) MODELS="$MODELS,$(printf '%s' "$XL_MODELS" | tr ',' '\n' | sed 's#^#xl/#' | paste -sd, -)" ;;
      *) die "unknown family: $f (control, bedrock, openrouter, explabs)" ;;
    esac
  done
  MODELS="${MODELS#,}"
fi
mkdir -p "$OUT" || die "cannot make $OUT"
MASTER_FILE="$WORK/.master"

if [ "$REUSE" = 0 ]; then
  teardown
  for c in $CONTAINERS; do ! _exists container "$c" || die "$c exists and is not this suite's"; done
  # from here on, whatever ends the run (a failed start, Ctrl-C) removes what it started, unless --keep
  trap '[ "$KEEP" = 1 ] || { teardown; rm -rf "$WORK"; }' EXIT
  trap 'exit 130' INT TERM
  rm -rf "$WORK"; mkdir -p "$WORK/litellm" "$WORK/state" "$WORK/mock/catalog" || die "cannot make $WORK"
  ( umask 077; printf 'sk-parity-%s\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" > "$MASTER_FILE" )

  # --- this checkout's config, rendered as ./stack renders it (the keys never in it: get_env answers from memory)
  say "rendering this checkout's LiteLLM config ($MODELS)"
  (
    STACK_DIR="$ROOT"; ENV_FILE=/dev/null; STATE_DIR="$WORK/state"; export STACK_DIR ENV_FILE STATE_DIR
    # shellcheck source=/dev/null
    . "$ROOT/lib/common.sh"; . "$ROOT/lib/ports.sh"; . "$ROOT/lib/portal.sh"; . "$ROOT/lib/models.sh"; . "$ROOT/lib/commands.sh"
    [ "$XL_REAL" = 1 ] || { EXPLABS_API="http://127.0.0.1:$XL_PORT/v1"; BEDROCK_NOW_TESTING=1; }
    get_env() {
      case "$1" in
        AWS_REGION_NAME) printf '%s' "$AWS_REGION_NAME" ;;
        OPENROUTER_API_KEY) case ",$FAMILIES,$MODELS," in *,openrouter,* | *,or/*) printf '%s' "$OPENROUTER_API_KEY" ;; esac ;;
        OPENROUTER_MODELS) printf '%s' "$OR_MODELS" ;;
        EXPLABS_API_KEY) case ",$FAMILIES,$MODELS," in *,explabs,* | *,xl/*) printf '%s' "$EXPLABS_API_KEY" ;; esac ;;
        EXPLABS_MODELS) printf '%s' "$XL_MODELS" ;;
        CLAUDE_BEDROCK_OPUS_MODEL | CLAUDE_BEDROCK_SONNET_MODEL | CLAUDE_BEDROCK_HAIKU_MODEL) printf 'claude-haiku-5-5' ;;
        CODE_MODELS) printf 'all' ;;
        # Claude Code's WebSearch (lib/websearch.sh): the stand-in's /search (SearXNG's shape), none, or a real one
        WEBSEARCH_BACKEND) case "$WS" in stand-in) printf searxng ;; *) printf '%s' "$WS" ;; esac ;;
        WEBSEARCH_SEARXNG_URL) case "$WS" in stand-in) printf 'http://127.0.0.1:%s' "$OR_PORT" ;; searxng) printf '%s' "$E2E_SEARXNG_URL" ;; esac ;;
        WEBSEARCH_AGENTCORE_GATEWAY) [ "$WS" != agentcore ] || printf '%s' "$E2E_AGENTCORE_GATEWAY" ;;
        # (the built-in SearXNG: on only for builtin, so auto never falls back to it in the other modes)
        WEBSEARCH_SEARXNG_BUILTIN) [ "$WS" = builtin ] && printf on || printf off ;;
      esac
    }
    CODE_COMPAT="$ROOT/catalog/code-models.tsv"; CODE_DISPLAY_TSV="$ROOT/catalog/display.tsv"
    STACK_DIR="$WORK"
    bn_hook_src() { printf '%s\n' "$ROOT/lib/litellm-hooks/bn_hooks.py"; }
    xl_cache_current() { [ -s "$(xl_cache_tsv)" ]; }   # (no key mark on disk)
    # the enabled Bedrock models: the control, the bedrock family's and the stand-ins' real model
    printf '%s\n' claude-haiku-5-5 gpt-6-luna mistral-large-3 llama-3-3-70b > "$WORK/litellm/enabled-models.txt"
    # OpenRouter's list: read keyless from openrouter.ai with a key (its models are then real), else one stand-in row
    if [ "$OR_REAL" = 1 ]; then
      curl -fsS -m 60 https://openrouter.ai/api/v1/models | or_models_tsv | or_classify > "$WORK/or.rows" || exit 1
      { printf '# fetched_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$WORK/or.rows"; } > "$(or_cache_tsv)"
    else
      printf '# fetched_at: %s\nopenai/gpt-oss-120b:free\tOpenAI: gpt-oss-120b (free)\t131072\t0\t0\t\t\tfree\t1754000000\t1\t32768\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$(or_cache_tsv)"
    fi
    # Experiential Labs' list: the stand-in's (the gateway's model ids and its catalog answers, tests/fixtures), or the
    # real gateway's, read with the key
    if [ "$XL_REAL" = 1 ]; then
      xl_fetch_models "$(xl_cache_tsv)" "$EXPLABS_API_KEY" || { echo "the gateway's list: $XL_ERR" >&2; exit 1; }
    else
      xl_ids < "$ROOT/tests/fixtures/explabs_v1_models.json" > "$WORK/xl.ids"
      for id in $(xl_wanted); do xl_model_tsv "$id" < "$ROOT/tests/fixtures/explabs_catalog/$id.json"; done > "$WORK/xl.det"
      { printf '# fetched_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; xl_join "$WORK/xl.ids" < "$WORK/xl.det"; } > "$(xl_cache_tsv)"
    fi
    # (AgentCore's target, when not LiteLLM's default name: as the check would have listed it)
    if [ "$WS" = agentcore ] && [ -n "${E2E_AGENTCORE_TOOL:-}" ]; then
      mkdir -p "$(websearch_state_dir)"
      printf 'status=ready\nurl=%s\ntool=%s\nat=%s\nfingerprint=%s\n' "$E2E_AGENTCORE_GATEWAY" "$E2E_AGENTCORE_TOOL" "$(date +%s)" "$(_ws_agentcore_fp)" > "$(_ws_state_file agentcore)"
    fi
    render_litellm_config "$WORK/litellm/enabled-models.txt" "$AWS_REGION_NAME" false false false > "$WORK/litellm/config.yaml.new" || exit 1
    code_models_write "$WORK/litellm/enabled-models.txt" "$WORK/litellm/code-models.tsv"
    websearch_write_json "$WORK/litellm/web-search.json"
    [ "$WS" != builtin ] || websearch_searxng_write "$WORK/searxng"
  ) || die "could not render the config"
  cp "$ROOT/lib/litellm-hooks/bn_hooks.py" "$WORK/litellm/bn_hooks.py"
  # The suite's own callback (never in a real config): each call's model, cost and error, for the spend and the errors
  cat > "$WORK/litellm/parity_spend.py" <<'PY'
import json, time
from litellm.integrations.custom_logger import CustomLogger


def _images(messages):
    n = 0
    for m in messages if isinstance(messages, list) else []:
        c = m.get("content") if isinstance(m, dict) else None
        n += sum(1 for p in c if isinstance(p, dict) and p.get("type") in ("image_url", "image")) if isinstance(c, list) else 0
    return n


def _origin(d):
    """Where a request came from: the proxy's route and the client's user-agent (never a header's other values)."""
    psr = d.get("proxy_server_request") if isinstance(d, dict) else None
    if not isinstance(psr, dict):
        return {}
    h = psr.get("headers") if isinstance(psr.get("headers"), dict) else {}
    return {"route": str(psr.get("url") or "")[-80:], "ua": str(h.get("user-agent") or "")[:60]}


def _row(kwargs, ok, err=None):
    lp = kwargs.get("litellm_params") or {}
    meta = lp.get("metadata") or {}
    return {"t": time.time(), "ok": ok, "call_id": kwargs.get("litellm_call_id"), "model": kwargs.get("model"),
            "group": meta.get("model_group"), "cost": kwargs.get("response_cost") or 0, "error": err,
            **_origin(lp) , **_origin(kwargs)}


class Spend(CustomLogger):
    def _write(self, row):
        try:
            with open("/tmp/parity-spend.jsonl", "a", encoding="utf-8") as f:
                f.write(json.dumps(row, default=str) + "\n")
        except Exception:  # noqa: BLE001
            pass

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # each request as Claude Code sent it (before any translation): the shape of its messages — roles and block
        # types, never their text — its system prompt's first words, max_tokens and tools, to tell its calls apart
        try:
            msgs = data.get("messages") if isinstance(data, dict) else None
            system = data.get("system")
            head = system if isinstance(system, str) else " ".join(b.get("text", "") for b in system if isinstance(b, dict)) if isinstance(system, list) else ""
            shape = []
            for m in msgs if isinstance(msgs, list) else []:
                c = m.get("content") if isinstance(m, dict) else None
                kinds = c if isinstance(c, str) and not c else ("text" if isinstance(c, str) else [b.get("type") for b in c if isinstance(b, dict)] if isinstance(c, list) else None)
                shape.append([m.get("role") if isinstance(m, dict) else None, kinds])
            self._write({"t": time.time(), "ok": True, "kind": "raw", "group": data.get("model") if isinstance(data, dict) else None,
                         **_origin(data),
                         "call_type": str(getattr(call_type, "value", call_type)), "system_head": head[:120],
                         "max_tokens": data.get("max_tokens") if isinstance(data, dict) else None,
                         "tools": len(data.get("tools") or []) if isinstance(data, dict) else None, "shape": shape[-12:]})
        except Exception:  # noqa: BLE001
            pass
        return data

    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        # each call as it goes to its deployment (the logs after it have no messages: turn_off_message_logging): the
        # images it carries and its messages' roles
        try:
            meta = kwargs.get("litellm_metadata") or kwargs.get("metadata") or {}
            msgs = kwargs.get("messages")
            self._write({"t": time.time(), "ok": True, "kind": "pre", "call_id": kwargs.get("litellm_call_id"),
                         "model": kwargs.get("model"), "group": meta.get("model_group"), "images": _images(msgs),
                         "roles": [m.get("role") for m in msgs if isinstance(m, dict)][-40:] if isinstance(msgs, list) else None})
        except Exception:  # noqa: BLE001
            pass
        return kwargs

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        self._write(_row(kwargs, True))

    async def async_log_failure_event(self, kwargs, response_obj, start_time, end_time):
        e = kwargs.get("exception")
        self._write(_row(kwargs, False, f"{type(e).__name__}: {e}"[:4000] if e is not None else None))


handler = Spend()
PY
  # no Postgres here: no database_url; the suite's callback beside the hook; and a deployment of the suite's own whose
  # model id Bedrock does not know (the error scenario: Bedrock's own words), named for devos-claude like the others
  sed -e '/^  database_url: /d' \
      -e 's/^model_list:$/model_list:\
  - model_name: "parity-bad-bedrock"\
    litellm_params:\
      model: "bedrock\/converse\/us.parity.no-such-model-v1:0"\
      aws_region_name: os.environ\/AWS_REGION_NAME\
    model_info:\
      mode: "chat"\
      bn_id: "parity-bad-bedrock"\
      bn_compat: "fails"\
      bn_code: false/' \
      -e "$([ "$OR_REAL" = 1 ] && printf '%s' 's/^model_list:$/model_list:\
  - model_name: "parity-bad-or"\
    litellm_params:\
      model: "openrouter\/parity\/no-such-model"\
      api_key: os.environ\/OPENROUTER_API_KEY\
    model_info:\
      mode: "chat"\
      bn_id: "parity-bad-or"\
      bn_compat: "fails"\
      bn_code: false/' || printf 's/^$//')" \
      -e "$([ "$XL_REAL" = 1 ] && printf '%s' 's/^model_list:$/model_list:\
  - model_name: "parity-bad-xl"\
    litellm_params:\
      model: "openai\/parity-no-such-model"\
      api_base: "https:\/\/api.experientiallabs.ai\/v1"\
      api_key: os.environ\/EXPLABS_API_KEY\
    model_info:\
      mode: "chat"\
      bn_id: "parity-bad-xl"\
      bn_compat: "fails"\
      bn_code: false/' || printf 's/^$//')" \
      -e 's/^  callbacks: \["bn_hooks.proxy_handler_instance"/  callbacks: ["bn_hooks.proxy_handler_instance", "parity_spend.handler"/' \
      "$WORK/litellm/config.yaml.new" > "$WORK/litellm/config.yaml" && rm -f "$WORK/litellm/config.yaml.new"
  grep -q 'parity_spend.handler' "$WORK/litellm/config.yaml" || die "the rendered config names no hook (lib/litellm-hooks/bn_hooks.py)"
  [ "$WS" = off ] || grep -q 'bn_hooks.web_search' "$WORK/litellm/config.yaml" || die "the rendered config has no web search (lib/websearch.sh)"
  # the stand-ins' list and catalog: the gateway's model ids (tests/fixtures) and its catalog answers
  cp "$ROOT/tests/fixtures/explabs_v1_models.json" "$WORK/mock/v1.json"
  cp "$ROOT/tests/fixtures/explabs_catalog/"*.json "$WORK/mock/catalog/"
  cp "$HERE/explabs-mock.py" "$WORK/mock/mock.py"
  chmod 755 "$WORK" "$WORK/litellm" "$WORK/mock" "$WORK/mock/catalog"; chmod 644 "$WORK/litellm/"* "$WORK/mock/"*.* "$WORK/mock/catalog/"*
  if [ "$WS" = builtin ]; then
    grep -q 'api_base: "http://searxng:8080"' "$WORK/litellm/config.yaml" || die "the rendered config does not search with the built-in SearXNG"
    [ -s "$WORK/searxng/settings.yml" ] || die "no settings.yml for the built-in SearXNG"
  fi
  chmod 600 "$MASTER_FILE"
fi
[ -r "$MASTER_FILE" ] || die "no kept throwaway (run without --reuse)"
MASTER="$(cat "$MASTER_FILE")"

if [ "$REUSE" = 0 ]; then
  IMAGE="$(sed -n 's/^    image: \(ghcr.io\/berriai\/litellm:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
  CADDY="$(sed -n 's/^    image: \(caddy:[^ ]*\)$/\1/p' "$ROOT/compose.terminal.yaml" | head -n 1)"
  [ -n "$IMAGE" ] && [ -n "$CADDY" ] || die "no LiteLLM or Caddy image in compose.yaml / compose.terminal.yaml"
  TIMAGE="${E2E_PARITY_TERMINAL_IMAGE:-}"
  if [ -z "$TIMAGE" ]; then
    TIMAGE="$NAME/terminal:local"
    say "building the terminal image from terminal/ ($TIMAGE)"
    docker build -q -t "$TIMAGE" --label io.bedrock-now.e2e=parity "$ROOT/terminal" > "$WORK/build.log" 2>&1 ||
      { tail -n 30 "$WORK/build.log" >&2; die "the terminal image did not build"; }
  fi
  PORT=18600
  while port_in_use "$PORT" || case "$AVOID_PORTS" in *" $PORT "*) true ;; *) false ;; esac; do PORT=$((PORT + 1)); done
  printf '%s\n' "$PORT" > "$WORK/.port"
  docker network create --label io.bedrock-now.e2e=parity "$NAME-out" >/dev/null || die "network $NAME-out"
  docker network create --internal --label io.bedrock-now.e2e=parity "$NAME-link" >/dev/null || die "network $NAME-link"
  docker network create --internal --label io.bedrock-now.e2e=parity "$NAME-term" >/dev/null || die "network $NAME-term"

  say "starting $NAME-litellm ($IMAGE) on 127.0.0.1:$PORT, with the stand-ins inside"
  # the stand-ins first (on the container's 127.0.0.1), then LiteLLM; the stand-ins' relay is LiteLLM itself
  LITELLM_MASTER_KEY="$MASTER" OR_APP_NAME="DevOS ADE" OR_SITE_URL="https://github.com/JongoDB-Labs/devos-ade" \
  docker run -d --name "$NAME-litellm" --label io.bedrock-now.e2e=parity --network "$NAME-out" -p "127.0.0.1:$PORT:4000" \
    -v "$WORK/litellm:/app/config:ro" -v "$WORK/mock:/mock:ro" \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION_NAME -e LITELLM_MASTER_KEY \
    -e LITELLM_LOCAL_MODEL_COST_MAP=True -e STORE_MODEL_IN_DB=False -e OPENROUTER_API_KEY -e EXPLABS_API_KEY -e OR_APP_NAME -e OR_SITE_URL \
    $([ "$OR_REAL" = 1 ] || printf -- '-e OPENROUTER_API_BASE=http://127.0.0.1:%s/api/v1' "$OR_PORT") \
    --entrypoint sh "$IMAGE" -c "PY=\$(command -v python3 || command -v python)
      MOCK_RELAY=http://127.0.0.1:4000 MOCK_RELAY_MODEL=$RELAY_MODEL MOCK_RELAY_KEY=\$LITELLM_MASTER_KEY \$PY /mock/mock.py $XL_PORT /tmp/xl-reqs.jsonl /mock/v1.json /mock/catalog &
      MOCK_FLAVOR=openrouter MOCK_RELAY=http://127.0.0.1:4000 MOCK_RELAY_MODEL=$RELAY_MODEL MOCK_RELAY_KEY=\$LITELLM_MASTER_KEY \$PY /mock/mock.py $OR_PORT /tmp/or-reqs.jsonl /mock/v1.json /mock/catalog &
      exec litellm --config /app/config/config.yaml --port 4000" >/dev/null || die "could not start $NAME-litellm"
  docker network connect --alias litellm "$NAME-link" "$NAME-litellm" || die "could not connect $NAME-litellm"

  if [ "$WS" = builtin ]; then
    # the built-in SearXNG as compose.yaml runs it: its image, user, read-only file system, settings and limits; on an
    # internal network with LiteLLM alone (as "searxng") and a way out of its own; a secret of this run's own (in its
    # environment only: SearXNG refuses its placeholder)
    SXIMAGE="$(sed -n 's/^    image: \(searxng\/searxng:[^ ]*\)$/\1/p' "$ROOT/compose.yaml" | head -n 1)"
    [ -n "$SXIMAGE" ] || die "no searxng image in compose.yaml"
    say "starting $NAME-searxng ($SXIMAGE)"
    docker network create --internal --label io.bedrock-now.e2e=parity "$NAME-ws" >/dev/null || die "network $NAME-ws"
    docker network create --label io.bedrock-now.e2e=parity "$NAME-wsout" >/dev/null || die "network $NAME-wsout"
    SEARXNG_SECRET="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')" \
    docker create --name "$NAME-searxng" --label io.bedrock-now.e2e=parity --network "$NAME-ws" --network-alias searxng \
      --user 977:977 --read-only --cap-drop ALL --security-opt no-new-privileges:true --memory 512m --pids-limit 128 \
      --tmpfs /var/cache/searxng:size=32m,uid=977,gid=977,mode=0700 --tmpfs /tmp:size=32m,mode=1777 \
      --add-host host.docker.internal:192.0.2.1 --add-host gateway.docker.internal:192.0.2.1 \
      -v "$WORK/searxng:/etc/searxng:ro" -e SEARXNG_SECRET "$SXIMAGE" >/dev/null || die "could not create $NAME-searxng"
    docker network connect "$NAME-wsout" "$NAME-searxng" || die "could not connect $NAME-searxng"
    docker start "$NAME-searxng" >/dev/null || die "could not start $NAME-searxng"
    docker network connect "$NAME-ws" "$NAME-litellm" || die "could not connect $NAME-litellm to $NAME-ws"
  fi

  say "starting $NAME-gateway (caddy/terminal-gateway.caddy)"
  # (both networks before it starts: Caddy binds to its name on each)
  docker create --name "$NAME-gateway" --label io.bedrock-now.e2e=parity --network "$NAME-term" --network-alias gateway \
    --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges:true \
    --tmpfs /data --tmpfs /config -v "$ROOT/caddy:/etc/caddy:ro" \
    "$CADDY" caddy run --config /etc/caddy/terminal-gateway.caddy --adapter caddyfile >/dev/null || die "could not create $NAME-gateway"
  docker network connect --alias terminal-upstream "$NAME-link" "$NAME-gateway" || die "could not connect $NAME-gateway"
  docker start "$NAME-gateway" >/dev/null || die "could not start $NAME-gateway"

  say "starting $NAME-sandbox ($TIMAGE)"
  ANTHROPIC_AUTH_TOKEN="$MASTER" docker run -d --name "$NAME-sandbox" --label io.bedrock-now.e2e=parity --network "$NAME-term" \
    --user 10104:10104 --read-only --cap-drop ALL --security-opt no-new-privileges:true --init \
    --tmpfs /tmp:size=1g,mode=1777 --tmpfs /home/claude:uid=10104,gid=10104,mode=0700,size=1g \
    --tmpfs /workspace:uid=10104,gid=10104,mode=0755,size=256m \
    --add-host host.docker.internal:192.0.2.1 --add-host gateway.docker.internal:192.0.2.1 \
    -v "$ROOT/terminal/bin/devos-claude:/usr/local/bin/devos-claude:ro" \
    -e ANTHROPIC_BASE_URL=http://gateway:8091 -e ANTHROPIC_AUTH_TOKEN \
    -e ANTHROPIC_MODEL=claude-haiku-5-5 -e ANTHROPIC_DEFAULT_OPUS_MODEL=claude-haiku-5-5 \
    -e ANTHROPIC_DEFAULT_SONNET_MODEL=claude-haiku-5-5 -e ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-5-5 \
    -e CLAUDE_BEDROCK_OPUS_MODEL=claude-haiku-5-5 -e CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 \
    -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 -e DISABLE_AUTOUPDATER=1 -e TERMINAL_AUTO_MODE=false \
    --entrypoint sleep "$TIMAGE" infinity >/dev/null || die "could not start $NAME-sandbox"
  docker network connect "$NAME-out" "$NAME-sandbox" || die "could not connect $NAME-sandbox"

  up=0
  for _ in $(seq 1 90); do
    if [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health/liveliness" 2>/dev/null)" = 200 ]; then up=1; break; fi
    docker container inspect -f '{{.State.Running}}' "$NAME-litellm" 2>/dev/null | grep true >/dev/null || break
    sleep 2
  done
  [ "$up" = 1 ] || { docker logs --tail 40 "$NAME-litellm" 2>&1 | tail -n 40 >&2; teardown; die "LiteLLM did not come up"; }
  say "LiteLLM is up"
  if [ "$WS" = builtin ]; then
    # the built-in SearXNG answers LiteLLM with real results before any scenario (its engines asked once)
    got=''
    for _ in $(seq 1 30); do
      got="$(docker exec "$NAME-litellm" python -c 'import json, urllib.request
d = json.load(urllib.request.urlopen("http://searxng:8080/search?q=IANA+example+domain&format=json", timeout=20))
print(len(d.get("results", [])), ",".join(sorted({e for r in d.get("results", []) for e in r.get("engines", [])})))' 2>/dev/null)"
      [ "${got%% *}" -gt 0 ] 2>/dev/null && break
      sleep 3
    done
    [ "${got%% *}" -gt 0 ] 2>/dev/null || { docker logs --tail 30 "$NAME-searxng" 2>&1 | tail -n 30 >&2; teardown; die "the built-in SearXNG gave LiteLLM no results"; }
    say "the built-in SearXNG answers LiteLLM: ${got%% *} results from ${got#* }"
  fi
fi
PORT="$(cat "$WORK/.port")"

# the key never on a command line: the driver reads the master key from a file of its own
rc=0
LITELLM_PORT="$PORT" MASTER_FILE="$MASTER_FILE" python3 -I "$HERE/harness-parity.py" --name "$NAME" --out "$OUT" --models "$MODELS" \
  ${SCENARIOS:+--scenarios "$SCENARIOS"} --relay-model "$RELAY_MODEL" \
  --or-mode "$([ "$OR_REAL" = 1 ] && echo real || echo stand-in)" --xl-mode "$([ "$XL_REAL" = 1 ] && echo real || echo stand-in)" \
  --code-dir "$ROOT/code" --jobs "${E2E_PARITY_JOBS:-3}" --websearch "$WS" \
  --deadline-min "${E2E_PARITY_MINUTES:-0}" || rc=$?

# --- the keys, nowhere
leak=''
for k in "$OPENROUTER_API_KEY" "$EXPLABS_API_KEY" "$AWS_SECRET_ACCESS_KEY" "$MASTER"; do
  if printf '%s\n' "$k" | grep -rqF -f - "$OUT/harness-parity.tsv" "$OUT/harness-parity.json" "$OUT/harness-parity-stand-ins.jsonl" "$OUT/harness-parity-logs" 2>/dev/null; then leak=1; fi
done
[ -z "$leak" ] || { echo "FAIL a key is in the results: removing them" >&2; rm -rf "$OUT/harness-parity.tsv" "$OUT/harness-parity.json" "$OUT/harness-parity-stand-ins.jsonl" "$OUT/harness-parity-logs"; rc=1; }

[ "$KEEP" = 0 ] || say "kept (tests/e2e/harness-parity.sh --reuse runs again on it; --teardown removes it)"
exit "$rc"
