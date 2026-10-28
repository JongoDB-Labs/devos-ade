# shellcheck shell=bash
# The model browser's lists (Settings › Models & providers › Browse models; portal/portal/model_browser.py): which
# models each provider with a key could add, read here — never in the browser, never with a key in the portal — and
# cached in .state/status/model-browser/ for the portal (read-only there):
#   bedrock.json          lib/model_browser_bedrock.py in a one-off container of LiteLLM's image, with LiteLLM's own AWS
#                         sign-in: ListFoundationModels and ListInferenceProfiles in AWS_REGION_NAME (read-only, free),
#                         each model's price, context, tool use and image input from LiteLLM's own price map. A key that
#                         may not list them: said (status denied), and the browser shows the catalog's models instead.
#   explabs-ids.json      the ids the Experiential Labs key may call (GET /v1/models with the key, as lib/explabs.sh
#                         reads it: curl -K -, never on a command line), and when; without a key, no file
#   explabs-catalog-N.json   the gateway's public catalog, page N (GET /api/models?limit=500&offset=…, keyless: nothing
#                         about you is sent), as it came — the portal reads each model's prices, context, tools and image
#                         input from it, field by field
# OpenRouter's list is public: the portal reads it itself (GET https://openrouter.ai/api/v1/models, cached an hour).
#
#   model_browser_refresh [--force]   each list older than MODEL_BROWSER_MAX_AGE_MIN read again (all of them with
#                                     --force), for the providers with a key; never fails. ./stack models browse, and
#                                     the update helper (a diagnostic, or when the portal asks: model_browser_tick)
MODEL_BROWSER_MAX_AGE_MIN=60
MODEL_BROWSER_CATALOG_PAGES=4          # 500 models a page: the gateway listed 963 on 2026-10-26
MODEL_BROWSER_PAGE_MAX_BYTES=8000000   # one page was 2.4 MB on 2026-10-26
model_browser_dir() { printf '%s/model-browser\n' "$(status_dir)"; }
# (the portal says someone opened the browser while a list is older than an hour: a file of this name in the requests
# folder, nothing in it — the helper reads the lists again, at most every MODEL_BROWSER_TICK_MIN minutes)
model_browser_wanted_file() { printf '%s/models-wanted\n' "$(request_dir)"; }
MODEL_BROWSER_TICK_MIN=10

# _mb_fresh FILE MIN -> 0 when FILE was written less than MIN minutes ago
_mb_fresh() { [ -s "$1" ] && [ -n "$(find "$1" -mmin "-$2" 2>/dev/null)" ]; }

# _mb_put NAME < content — NAME in the folder, atomically, readable by the portal
_mb_put() {
  local d tmp; d="$(model_browser_dir)"
  mkdir -p "$d" 2>/dev/null && chmod 755 "$d" 2>/dev/null || return 0
  tmp="$(mktemp "$d/.$1.XXXXXX")" || return 0
  if cat > "$tmp"; then chmod 644 "$tmp"; mv -f "$tmp" "$d/$1"; else rm -f "$tmp"; fi
}

# _mb_json_str TEXT -> TEXT as a JSON string (quotes, backslashes and control characters left out: our own words only)
_mb_json_str() { printf '"%s"' "$(printf '%s' "$1" | LC_ALL=C tr -d '"\\\000-\037\177' | cut -c1-300)"; }

# model_browser_bedrock — bedrock.json: the text models this AWS key could add in its region (or why not)
model_browser_bedrock() {
  local out region now; now="$(date +%s)"; region="$(get_env AWS_REGION_NAME)"
  if [ -z "$(get_env LITELLM_MASTER_KEY)" ]; then
    printf '{"provider":"bedrock","status":"error","why":%s,"at":%s,"models":[]}\n' "$(_mb_json_str "run ./stack setup first")" "$now" | _mb_put bedrock.json
    return 0
  fi
  # (the script as an argument: _with_deadline gives the command /dev/null; Bedrock's calls give up after 20 s each)
  out="$(_with_deadline 120 dc run --rm --no-deps -T --entrypoint python litellm -I -c "$(cat "$STACK_DIR/lib/model_browser_bedrock.py")" \
    "$region" 2>/dev/null)" || true
  # (its one line: a JSON object it printed, no control character, within 4 MB)
  out="$(printf '%s\n' "$out" | LC_ALL=C grep -E '^\{"provider":"bedrock",[ -~]*\}$' | tail -n 1 | head -c 4000000 || true)"
  if [ -z "$out" ]; then
    printf '{"provider":"bedrock","status":"error","why":%s,"at":%s,"models":[]}\n' \
      "$(_mb_json_str "the list was not read (LiteLLM's image could not start a container)")" "$now" | _mb_put bedrock.json
    return 0
  fi
  printf '%s\n' "${out%\}},\"at\":$now}" | _mb_put bedrock.json
}

# model_browser_explabs — explabs-ids.json and the catalog's pages; none of it without a key (and their files go)
model_browser_explabs() {
  local d ids raw now o total page err='' n=0 code
  d="$(model_browser_dir)"; now="$(date +%s)"
  if ! explabs_enabled || ! xl_api_ok; then rm -f "$d"/explabs-ids.json "$d"/explabs-catalog-*.json 2>/dev/null; return 0; fi
  ids="$(mktemp)"; raw="$(mktemp)"
  if xl_fetch_ids "$ids" "$(get_env EXPLABS_API_KEY)"; then
    { printf '{"provider":"explabs","at":%s,"error":null,"ids":[' "$now"
      awk 'NR > 1 { printf "," } { printf "\"%s\"", $0 }' "$ids"   # (valid_xl_id: nothing to escape)
      printf ']}\n'; } | _mb_put explabs-ids.json
  else
    err="$XL_ERR"
    printf '{"provider":"explabs","at":%s,"error":%s,"ids":[]}\n' "$now" "$(_mb_json_str "$err")" | _mb_put explabs-ids.json
  fi
  # the public catalog, page by page (keyless), until it has said how many it holds
  o=0; total=''
  while [ "$n" -lt "$MODEL_BROWSER_CATALOG_PAGES" ]; do
    code="$(curl --proto "$(_xl_proto)" -sS --connect-timeout 10 -m 90 --max-filesize "$MODEL_BROWSER_PAGE_MAX_BYTES" -o "$raw" \
      -w '%{http_code}' "$EXPLABS_CATALOG?limit=500&offset=$o" 2>/dev/null)" || code=000
    [ "$code" = 200 ] && LC_ALL=C grep -q '^[[:space:]]*{' "$raw" || break
    n=$((n + 1)); page="explabs-catalog-$n.json"
    _mb_put "$page" < "$raw"
    total="$(LC_ALL=C grep -o '"total"[[:space:]]*:[[:space:]]*[0-9]*' "$raw" | head -n 1 | tr -dc '0-9')"
    o=$((o + 500))
    [ -n "$total" ] && [ "$o" -lt "$total" ] || break
  done
  # (pages of an earlier, longer read: gone)
  for page in "$d"/explabs-catalog-*.json; do
    [ -e "$page" ] || continue
    case "${page##*/explabs-catalog-}" in *[!0-9]*.json) ;; *) [ "${page##*/explabs-catalog-}" -le "$n" ] 2>/dev/null || rm -f "$page" ;; esac
  done
  rm -f "$ids" "$raw"
}

# model_browser_refresh [--force] — the lists of the providers with a key, each read again when older than
# MODEL_BROWSER_MAX_AGE_MIN (or always, with --force); says what it read. Never fails.
model_browser_refresh() {
  local force=0 d; [ "${1:-}" != --force ] || force=1
  d="$(model_browser_dir)"
  if [ "$force" = 1 ] || ! _mb_fresh "$d/bedrock.json" "$MODEL_BROWSER_MAX_AGE_MIN"; then
    model_browser_bedrock
    log "model browser: Bedrock's list read ($(_mb_count "$d/bedrock.json") models)"
  fi
  if ! explabs_enabled; then rm -f "$d"/explabs-ids.json "$d"/explabs-catalog-*.json 2>/dev/null
  elif [ "$force" = 1 ] || ! _mb_fresh "$d/explabs-ids.json" "$MODEL_BROWSER_MAX_AGE_MIN"; then
    model_browser_explabs
    log "model browser: Experiential Labs' list read ($(_mb_count "$d/explabs-ids.json" '"ids"') ids your key may call)"
  fi
  return 0
}
# _mb_count FILE [FIELD] -> about how many entries FILE lists (its "id" strings, or FIELD's array's)
_mb_count() {
  [ -r "$1" ] || { echo 0; return 0; }
  if [ -n "${2:-}" ]; then sed -n 's/.*"ids":\[\(.*\)\].*/\1/p' "$1" | tr ',' '\n' | grep -c '"' || true
  else LC_ALL=C grep -o '"id":"' "$1" | wc -l | tr -d ' '; fi
}

# cmd_models_browse [--refresh] — ./stack models browse: the lists read (when older than an hour, or --refresh), and
# how many each has
cmd_models_browse() {
  case "${1:-}" in --refresh) model_browser_refresh --force ;; '') model_browser_refresh ;; *) die "usage: ./stack models browse [--refresh]" ;; esac
  printf 'The model browser (Settings › Models & providers › Browse models) lists:\n'
  printf '  Bedrock            %s models in %s\n' "$(_mb_count "$(model_browser_dir)/bedrock.json")" "$(get_env AWS_REGION_NAME)"
  if explabs_enabled; then printf '  Experiential Labs  %s models your key may call\n' "$(_mb_count "$(model_browser_dir)/explabs-ids.json" ids)"; fi
  if openrouter_enabled; then printf '  OpenRouter         its public list, read by the portal\n'; fi
}

# model_browser_tick — the update helper, each loop: when the portal asked (model_browser_wanted_file), or no list was
# ever read here (the first open of the page then finds them), the lists older than an hour read again, in the
# background, at most every MODEL_BROWSER_TICK_MIN minutes. While a read runs or the stack is busy, the request waits.
model_browser_tick() {
  local w last pid; w="$(model_browser_wanted_file)"; last="$(helper_dir)/model-browser-last"
  [ -e "$w" ] || [ ! -e "$last" ] || return 0
  pid="$(cat "$(helper_dir)/model-browser.pid" 2>/dev/null || true)"
  case "$pid" in '' | *[!0-9]*) ;; *) ! kill -0 "$pid" 2>/dev/null || return 0 ;; esac
  [ -z "$(stack_lock_holder)" ] || return 0
  rm -f "$w"
  ! _mb_fresh "$last" "$MODEL_BROWSER_TICK_MIN" || return 0
  date +%s 2>/dev/null > "$last" || return 0   # (not empty: _mb_fresh counts an empty file as never written; unwritable: never a read every loop)
  ( cd "$STACK_DIR" && exec env BEDROCK_NOW_JOB_ORIGIN=helper NO_COLOR=1 "$STACK_DIR/stack" models browse ) </dev/null > "$(helper_dir)/model-browser.log" 2>&1 &
  printf '%s\n' "$!" > "$(helper_dir)/model-browser.pid"
}
