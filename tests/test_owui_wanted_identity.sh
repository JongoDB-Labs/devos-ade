# shellcheck shell=bash
# shellcheck disable=SC2329,SC2034  # stubs are called by the code under test; CATALOG and the others are read by lib/
# JON-972: _owui_models_wanted (lib/owui.sh) builds Chat's list of models in one pass. tests/fixtures/
# owui_models_wanted_old.sh keeps the per-model version (v0.68.6); each case runs both on the same catalog, prices,
# names, icons, enabled list and MODELS_HIDDEN and compares the lines byte for byte, and the return status.
. "$STACK_DIR/lib/commands.sh"
. "$STACK_DIR/lib/owui.sh"
. "$STACK_DIR/tests/fixtures/owui_models_wanted_old.sh"

EN_FILE=''
_enabled_or_all() { printf '%s\n' "$EN_FILE"; }

# _id_same LABEL — old and new on the inputs as they are now: the same bytes (a trailing newline too) and status
_id_same() {
  local o n ro rn
  o="$(old_owui_models_wanted; ro=$?; printf 'x%s' "$ro")"
  n="$(_owui_models_wanted; rn=$?; printf 'x%s' "$rn")"
  [ "$o" = "$n" ] && return 0
  printf '%s: old and new differ\n' "$1" >&2
  diff <(printf '%s\n' "$o") <(printf '%s\n' "$n") | cut -c1-200 >&2
  return 1
}

_real() {
  CATALOG="$STACK_DIR/catalog/models.tsv"; PRICES="$STACK_DIR/catalog/prices.tsv"
  DISPLAY_CATALOG="$STACK_DIR/catalog/display.tsv"; ICONS_DIR="$STACK_DIR/catalog/icons"
}

test_the_shipped_catalog_gives_the_same_list() {
  _real; : > "$ENV_FILE"
  _id_same "every model" || return 1
  [ "$(_owui_models_wanted | wc -l | tr -d ' ')" -gt 10 ]
  catalog_rows | cut -f1 | awk 'NR % 2' > "$TMP/en"; EN_FILE="$TMP/en"
  set_env MODELS_HIDDEN "$(catalog_rows | awk -F'\t' '$2 == "chat" { print $1 }' | head -3 | paste -sd, -)"
  _id_same "every other model, three chat ones hidden" || return 1
  set_env MODELS_HIDDEN "$(catalog_rows | cut -f1 | head -1), x,,"
  _id_same "a hidden list with spaces" || return 1
}

# A catalog of the odd cases: comments, blank and CRLF lines, empty fields (a run of tabs is one field break to
# bash's read), aliases with empty parts, every price shape (both, in only, per image, per query, none, "-", text,
# numbers that sort wrong as text), names the display file lacks or gives as "-", every icon form, tags with gaps.
_odd() {
  mkdir -p "$TMP/icons"
  printf 'png-a' > "$TMP/icons/anthro.png"; printf 'png-b' > "$TMP/icons/b_2-x.png"
  CATALOG="$TMP/models.tsv"; PRICES="$TMP/prices.tsv"; DISPLAY_CATALOG="$TMP/display.tsv"; ICONS_DIR="$TMP/icons"
  {
    printf '# name\tmode\tid\taliases\n\n   \n'
    printf 'm-both\tchat\tid1\tm-a1,,m-a2,\n'
    printf 'm-in\tchat\tid2\t-\r\n'
    printf 'm-img\timage_generation\tid3\t-\n'
    printf 'm-query\trerank\tid4\t-\n'
    printf 'm-none\tchat\tid5\t\n'
    printf 'm-tabs\t\tchat\t\tid6\t\tal-x\t\textra\n'
    printf '\tm-lead\tchat\tid7\tal-y\t\n'
    printf 'm-ten\tchat\tid8\n'
    printf 'm-half\tchat\n'
    printf 'm-three\tchat\tid9\t-\textra\tmore\n'
    printf 'm-text\tchat\tid10\t-\n'
    printf 'm-exp\tchat\tid11\t-\n'
    printf 'm-big\trerank\tid12\t-\n'
    printf 'm-frac\trerank\tid13\t-\n'
    printf 'm-dup\tchat\tid14\t-\nm-dup\tembedding\tid15\tdup-al\n'
    printf 'm-only'
  } > "$CATALOG"
  {
    printf '# name\tin\tout\tcache_read\tcache_write\tper_image\tper_query\n'
    printf 'm-both\t3\t15\t0.3\t3.75\t-\t-\nm-both\t9\t9\t-\t-\t-\t-\n'
    printf 'm-in\t0.25\t-\t-\t-\t-\t-\r\n'
    printf 'm-img\t-\t-\t-\t-\t0.04\t-\n'
    printf 'm-query\t-\t-\t-\t-\t-\t0.002\n'
    printf 'm-none\t-\t-\t-\t-\t-\t-\n'
    printf 'm-tabs\t0.5\t2.5\n'
    printf 'm-lead\t2.9999\t0.00001\n'
    printf 'm-ten\t10\t40\n'
    printf 'm-half\t0.49\t1\n'
    printf 'm-three\t3\t3\n'
    printf 'm-text\tabc\t1\n'
    printf 'm-exp\t1e-3\t2E1\n'
    printf 'm-big\t-\t-\t-\t-\t-\t1000\n'
    printf 'm-frac\t-\t-\t-\t-\t-\t0.0123456789\n'
    printf '# m-only\t1\t1\n'
  } > "$PRICES"
  {
    printf '# name\tdisplay\ticon\ttags\n'
    printf 'm-both\tBoth Model\tanthro\tFast,,Vision,\r\nm-both\tSecond Row\tb_2-x\tNo\n'
    printf 'm-in\t-\tb_2-x\t-\n'
    printf 'm-img\tImage One\tdata:image/png;base64,QUJD\tImages\n'
    printf 'm-query\tQuery One\thttps://example.test/q.png\n'
    printf 'm-none\tNone One\t/static/n.png\t\n'
    printf 'm-tabs\tTabs\tAnthro\tUpper\n'
    printf 'm-lead\tLead\tbad name\t a , b \n'
    printf 'm-ten\tTen\tmissing-icon\n'
    printf 'm-half\t\thttp://example.test/h.png\n'
    printf 'm-three\tThree\n'
    printf 'm-text\tText\tanthro\tx\n'
    printf 'm-exp\tExp\t-\t-\n'
    printf 'm-dup\tDup\tanthro\n'
    printf '# m-only\tCommented\tanthro\n'
  } > "$DISPLAY_CATALOG"
}

test_odd_catalogs_give_the_same_list() {
  _odd; : > "$ENV_FILE"
  _id_same "every odd model" || return 1
  set_env MODELS_HIDDEN 'm-both,m-in , m-tabs,m-lead,al-x,m-img'
  _id_same "hidden: some exact, some with spaces, an alias, a non-chat model" || return 1
  printf 'm-both\nm-in\r\nm-ten\nm-dup\nnot-in-catalog\nal-x\n' > "$TMP/en"; EN_FILE="$TMP/en"
  _id_same "an enabled list (one CRLF line, one alias, one unknown)" || return 1
  printf 'm-three' > "$TMP/en"
  _id_same "an enabled list without a final newline" || return 1
  EN_FILE=''
  # (the files missing, one at a time; the catalog itself missing or empty: no lines, status 0)
  local p="$PRICES" d="$DISPLAY_CATALOG" i="$ICONS_DIR" c="$CATALOG"
  PRICES="$TMP/no-prices"; _id_same "no prices file" || return 1; PRICES="$p"
  DISPLAY_CATALOG="$TMP/no-display"; _id_same "no display file" || return 1; DISPLAY_CATALOG="$d"
  ICONS_DIR="$TMP/no-icons"; _id_same "no icons folder" || return 1; ICONS_DIR="$i"
  CATALOG="$TMP/no-catalog"; _id_same "no catalog" || return 1
  printf '# only a comment\n' > "$TMP/empty.tsv"; CATALOG="$TMP/empty.tsv"; _id_same "an empty catalog" || return 1
  CATALOG="$c"
  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$PRICES" "$DISPLAY_CATALOG"; _id_same "unreadable prices and names" || { chmod 644 "$PRICES" "$DISPLAY_CATALOG"; return 1; }
    chmod 644 "$PRICES" "$DISPLAY_CATALOG"
  fi
}

test_the_price_tiers_compare_as_numbers() {
  # (a price of 10 is "$$$": compared as text, "10" < "3" and it would be "$$")
  _odd; : > "$ENV_FILE"
  assert_contains "$(_owui_models_wanted | awk -F'\t' '$1 == "m-ten" { print $2 }')" 'Ten · $$$'
  assert_contains "$(_owui_models_wanted | awk -F'\t' '$1 == "m-half" { print $2 }')" '· $'
  assert_eq "$(_owui_models_wanted | awk -F'\t' '$1 == "m-big" { print $4 }')" 'AWS Bedrock · $1000000.00 per 1K queries'
}

test_the_list_asks_once_per_icon_not_once_per_model() {
  # (per model, the helpers ran a dozen small programs: 80 ms a model; now one awk writes the lines and openssl runs
  # once for each icon the lines name)
  _real; : > "$ENV_FILE"
  local calls="$TMP/calls" fn
  for fn in price_label owui_model_name display_name owui_tags_json icon_url display_field price_field model_tier money; do
    eval "$fn() { echo $fn >> \"$calls\"; }"
  done
  openssl() { echo openssl >> "$calls"; command openssl "$@"; }
  : > "$calls"
  _owui_models_wanted > "$TMP/out"
  assert_eq "$(grep -cv '^openssl$' "$calls")" 0
  local icons
  icons="$(awk -F'\t' '$7 != "" { print $7 }' "$TMP/out" | sort -u | wc -l | tr -d ' ')"
  [ "$icons" -gt 0 ] && [ "$(grep -c '^openssl$' "$calls")" -le "$icons" ]
  [ "$(wc -l < "$TMP/out" | tr -d ' ')" -gt "$icons" ]
}
