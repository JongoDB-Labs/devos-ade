# shellcheck shell=bash
# The rename to DevOS ADE (v0.25.0, formerly bedrock-now): no old name left where a person reads it, one value per layer
# for the names, the GitHub App's slug written once, and every internal name — the Compose project, volumes, hosts,
# labels, salts, cookie names, BEDROCK_NOW_* — as it was (docs/internal-names.md says why each stays).

test_no_old_name_left_where_a_person_reads_it() {
  local out
  if ! out="$(python3 "$T_ROOT/tests/brand_check.py" --root "$T_ROOT" 2>&1)"; then
    printf '%s\n' "$out" | tail -40 >&2; return 1
  fi
}

test_the_brand_check_finds_an_old_name_and_takes_the_allowed_ones() {
  local r="$TMP/repo"; mkdir -p "$r/docs" "$r/tests/fixtures" "$r/lib"; git -C "$r" init -q
  cp "$T_ROOT/docs/internal-names.md" "$r/docs/"
  printf 'lib/x.sh\tkeep bedrock-now here\twhy\n' > "$r/tests/fixtures/brand-allow.txt"
  printf 'log "DevOS ADE is up"\nhost=bedrock-now.localhost v=$BEDROCK_NOW_DIR\n# keep bedrock-now here\n' > "$r/lib/x.sh"
  printf '## [Unreleased]\n- DevOS ADE (formerly bedrock-now)\n## [0.24.0]\n- bedrock-now did\n' > "$r/CHANGELOG.md"
  printf 'echo bedrock-now\n' > "$r/tests/t.sh"   # the tests are not read
  python3 "$T_ROOT/tests/brand_check.py" --root "$r" > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  printf 'echo "Bedrock Now is up"\n' > "$r/lib/y.sh"; printf '## [0.25.0]\n- bedrock-now here\n' >> "$r/CHANGELOG.md"
  if python3 "$T_ROOT/tests/brand_check.py" --root "$r" > "$TMP/out" 2>&1; then echo "missed an old name" >&2; return 1; fi
  assert_contains "$(cat "$TMP/out")" "lib/y.sh:1: echo \"Bedrock Now is up\""
  assert_not_contains "$(cat "$TMP/out")" "0.24.0"
  # an exemption that matches nothing any more fails too
  rm "$r/lib/y.sh"; printf '## [0.24.0]\n' > "$r/CHANGELOG.md"; printf 'log ok\n' > "$r/lib/x.sh"
  if python3 "$T_ROOT/tests/brand_check.py" --root "$r" > "$TMP/out" 2>&1; then echo "kept a stale exemption" >&2; return 1; fi
  assert_contains "$(cat "$TMP/out")" "stale exemption"
}

# _py_const FILE NAME -> NAME = "value" of a Python file; _js_const FILE NAME -> export const NAME = 'value'
_py_const() { sed -n "s/^$2 = \"\\(.*\\)\"\$/\\1/p" "$1"; }
_js_const() { sed -n "s/^export const $2 = '\\(.*\\)';\$/\\1/p" "$1"; }

test_the_names_agree_in_every_layer() {
  assert_eq "$PRODUCT_NAME|$PRODUCT_SLUG|$PRODUCT_REPO" "DevOS ADE|devos-ade|JongoDB-Labs/devos-ade"
  assert_eq "$PRODUCT_LEGACY_NAME|$PRODUCT_LEGACY_REPO" "bedrock-now|JongoDB-Labs/bedrock-now"
  local b="$T_ROOT/portal/portal/brand.py"
  assert_eq "$(_py_const "$b" NAME)|$(_py_const "$b" SLUG)|$(_py_const "$b" REPO)" "$PRODUCT_NAME|$PRODUCT_SLUG|$PRODUCT_REPO"
  assert_eq "$(_py_const "$b" LEGACY_NAME)|$(_py_const "$b" LEGACY_REPO)" "$PRODUCT_LEGACY_NAME|$PRODUCT_LEGACY_REPO"
  assert_eq "$(_js_const "$T_ROOT/code/server/brand.mjs" PRODUCT)|$(_js_const "$T_ROOT/code/server/brand.mjs" PRODUCT_SLUG)" "$PRODUCT_NAME|$PRODUCT_SLUG"
  assert_eq "$(_js_const "$T_ROOT/code/web/src/brand.ts" PRODUCT)" "$PRODUCT_NAME"
  # install.sh's own copy (it runs before there is a checkout)
  assert_eq "$(BEDROCK_NOW_INSTALL_LIB=1 bash -c '. "$1"; printf "%s|%s|%s|%s|%s|%s" "$PRODUCT_NAME" "$PRODUCT_SLUG" "$PRODUCT_REPO" "$PRODUCT_LEGACY_NAME" "$PRODUCT_LEGACY_REPO" "$BN_REPO_URL"' _ "$T_ROOT/install.sh")" \
    "$PRODUCT_NAME|$PRODUCT_SLUG|$PRODUCT_REPO|$PRODUCT_LEGACY_NAME|$PRODUCT_LEGACY_REPO|https://github.com/$PRODUCT_REPO"
  # the users of the portal's: the update check and the installed app's name
  assert_contains "$(cat "$T_ROOT/portal/portal/updates.py")" "REPO = brand.REPO"
  assert_contains "$(cat "$T_ROOT/portal/portal/updates.py")" "LEGACY_REPO = brand.LEGACY_REPO"
  assert_contains "$(cat "$T_ROOT/portal/portal/webapp.py")" "BASE = brand.NAME"
  # the one-liner the README and the docs give points at the new repository
  assert_contains "$(cat "$T_ROOT/README.md")" "https://raw.githubusercontent.com/$PRODUCT_REPO/main/install.sh"
  assert_contains "$(sed -n 1,5p "$T_ROOT/install.sh")" "https://raw.githubusercontent.com/$PRODUCT_REPO/main/install.sh"
}

test_the_github_apps_slug_is_written_in_one_place() {
  # GITHUB_APP_SLUG in code/server/oauth.mjs: the App's address (github.com/apps/<slug>) and every link built from it
  local o="$T_ROOT/code/server/oauth.mjs" hits
  assert_eq "$(grep -c "^export const GITHUB_APP_SLUG = '[a-z0-9][a-z0-9-]*';\$" "$o")" 1
  assert_contains "$(grep '^export const DEFAULT_APPS' "$o")" "appSlug: GITHUB_APP_SLUG"
  # no other slug in the code, and no App address with a slug in it in the docs (they name the App, not its address)
  hits="$(cd "$T_ROOT" && git grep -nE "appSlug: '[a-z0-9-]+'|apps/[a-z0-9][a-z0-9-]*/installations|github\.com/apps/[a-z0-9][a-z0-9-]*([^a-z0-9<-]|\$)" \
    -- code/server code/web/src code/plain portal/portal lib catalog README.md docs ':!CHANGELOG.md' || true)"
  assert_eq "$hits" ""
}

test_internal_names_are_as_they_were() {
  local f t miss=""
  while IFS="$(printf '\t')" read -r f t; do
    case "$f" in '#'* | '') continue ;; esac
    grep -qF -- "$t" "$T_ROOT/$f" || miss="$miss
  $f: $t"
  done < "$T_ROOT/tests/fixtures/internal-names.tsv"
  [ -z "$miss" ] || { echo "an internal name changed — data, links or sign-ins would break:$miss" >&2; return 1; }
  [ -x "$T_ROOT/bin/bedrock-now-helper" ] || { echo "bin/bedrock-now-helper is gone" >&2; return 1; }
  # every BEDROCK_NOW_* name of v0.24.0 is still read
  local n src
  src="$(cd "$T_ROOT" && git grep -hoE 'BEDROCK_NOW_[A-Z0-9_]*' -- . ':!tests' ':!portal/tests' ':!code/test' ':!code/web/test' ':!code/web/e2e' ':!portal/e2e' ':!CHANGELOG.md' ':!README.md' ':!docs' | sort -u)"
  while read -r n; do
    case "$n" in '#'* | '') continue ;; esac
    printf '%s\n' "$src" | grep -q "^$n" || miss="$miss $n"
  done < "$T_ROOT/tests/fixtures/env-names.txt"
  [ -z "$miss" ] || { echo "no longer read:$miss" >&2; return 1; }
}

# --- the Compose project, as Docker Compose renders it: the same names as v0.24.0's (tests/fixtures/compose-golden) ---

_golden_env() { # _golden_env CASE -> writes .env for that case
  printf 'POSTGRES_PASSWORD=p\nRUSTFS_ACCESS_KEY=a\nRUSTFS_SECRET_KEY=s\nLITELLM_MASTER_KEY=m\nLITELLM_SALT_KEY=s\nLITELLM_UI_PASSWORD=u\nWEBUI_SECRET_KEY=w\nOPENWEBUI_ADMIN_EMAIL=a@b.c\nOPENWEBUI_ADMIN_PASSWORD=p\nSHARED_MCP_TOKEN=t\n' > "$ENV_FILE"
  case "$1" in
    default) ;;
    all | copy | host | off)
      mkdir -p "$TMP/ws"
      printf 'TERMINAL_ENABLED=true\nTERMINAL_WORKSPACE=%s\nCODE_ENABLED=true\nREMOTE_MODE=domain\nREMOTE_DOMAIN=ai.example.com\nCLOUDFLARE_API_TOKEN=x\nTS_AUTHKEY=x\nSTT_PROVIDER=bedrock\n' "$TMP/ws" >> "$ENV_FILE"
      case "$1" in
        copy) printf 'COMPOSE_PROJECT_NAME=bn-two\nPORTAL_HOST=bn-two.localhost\nPORTAL_PORT=8801\n' >> "$ENV_FILE" ;;
        host) printf 'TERMINAL_EGRESS=host\n' >> "$ENV_FILE" ;;
        off) printf 'TERMINAL_EGRESS=off\n' >> "$ENV_FILE" ;;
      esac ;;
  esac
}

test_the_compose_projects_names_are_as_they_were() {
  [ -n "${BN_REAL_DOCKER:-}" ] && "$BN_REAL_DOCKER" compose version >/dev/null 2>&1 || { echo "no docker compose" >&2; return 77; }
  docker() { case "$*" in *" config --format json") "$BN_REAL_DOCKER" "$@" ;; *) echo "unexpected docker $*" >&2; return 97 ;; esac; }
  local c dir="$T_ROOT/tests/fixtures/compose-golden" diffs=""
  for c in default all copy host off; do
    _golden_env "$c"
    dc config --format json 2>"$TMP/err" | python3 "$T_ROOT/tests/compose_golden.py" "<STACK>=$STACK_DIR" "<STATE>=$STATE_DIR" \
      "<WORKSPACE>=$TMP/ws" "<HOME>=$HOME" > "$TMP/$c.json" || { cat "$TMP/err" >&2; return 1; }
    if [ "${BN_GOLDEN_WRITE:-0}" = 1 ]; then cp "$TMP/$c.json" "$dir/$c.json"; continue; fi
    diff -u "$dir/$c.json" "$TMP/$c.json" > "$TMP/$c.diff" || diffs="$diffs$(cat "$TMP/$c.diff")
"
  done
  [ -z "$diffs" ] || { printf 'an internal name changed: data or links would break\n%s\n' "$diffs" | head -60 >&2; return 1; }
}
