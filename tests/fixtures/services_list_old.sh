# shellcheck shell=bash
# The services list's helpers as they were in v0.68.10, as old_*: tests/test_services_list_identity.sh runs these and
# today's on the same inputs and compares their output and status (JON-972).
old_optional_services() {
  local out='' x
  for x in "$(stt_services)" "$(old_terminal_services)" "$(old_code_services)" "$(websearch_builtin_services)" "$(localgit_services)" "$(old_runtime_services)"; do [ -z "$x" ] || out="$out${out:+ }$x"; done
  printf '%s\n' "$out"
}
old_terminal_ready() {
  local ws; ws="$(get_env TERMINAL_WORKSPACE)"
  terminal_on && [ -n "$ws" ] && [ -d "$ws" ] && old_terminal_workspace_check_v06810 "$ws" >/dev/null
}
old_terminal_services() {
  old_terminal_ready || return 0
  if [ "$(terminal_egress_mode)" = internet ]; then echo "terminal-egress terminal-gateway terminal"; else echo "terminal-gateway terminal"; fi
}
old_code_ready() { code_on && old_terminal_ready; }
old_code_services() {
  old_code_ready || return 0
  if declare -F chat_proxy_wanted >/dev/null && chat_proxy_wanted; then echo "code subs-chat chat-egress"; else echo "code subs-chat"; fi
}
old_runtime_services() { local id out=''; for id in $RUNTIME_IDS; do ! rt_compose_on "$id" || out="$out${out:+ }$(rt_services "$id")"; done; printf '%s\n' "$out"; }
old_phys() { (cd "$1" 2>/dev/null && /bin/pwd -P) || true; }
old_project_name() { local p; p="$(get_env COMPOSE_PROJECT_NAME)"; printf '%s\n' "${p:-$DEFAULT_PROJECT}"; }
# (the folder check of v0.68.10, with its _phys as it was)
old_terminal_workspace_check_v06810() {
  local real r h s p t lmd lib
  [ -n "$_FOLD_OS" ] || _FOLD_OS="$(uname -s)"   # (once here: a check run in $( ) would ask again at each fold)
  case "$1" in *:* | *,*) echo "its path contains ':' or ',' (Docker cannot mount that)"; return 1 ;; esac
  real="$(old_phys "$1")"
  [ -n "$real" ] || { echo "cannot open it"; return 1; }
  if p="$(env_value_problem "$real")"; then echo "its path $p"; return 1; fi
  _fold_into r "$real"; _fold_into h "$(old_phys "$HOME")"; _fold_into s "$(old_phys "$STACK_DIR")"
  case "$r/" in "$s/"*) echo "it is this $PRODUCT_NAME folder or inside it"; return 1 ;; esac
  case "$s/" in "$r/"*) echo "it contains this $PRODUCT_NAME folder (and its .env)"; return 1 ;; esac
  if [ -n "$h" ]; then
    case "$h/" in "$r/"*) echo "it is your home folder or a folder around it — pick a folder inside it"; return 1 ;; esac
    case "$r" in "$h"/.*) echo "it is a hidden folder of your home folder (keys and settings live there)"; return 1 ;; esac
    _fold_into lmd "$h/Library/Mobile Documents"; _fold_into lib "$h/Library"
    case "$r" in
      "$lmd" | "$lmd"/*) ;;
      "$lib" | "$lib"/*) echo "it is in ~/Library (keychains, app data and settings live there)"; return 1 ;;
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
    t="$(old_phys "$t")"; [ -z "$t" ] || { _fold_into t "$t"; [ "$r" != "$t" ]; } || p=x
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
    _fold_into t "$p"; [ "$r" != "$t" ] || { echo "it holds every mounted disk ($p) — pick a folder on one of them"; return 1; }
  done
  for p in /bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /proc /root /run /sbin /snap /srv/docker /sys /usr /var \
           /private /System /Library /Applications /cores /opt/homebrew; do
    _fold_into p "$p"
    case "$r" in "$p" | "$p"/*) echo "it is a system folder ($p)"; return 1 ;; esac
  done
  [ "$r" != / ] || { echo "it is the root of the disk"; return 1; }
  printf '%s\n' "$real"
}
