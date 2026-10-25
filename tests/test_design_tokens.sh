# shellcheck shell=bash
# The design tokens (docs/design.md): one file with two copies, because the portal and the Code page are built from
# separate Docker contexts. The copies, their fonts and the fonts' licences must stay identical, and no page may load a
# font or style sheet from another origin.

P="portal/portal/static"
C="code/web/src/styles"

test_the_portal_and_the_code_page_share_one_token_file() {
  cmp -s "$T_ROOT/$P/tokens.css" "$T_ROOT/$C/tokens.css" || { diff "$T_ROOT/$P/tokens.css" "$T_ROOT/$C/tokens.css" >&2; return 1; }
  cmp -s "$T_ROOT/$P/fonts.css" "$T_ROOT/$C/fonts.css" || { diff "$T_ROOT/$P/fonts.css" "$T_ROOT/$C/fonts.css" >&2; return 1; }
}

test_both_copies_carry_the_same_fonts_and_licences() {
  local f n=0
  for f in source-serif-4-latin-wght-normal.woff2 inter-latin-wght-normal.woff2 jetbrains-mono-latin-wght-normal.woff2 \
           LICENSE-source-serif-4.txt LICENSE-inter.txt LICENSE-jetbrains-mono.txt; do
    [ -s "$T_ROOT/$P/fonts/$f" ] || { echo "missing $P/fonts/$f" >&2; return 1; }
    cmp -s "$T_ROOT/$P/fonts/$f" "$T_ROOT/$C/fonts/$f" || { echo "$P/fonts/$f and $C/fonts/$f differ" >&2; return 1; }
    n=$((n + 1))
  done
  assert_eq "$n" 6
  for f in "$T_ROOT/$P"/fonts/LICENSE-*.txt; do
    assert_contains "$(cat "$f")" "SIL OPEN FONT LICENSE Version 1.1"
  done
  # every font fonts.css names is there, and nothing else is
  for f in $(sed -n 's/.*url("fonts\/\([^"]*\)").*/\1/p' "$T_ROOT/$P/fonts.css"); do
    [ -s "$T_ROOT/$P/fonts/$f" ] || { echo "fonts.css names fonts/$f, which is missing" >&2; return 1; }
  done
  assert_eq "$(ls "$T_ROOT/$P/fonts" | grep -c '\.woff2$')" 3
}

test_the_light_and_dark_token_sets_name_the_same_tokens() {
  # every token the dark theme sets is a light token too, and the two dark blocks (system dark, data-theme dark) agree
  local f="$T_ROOT/$P/tokens.css" light media forced
  light="$(awk '/^:root \{/,/^\}/' "$f" | sed -n 's/^ *\(--[a-z0-9-]*\):.*/\1/p' | sort)"
  media="$(awk '/^@media \(prefers-color-scheme: dark\)/,/^\}/' "$f" | sed -n 's/^ *\(--[a-z0-9-]*\): *\(.*\);/\1 \2/p')"
  forced="$(awk '/^:root\[data-theme="dark"\] \{/,/^\}/' "$f" | sed -n 's/^ *\(--[a-z0-9-]*\): *\(.*\);/\1 \2/p')"
  [ -n "$media" ] || { echo "no dark tokens" >&2; return 1; }
  assert_eq "$media" "$forced"
  local t
  for t in $(printf '%s\n' "$media" | cut -d' ' -f1); do
    printf '%s\n' "$light" | grep -qx -- "$t" || { echo "dark-only token $t" >&2; return 1; }
  done
}

test_the_style_sheets_load_nothing_from_another_origin() {
  local hits
  hits="$(grep -nE '(@import|url\()[^)]*(https?:)?//' "$T_ROOT/$P"/*.css "$T_ROOT/$C"/*.css 2>/dev/null || true)"
  assert_eq "$hits" ""
  hits="$(grep -nE '<link[^>]+href="https?://' "$T_ROOT/$P"/*.html 2>/dev/null || true)"
  assert_eq "$hits" ""
}
