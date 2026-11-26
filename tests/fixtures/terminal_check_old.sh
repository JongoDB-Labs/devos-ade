# shellcheck shell=bash
# shellcheck disable=SC2329  # (called by tests/test_fold_identity.sh)
# terminal_workspace_check, _fold and _json_str as they were before JON-972 cut their subshells (v0.68.9), renamed old_*, for
# tests/test_fold_identity.sh: the new ones must answer every path the same way.
old_fold() { if [ "$(uname -s)" = Darwin ]; then printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; else printf '%s\n' "$1"; fi; }
old_terminal_workspace_check() {
  local real r h s p t
  case "$1" in *:* | *,*) echo "its path contains ':' or ',' (Docker cannot mount that)"; return 1 ;; esac
  real="$(_phys "$1")"
  [ -n "$real" ] || { echo "cannot open it"; return 1; }
  if p="$(env_value_problem "$real")"; then echo "its path $p"; return 1; fi
  r="$(old_fold "$real")"; h="$(old_fold "$(_phys "$HOME")")"; s="$(old_fold "$(_phys "$STACK_DIR")")"
  case "$r/" in "$s/"*) echo "it is this $PRODUCT_NAME folder or inside it"; return 1 ;; esac
  case "$s/" in "$r/"*) echo "it contains this $PRODUCT_NAME folder (and its .env)"; return 1 ;; esac
  if [ -n "$h" ]; then
    case "$h/" in "$r/"*) echo "it is your home folder or a folder around it — pick a folder inside it"; return 1 ;; esac
    case "$r" in "$h"/.*) echo "it is a hidden folder of your home folder (keys and settings live there)"; return 1 ;; esac
    case "$r" in
      "$(old_fold "$h/Library/Mobile Documents")" | "$(old_fold "$h/Library/Mobile Documents")"/*) ;;
      "$(old_fold "$h/Library")" | "$(old_fold "$h/Library")"/*) echo "it is in ~/Library (keychains, app data and settings live there)"; return 1 ;;
    esac
  fi
  # a temporary folder itself (macOS's per-user ones are /private/var/folders/<xx>/<id>/T and …/C: those and every
  # folder above them), never a folder of yours in one
  p="${r#/private/var/folders}"; p="${p//[!\/]/}"
  case "$r" in
    /tmp | /var/tmp | /private/tmp | /private/var/tmp | /dev/shm | /private/var/folders) p=x ;;
    /private/var/folders/*) [ "${#p}" -ge 4 ] || p=x ;;
  esac
  # (and each as it resolves: a Linux /tmp may be a link to a folder elsewhere)
  for t in /tmp /var/tmp /dev/shm ${XDG_RUNTIME_DIR:+"$XDG_RUNTIME_DIR"}; do
    t="$(_phys "$t")"; [ -z "$t" ] || [ "$r" != "$(old_fold "$t")" ] || p=x
  done
  if [ "$p" = x ]; then
    echo "it is a temporary folder itself: programs of this computer keep their sockets there — pick a folder of your own in it, or elsewhere"; return 1
  fi
  if p="$(socket_dir_component "$real")"; then
    echo "its path goes through $p, a folder where programs of this computer keep their sockets (a way to run commands on it)"; return 1
  fi
  case "$r" in /tmp/* | /var/tmp/* | /private/tmp/* | /private/var/tmp/* | /private/var/folders/*) printf '%s\n' "$real"; return 0 ;; esac
  # where other disks are mounted: the folder itself shows them all (a folder on one of them is fine)
  for p in /Volumes /mnt /media; do
    [ "$r" != "$(old_fold "$p")" ] || { echo "it holds every mounted disk ($p) — pick a folder on one of them"; return 1; }
  done
  for p in /bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /proc /root /run /sbin /snap /srv/docker /sys /usr /var \
           /private /System /Library /Applications /cores /opt/homebrew; do
    p="$(old_fold "$p")"
    case "$r" in "$p" | "$p"/*) echo "it is a system folder ($p)"; return 1 ;; esac
  done
  [ "$r" != / ] || { echo "it is the root of the disk"; return 1; }
  printf '%s\n' "$real"
}

# _json_str as it was before its plain-text fast path (v0.68.9)
old_json_str() {
  local t
  t="$(printf '%s' "$1" | tr -d '"\\' | tr -d '\000-\037' | head -c 300 || true)"
  printf '%s' "$t" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || printf '%s' "$t" | LC_ALL=C tr -cd '\040-\176'
}
