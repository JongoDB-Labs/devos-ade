# shellcheck shell=bash
# shellcheck disable=SC2120,SC2154  # the old functions as they were
# dc (lib/common.sh) and the helpers it called, as they were at v0.68.6 (aa9321ba), before JON-972 made each dc call
# quicker; every one renamed old_<name>, and the calls among them too. tests/test_dc_identity.sh runs old_dc beside
# dc on the same settings and files and compares what docker is given: its arguments and its environment. Do not edit.

# (lib/common.sh:352)
old_dc() {
  local p; p="$(project_name)"
  old_localgit_sso_ensure 2>/dev/null || true
  if [ -n "${COMPOSE_PROJECT_NAME:-}" ] && [ "$COMPOSE_PROJECT_NAME" != "$p" ] && [ -z "${_DC_PROJECT_WARNED:-}" ]; then
    warn "COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME in your shell is ignored: this checkout is project '$p' (from .env or the default)"
    _DC_PROJECT_WARNED=1
  fi
  if [ "${1:-}" = ps ] && [ "${DEVOS_ADE_PS_VIA_COMPOSE:-0}" != 1 ] && _dc_ps_form "$@"; then _dc_ps_fast "$p" "$@"; return; fi
  # Compose lets shell variables beat --env-file: OpenRouter, Experiential Labs, speech-to-text and the search keys are
  # opt-in via .env only, so an OPENROUTER_*, EXPLABS_*, STT_* or WEBSEARCH_* in your shell never switches them on (or
  # keeps them on after a remove).
  # (A subshell, not `env -u`: same effect on docker's environment, and tests can still stub docker.)
  # The same for AWS: .env decides the key (or none, with AWS_AUTH=instance-role) and the region, never the shell
  # (./stack warns once per command when your shell's key differs: warn_shell_aws_ignored in lib/host.sh).
  local f=() o
  # the portal's docs index (compose.portal-docs.yaml): only where this Docker Compose reads additional_contexts
  if compose_reads_contexts; then f+=(-f "$STACK_DIR/compose.portal-docs.yaml"); fi
  for o in $(old_compose_overlays); do
    case "$o" in @projects) f+=(-f "$STATE_DIR/projects/compose.yaml") ;; *) f+=(-f "$STACK_DIR/$o") ;; esac
  done
  # The Code page's container mounts the project folders' public list (compose.code.yaml: the folder, read-only, never
  # created by Docker): there before compose needs it (lib/projects.sh writes its roots.json)
  if old_flag_on "$(get_env CODE_ENABLED)"; then mkdir -p "$STATE_DIR/projects/public" 2>/dev/null && chmod 700 "$STATE_DIR/projects" 2>/dev/null || true; fi
  # Bedrock speech-to-text: its container is in the "stt" profile (lib/stt.sh), so down/ps/logs include it too.
  if [ "${_STT_PROFILE:-}" = 1 ] || [ "$(get_env STT_PROVIDER)" = bedrock ]; then f+=(--profile stt); fi
  # The built-in SearXNG (lib/websearch.sh): in the "searxng" profile, on unless WEBSEARCH_SEARXNG_BUILTIN=off
  if [ "${_WS_SEARXNG_PROFILE:-}" = 1 ] || ! old_flag_off "$(get_env WEBSEARCH_SEARXNG_BUILTIN)"; then f+=(--profile searxng); fi
  # The built-in git server, Forgejo (lib/localgit.sh): in the "forgejo" profile, on unless LOCALGIT=off
  if [ "${_LG_PROFILE:-}" = 1 ] || ! old_flag_off "$(get_env LOCALGIT)"; then f+=(--profile forgejo); fi
  # The runtimes as containers (lib/runtimes.sh, Linux): each in its own profile while this stack installed it
  if declare -F old_runtime_profiles >/dev/null; then local rp; for rp in $(old_runtime_profiles); do f+=(--profile "$rp"); done; fi
  # the checksums of the configuration files the services read only at their start (old_config_sums, below): every compose
  # call passes the same ones, so none recreates a service whose files did not change, and each recreates one whose did
  local policy sums; policy="$(old_claude_policy)"; sums="$(old_config_sums "$policy")"
  # The browser terminal too: an exported TERMINAL_WORKSPACE must never decide what the container sees.
  ( unset OPENROUTER_API_KEY OPENROUTER_MODELS OPENROUTER_MAX_MODELS EXPLABS_API_KEY EXPLABS_MODELS STT_PROVIDER STT_API_KEY STT_MODEL OWUI_STT_ENGINE \
      WEBSEARCH_TAVILY_API_KEY WEBSEARCH_BRAVE_API_KEY WEBSEARCH_PERPLEXITY_API_KEY WEBSEARCH_SEARXNG_SECRET WEBSEARCH_SEARXNG_BUILTIN \
      LOCALGIT LOCALGIT_ADMIN_PASSWORD LOCALGIT_READ_TOKEN LOCALGIT_INDEXER LOCALGIT_SSO_HEADER LOCALGIT_SSO_ON LOCALGIT_MIRROR_EGRESS LOCALGIT_MIRROR_HOSTS GIT_HOST GIT_ORIGIN BN_LOCALGIT_MODE BN_LOCALGIT_TLS BN_LEGACY_HOSTS \
      OWUI_STT_BASE_URL STT_BEDROCK_MODEL COMPOSE_PROFILES \
      AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION_NAME \
      PORTAL_HTTPS TERMINAL_ENABLED TERMINAL_WORKSPACE TERMINAL_EGRESS TERMINAL_EGRESS_ALLOW TERMINAL_EGRESS_DENY TERMINAL_HOST TERMINAL_UID TERMINAL_GID TERMINAL_MEM_LIMIT \
      REMOTE_TERMINAL REMOTE_TERMINAL_HOST CODE_ENABLED CODE_HOST CODE_PROXY_SECRET REMOTE_CODE_HOST PREVIEW_DOMAIN PREVIEW_PROXY_SECRET CODE_ALLOW_BYPASS \
      CODE_AUTO_MODE TERMINAL_AUTO_MODE GIT_GITHUB_CLIENT_ID GIT_GITHUB_APP_SLUG GIT_GITLAB_CLIENT_ID CODE_CLAUDE_PLAN CODE_CHAT_KEY
    # (and the BN_*_SUM of old_config_sums: only ./stack sets them, never this shell)
    while IFS='=' read -r o p_sum; do [ -z "$o" ] || export "$o=$p_sum"; done <<SUMS
$sums
SUMS
    # Builds without the default provenance attestation (unless your shell says otherwise): with Docker's containerd image
    # store it carries the build's time, so a build all from the cache gave a new image ID — and compose recreated that
    # service, and every step that reads the images ran again, on every update. Images built here are never pushed.
    # which of terminal/managed/*.json the sandbox gets as Claude Code's managed settings (read-only): from .env alone
    TERMINAL_CLAUDE_POLICY="$policy" BN_PROJECTS_PUBLIC="$STATE_DIR/projects/public" \
    LOCALGIT_SSO_HEADER="$(get_env LOCALGIT_SSO_HEADER)" LOCALGIT_SSO_ON="$([ -n "$(get_env LOCALGIT_SSO_HEADER)" ] && echo true || echo false)" \
    BN_TLS_SERVE="$STATE_DIR/tls/serve" BN_LOCAL_SCHEME="$(old_flag_on "$(get_env PORTAL_HTTPS)" && echo https || echo http)" \
    BN_LOCALGIT_TLS="$STATE_DIR/localgit/tls" BN_LOCALGIT_MODE="$(old_flag_off "$(get_env LOCALGIT)" && echo off || echo on)" BN_LEGACY_HOSTS="$(old_legacy_hosts_mode)" \
    BN_LLAMACPP_DIR="$STATE_DIR/runtimes/llamacpp" BN_LLAMACPP_USER="$(cat "$STATE_DIR/runtimes/llamacpp/user" 2>/dev/null || echo 65534:65534)" \
    BN_VLLM_DIR="$STATE_DIR/runtimes/vllm" BN_VLLM_USER="$(cat "$STATE_DIR/runtimes/vllm/user" 2>/dev/null || echo 65534:65534)" \
    BUILDX_NO_DEFAULT_ATTESTATIONS="${BUILDX_NO_DEFAULT_ATTESTATIONS:-1}" \
    DEVOS_ADE_ENV_DISPLAY="$(env_file_display)" COMPOSE_PROJECT_NAME="$p" docker compose -p "$p" --project-directory "$STACK_DIR" -f "$STACK_DIR/compose.yaml" ${f[@]+"${f[@]}"} \
      --env-file "$ENV_FILE" "$@" )
}
# (lib/common.sh:771)
old_compose_overlays() {
  if [ "${REMOTE_DEGRADED:-0}" != 1 ]; then   # remote network unusable this run (lib/remote.sh remote_net_preflight)
    case "$(get_env REMOTE_MODE)" in
      tailscale) echo compose.tailscale.yaml ;;
      domain) echo compose.tailscale.yaml compose.domain.yaml ;;
    esac
  fi
  # (Without a folder in TERMINAL_WORKSPACE compose could not even read that file: it is left out, and ./stack up
  # says why — lib/terminal.sh terminal_up_hook.)
  if old_flag_on "$(get_env TERMINAL_ENABLED)" && [ -n "$(get_env TERMINAL_WORKSPACE)" ]; then
    echo compose.terminal.yaml
    # the project folders of this computer (lib/projects.sh generates it while there are any): @projects is
    # .state/projects/compose.yaml for old_dc (a word: a checkout's path may have spaces)
    [ ! -f "$STATE_DIR/projects/compose.yaml" ] || echo @projects
    case "$(old_egress_mode "$(get_env TERMINAL_EGRESS)")" in
      internet) echo compose.terminal-proxy.yaml ;;
      host) echo compose.terminal-egress.yaml ;;
    esac
    # the built-in git server as the sandbox's git host: the gateway's TLS listener (lib/localgit.sh)
    ! old_localgit_overlay_wanted || echo compose.localgit.yaml
    if old_flag_on "$(get_env CODE_ENABLED)"; then
      echo compose.code.yaml
      # (Chat's sandbox's way out: the terminal's proxy; with the direct one, a proxy of its own; none with none —
      # compose.code.yaml subs-chat)
      case "$(old_egress_mode "$(get_env TERMINAL_EGRESS)")" in
        internet) echo compose.code-proxy.yaml ;;
        host) echo compose.code-egress.yaml ;;
        *) echo compose.code-offline.yaml ;;
      esac
    fi
  fi
  # the portal over HTTPS (lib/tls.sh): Caddy's certificate, once ./stack https on made it
  ! declare -F https_overlay_wanted >/dev/null || ! https_overlay_wanted || echo compose.https.yaml
  # (independent of the terminal: the git server alone, while it has a mirror)
  ! localgit_mirror_wanted || echo compose.localgit-mirror.yaml
  # the runtimes' GPUs (lib/runtimes.sh: Ollama's, llama.cpp's and vLLM's containers with the NVIDIA runtime)
  ! declare -F old_runtime_overlays >/dev/null || old_runtime_overlays
  return 0
}
# (lib/common.sh:847)
old_claude_policy() {
  if old_flag_on "$(get_env TERMINAL_AUTO_MODE)"; then echo on
  elif old_flag_on "$(get_env CODE_AUTO_MODE)"; then echo code-auto
  else echo off; fi
}
# (lib/common.sh:497)
old_config_sums() {
  local policy="${1:-}" c=() g
  [ -n "$policy" ] || policy="$(old_claude_policy)"
  for g in "$STACK_DIR"/caddy/*.caddy; do case "${g##*/}" in terminal-gateway.caddy | localgit-gateway-*.caddy | ollama-gate.caddy) ;; *) c+=("${g##*/}") ;; esac; done
  printf 'BN_LITELLM_CONFIG_SUM=%s\n' "$(old_litellm_compose_sum)"
  printf 'BN_TLS_SUM=%s\n' "$(old_files_sum "$STATE_DIR/tls/serve" site.pem)"
  printf 'BN_CADDY_CONFIG_SUM=%s\n' "$(old_files_sum "$STACK_DIR/caddy" Caddyfile ${c[@]+"${c[@]}"})"
  printf 'BN_GATEWAY_CONFIG_SUM=%s\n' "$(old_files_sum "$STACK_DIR/caddy" terminal-gateway.caddy localgit-gateway-on.caddy localgit-gateway-off.caddy)"
  printf 'BN_OLLAMA_GATE_CONFIG_SUM=%s\n' "$(old_files_sum "$STACK_DIR/caddy" ollama-gate.caddy)"
  # (as v0.31.0 gave it: the checksum alone, so an update to this version leaves an unchanged SearXNG running)
  g=''; [ ! -f "$STACK_DIR/searxng/settings.yml" ] || g="$(cksum < "$STACK_DIR/searxng/settings.yml" | awk '{ print $1 }')"
  printf 'BN_SEARXNG_SETTINGS_SUM=%s\n' "$g"
  printf 'BN_TERMINAL_POLICY_SUM=%s\n' "$(old_files_sum "$STACK_DIR/terminal/managed" "$policy.json")"
  printf 'BN_CHAT_POLICY_SUM=%s\n' "$(old_files_sum "$STACK_DIR/terminal/managed" chat.json)"
}
# (lib/common.sh:528)
old_files_sum() {
  local d="$1" n=() x
  shift
  for x in "$@"; do [ ! -f "$d/$x" ] || n+=("$x"); done
  [ ${#n[@]} -gt 0 ] || return 0
  ( cd "$d" && cksum "${n[@]}" 2>/dev/null ) | cksum | awk '{ print $1 "-" $2 }'
}
# (lib/common.sh:519)
old_litellm_compose_sum() {
  local s live='' base=''
  s="$(old_litellm_config_sum_now)"
  [ ! -r "$(litellm_live_sum_file)" ] || read -r live base < "$(litellm_live_sum_file)" 2>/dev/null || true
  if [ -n "$s" ] && [ "$live" = "$s" ] && [ -n "$base" ]; then s="$base"; fi
  printf '%s\n' "$s"
}
# (lib/common.sh:518)
old_litellm_config_sum_now() { old_files_sum "$STACK_DIR/litellm" config.yaml bn_hooks.py; }
# (lib/common.sh:814)
old_flag_on() { case "$(_flag "$1")" in true | 1 | yes | on) return 0 ;; esac; return 1; }
# (lib/common.sh:825)
old_flag_off() { case "$(_flag "$1")" in false | 0 | no | off) return 0 ;; esac; return 1; }
# (lib/common.sh:832)
old_egress_mode() {
  case "$(_flag "$1")" in
    host) echo host ;;
    false | 0 | no | off) echo off ;;
    *) echo internet ;;
  esac
}
# (lib/runtimes.sh:364)
old_runtime_profiles() { local id; for id in $RUNTIME_IDS; do ! { old_rt_compose_on "$id" || [ "${_RT_PROFILE:-}" = "$id" ]; } || echo "$id"; done; }
# (lib/runtimes.sh:366)
old_runtime_overlays() {
  local id
  for id in $RUNTIME_IDS; do
    # (also while it is being installed: its pull is of the GPU's image)
    { old_rt_compose_on "$id" || [ "${_RT_PROFILE:-}" = "$id" ]; } || continue
    [ "$(cat "$(rt_dir "$id")/gpu" 2>/dev/null)" != nvidia ] || echo "compose.$id-gpu.yaml"
  done
}
# (lib/runtimes.sh:357)
old_rt_compose_on() { [ "$(rt_os)" = linux ] && rt_installed "$1" && { [ "$1" != vllm ] || rt_vllm_serving >/dev/null; }; }
# (lib/common.sh:714)
old_localgit_overlay_wanted() {
  old_localgit_on && old_flag_on "$(get_env TERMINAL_ENABLED)" && [ -n "$(get_env TERMINAL_WORKSPACE)" ] && localgit_tls_ensure
}
# (lib/common.sh:711)
old_localgit_on() { ! old_flag_off "$(get_env LOCALGIT)"; }
# (lib/common.sh:337)
old_localgit_sso_ensure() {
  ! old_flag_off "$(get_env LOCALGIT)" || return 0
  [ -n "$(get_env LOCALGIT_SSO_HEADER)" ] || set_env LOCALGIT_SSO_HEADER "X-Bn-Git-$(gen_hex 16)"
}
# (lib/common.sh:346)
old_legacy_hosts_mode() {
  local h p; h="$(get_env PORTAL_HOST)"; p="$(get_env PREVIEW_DOMAIN)"
  case "$h" in bedrock-now.localhost | *.bedrock-now.localhost) echo off; return ;; esac
  case "$p" in bedrock-now-preview.localhost | *.bedrock-now-preview.localhost) echo off; return ;; esac
  echo on
}
