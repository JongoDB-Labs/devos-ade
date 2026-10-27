# shellcheck shell=bash
# LiteLLM's model list changed without a restart (JON-533). Sourced by lib/commands.sh.
#
# litellm/config.yaml stays the record: ./stack renders it first, and a LiteLLM that starts (or restarts) reads it as
# always. A running LiteLLM gets the same change at once through its model admin API (LiteLLM 1.105.0, with
# store_model_in_db on: compose.yaml's STORE_MODEL_IN_DB):
#   - each model added or changed: POST /model/new with its entry exactly as config.yaml has it — litellm_params (the
#     key as its os.environ/ reference, never the value), model_info (the hook's bn_* keys, mode) and its stable id
#     ("bn-<name>": lib/models.sh litellm_model_ids), so it replaces the deployment of that id (or adds one). Its prices
#     go in litellm_params as well: /model/new keeps a deployment's own prices there (it drops them from model_info and
#     mirrors them back from litellm_params), and LiteLLM books a call with the same prices either way;
#   - every model config.yaml no longer has: let go of by LiteLLM's own reconcile, which reads config.yaml again and
#     drops each deployment that neither it nor the database lists (it runs inside /model/new; a change that only
#     removes models asks for it with an empty POST /config/update);
#   - then the database rows /model/new left are deleted (model_id 'bn-%': ours only; a model added in LiteLLM's own UI
#     keeps its row), so config.yaml stays the only record: a restart never brings back an older copy of a model;
#   - and LiteLLM is asked for its model list: the ids of ours must be config.yaml's, each changed one with config.yaml's
#     model, base, drops and bn_* keys.
# The script runs inside LiteLLM's container (docker exec: its Python and PyYAML, its own LITELLM_MASTER_KEY, on its own
# 127.0.0.1:4000 — the master key never leaves the host and that container; no browser ever sees it); the rows go with
# psql inside Postgres's.
# Only what the model list says changes live. Anything else in config.yaml (callbacks, router or general settings, the
# search tools), more than LITELLM_LIVE_MAX models at once, or a LiteLLM that does not run the config the change started
# from: the caller restarts LiteLLM instead (Compose then recreates it: BN_LITELLM_CONFIG_SUM, lib/common.sh).
#
#   litellm_live_sync OLD_SUM OLD_FILE  0: LiteLLM serves config.yaml now (LITELLM_LIVE_SAID says what changed);
#                                       3: not live — restart it (LITELLM_LIVE_ERR says why); else failed (LITELLM_LIVE_ERR)
#   litellm_db_rows_clear               the database rows of our models gone (also before a restart: a sync cut short)

LITELLM_LIVE_MAX="${LITELLM_LIVE_MAX:-40}"   # models added or changed at once (each /model/new reconciles: ~0.1 s)

# _compose_cid SERVICE -> the running container of SERVICE in this checkout's project (docker ps by Compose's labels:
# no compose call), nothing when none runs
_compose_cid() {
  docker ps -q --no-trunc --filter "label=com.docker.compose.project=$(project_name)" \
    --filter "label=com.docker.compose.service=$1" --filter status=running 2>/dev/null | head -n 1
}

# litellm_serving_sum CID -> the checksum (BN_LITELLM_CONFIG_SUM's kind) of the config LiteLLM in CID serves: the one
# it started with (its BN_CONFIG_SUM), or the one ./stack gave it live since (litellm_live_sum_file names it, with the
# BN_CONFIG_SUM of the container it was given to)
litellm_serving_sum() {
  local base live lbase
  base="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n 's/^BN_CONFIG_SUM=//p' | head -n 1)"
  live=''; lbase=''
  [ ! -r "$(litellm_live_sum_file)" ] || read -r live lbase < "$(litellm_live_sum_file)" || true
  if [ -n "$live" ] && [ -n "$base" ] && [ "$lbase" = "$base" ]; then printf '%s\n' "$live"; else printf '%s\n' "$base"; fi
}

# litellm_db_rows_clear [PG_CID] — the rows /model/new left in LiteLLM's database for our models (ids bn-…) deleted:
# the router keeps serving them (config.yaml lists them), and a LiteLLM that starts reads config.yaml alone. 0 when
# none is left (or Postgres does not run: nothing to clear then — LiteLLM cannot run without it).
litellm_db_rows_clear() {
  local pg="${1:-}"
  [ -n "$pg" ] || pg="$(_compose_cid postgres)"
  [ -n "$pg" ] || return 0
  docker exec "$pg" psql -U postgres -d litellm -v ON_ERROR_STOP=1 -qAt \
    -c "DELETE FROM \"LiteLLM_ProxyModelTable\" WHERE model_id LIKE 'bn-%'" >/dev/null 2>&1
}

litellm_live_sync() {
  local old_sum="$1" old="$2" cid pg out rc=0 base now
  # shellcheck disable=SC2034  # LITELLM_LIVE_ERR and LITELLM_LIVE_SAID are read by lib/settings.sh (the caller)
  LITELLM_LIVE_ERR=''; LITELLM_LIVE_SAID=''
  cid="$(_compose_cid litellm)"; pg="$(_compose_cid postgres)"
  [ -n "$cid" ] && [ -n "$pg" ] || { LITELLM_LIVE_ERR="LiteLLM is not running"; return 3; }
  [ -r "$old" ] || { LITELLM_LIVE_ERR="no copy of the config it ran"; return 3; }
  base="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null | sed -n 's/^BN_CONFIG_SUM=//p' | head -n 1)"
  if [ -z "$old_sum" ] || [ "$(litellm_serving_sum "$cid")" != "$old_sum" ]; then
    LITELLM_LIVE_ERR="LiteLLM does not run the config this change started from"; return 3
  fi
  # (a sync cut short before its rows went: cleared first, so none of an older copy is left)
  litellm_db_rows_clear "$pg" || true
  out="$(docker exec -i "$cid" python -I -c "$LITELLM_LIVE_PY" "$LITELLM_LIVE_MAX" < "$old" 2>/dev/null)" || rc=$?
  out="$(printf '%s\n' "$out" | tail -n 1 | LC_ALL=C tr -cd '\040-\176')"
  if ! litellm_db_rows_clear "$pg"; then
    LITELLM_LIVE_ERR="could not delete the database rows of the models it added (psql)"; return 1
  fi
  case "$rc" in
    0) now="$(litellm_config_sum_now)"
       mkdir -p "$STATE_DIR" && printf '%s %s\n' "$now" "$base" > "$(litellm_live_sum_file)"
       LITELLM_LIVE_SAID="$(_litellm_live_field "$out" said)"; return 0 ;;
    3) LITELLM_LIVE_ERR="$(_litellm_live_field "$out" why)"; return 3 ;;
    *) LITELLM_LIVE_ERR="$(_litellm_live_field "$out" why)"; LITELLM_LIVE_ERR="${LITELLM_LIVE_ERR:-LiteLLM did not answer (exit $rc)}"; return 1 ;;
  esac
}

# _litellm_live_field JSON KEY -> a string field of the script's one-line answer (printable ASCII; no quotes)
_litellm_live_field() { printf '%s' "$1" | sed -n "s/.*\"$2\": \"\\([^\"]*\\)\".*/\\1/p" | head -n 1; }

# The script, in LiteLLM's container: OLD config.yaml on stdin, the new one at /app/config/config.yaml, MAX in argv[1].
# One line of JSON on stdout: {"result": "ok|restart|failed", "said"|"why": …}; exit 0, 3 (restart) or 1.
# shellcheck disable=SC2016  # Python source
LITELLM_LIVE_PY='
import json, os, sys, urllib.error, urllib.request
import yaml
MAX = int(sys.argv[1])
# a deployment'"'"'s own prices: /model/new keeps them on litellm_params (and mirrors them into model_info from there)
PRICES = ("input_cost_per_token", "output_cost_per_token", "input_cost_per_character", "output_cost_per_character",
          "cache_read_input_token_cost", "cache_creation_input_token_cost", "input_cost_per_second", "output_cost_per_second",
          "input_cost_per_image", "output_cost_per_image", "input_cost_per_query")
def done(result, code, **kw):
    print(json.dumps(dict(result=result, **kw)))
    sys.exit(code)
try:
    old = yaml.safe_load(sys.stdin.read()) or {}
    with open(os.environ.get("LITELLM_LIVE_CONFIG", "/app/config/config.yaml"), encoding="utf-8") as f:
        new = yaml.safe_load(f) or {}
except Exception as e:
    done("restart", 3, why="a config could not be read (%s)" % type(e).__name__)
def rest(c):
    return {k: v for k, v in c.items() if k != "model_list"}
if rest(old) != rest(new):
    done("restart", 3, why="settings besides the model list changed")
def models(c):
    out = {}
    for m in c.get("model_list") or []:
        if not isinstance(m, dict) or "model_name" not in m:
            done("restart", 3, why="a model entry without a name")
        out[m["model_name"]] = m
    return out
om, nm = models(old), models(new)
for n, m in list(om.items()) + list(nm.items()):
    if not str((m.get("model_info") or {}).get("id", "")).startswith("bn-"):
        done("restart", 3, why="%s has no stable id (a config rendered before this version)" % n)
add = [n for n in nm if n not in om]
chg = [n for n in nm if n in om and om[n] != nm[n]]
rm = [n for n in om if n not in nm]
if not (add or chg or rm):
    done("ok", 0, said="no model changed")
if len(add) + len(chg) > MAX:
    done("restart", 3, why="%d models added or changed (more than %d at once)" % (len(add) + len(chg), MAX))
KEY = os.environ.get("LITELLM_MASTER_KEY", "")
URL = os.environ.get("LITELLM_LIVE_URL", "http://127.0.0.1:4000")   # (tests/test_litellm_live.sh: a stand-in)
def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method,
                                 headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:200].decode("utf-8", "replace")
    except Exception as e:
        return 0, type(e).__name__
def payload(m):
    p = json.loads(json.dumps(m))
    lp, mi = p.setdefault("litellm_params", {}), p.setdefault("model_info", {})
    for k in PRICES:
        if k in mi and k not in lp:
            lp[k] = mi[k]
    return p
for n in add + chg:
    st, body = call("POST", "/model/new", payload(nm[n]))
    if st != 200:
        done("failed", 1, why="LiteLLM refused %s (HTTP %s): %s" % (n, st, "".join(c for c in str(body) if " " <= c <= "~")[:160]))
if rm and not (add or chg):
    st, body = call("POST", "/config/update", {})
    if st != 200:
        done("failed", 1, why="LiteLLM did not read config.yaml again (HTTP %s)" % st)
# what LiteLLM serves now: our ids exactly config.yaml'"'"'s, each changed one as config.yaml has it
st, info = call("GET", "/model/info")
if st != 200 or not isinstance(info, dict):
    done("failed", 1, why="LiteLLM did not list its models (HTTP %s)" % st)
live = {}
for d in info.get("data") or []:
    mi = d.get("model_info") or {}
    i = str(mi.get("id", ""))
    if i.startswith("bn-") and d.get("model_name") == (mi.get("bn_id") or d.get("model_name")):
        live.setdefault(i, d)
want = {str(m["model_info"]["id"]): m for m in nm.values()}
if set(live) != set(want):
    miss, extra = sorted(set(want) - set(live)), sorted(set(live) - set(want))
    done("failed", 1, why="LiteLLM serves other models than config.yaml: missing %s, left %s" % (",".join(miss)[:120], ",".join(extra)[:120]))
for n in add + chg:
    m, d = nm[n], live[str(nm[n]["model_info"]["id"])]
    lp, mi = d.get("litellm_params") or {}, d.get("model_info") or {}
    for k, v in (m.get("litellm_params") or {}).items():
        if isinstance(v, str) and v.startswith("os.environ/"):
            continue
        if k in lp and lp[k] != v:
            done("failed", 1, why="%s: LiteLLM has another %s than config.yaml" % (n, k))
    for k, v in (m.get("model_info") or {}).items():
        if (k.startswith("bn_") or k == "mode") and mi.get(k) != v:
            done("failed", 1, why="%s: LiteLLM has another model_info %s than config.yaml" % (n, k))
done("ok", 0, said="%d added, %d changed, %d removed" % (len(add), len(chg), len(rm)))
'
