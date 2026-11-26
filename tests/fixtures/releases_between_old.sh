# shellcheck shell=bash
# releases_between as it was in v0.68.17 (e5c4d6f3), a version_newer for each release tag, as old_releases_between:
# tests/test_update_git.sh compares the one-pass filter with it (JON-972). Generated: git show e5c4d6f3:lib/commands.sh
old_releases_between() {
  local from cur t subj n=0 more=0
  [ -e "$STACK_DIR/.git" ] && [ -n "${1:-}" ] || return 0
  from="$(_git describe --tags --abbrev=0 "$1" 2>/dev/null || true)"; cur="$(installed_version)"
  _semver "$from" >/dev/null 2>&1 && _semver "$cur" >/dev/null 2>&1 || return 0
  for t in $(newest_release_tags); do
    version_newer "$t" "$from" || continue
    ! version_newer "$t" "$cur" || continue
    n=$((n + 1)); [ "$n" -le 10 ] || { more=$((more + 1)); continue; }
    subj="$(_git for-each-ref --format='%(objecttype) %(contents:subject)' "refs/tags/$t" 2>/dev/null | sed -n 's/^tag //p' | head -n 1 | tr -d '\000-\037')"
    # at most 120 characters, cut at a word (never inside a word, nor inside a character where bash counts bytes)
    [ "${#subj}" -le 120 ] || { subj="${subj:0:119}"; subj="${subj% *}"; subj="${subj%[,;:]} …"; }
    case "$subj" in "$t"*) printf '%s\n' "$subj" ;; '') printf '%s\n' "$t" ;; *) printf '%s — %s\n' "$t" "$subj" ;; esac
  done
  [ "$more" = 0 ] || printf '… and %s older\n' "$more"
}
