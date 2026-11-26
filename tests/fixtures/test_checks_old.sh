# shellcheck shell=bash
# _test_checks as it was in v0.68.12 (7382247f), the groups one after the other, as old_test_checks: tests/test_smoke_groups.sh
# compares the side-by-side groups with it (JON-972). Generated: git show 7382247f:lib/commands.sh
old_test_checks() {
  local tmp lp mp code haiku opus sk alias envk k
  tmp="$(mktemp)"; lp="$(get_env LITELLM_PORT)"; mp="$(get_env SHARED_MCP_PORT)"
  haiku="$(get_env CLAUDE_BEDROCK_HAIKU_MODEL)"; opus="$(get_env CLAUDE_BEDROCK_OPUS_MODEL)"
  sk="$(get_env LITELLM_KEY_SETUP)"

  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$lp/health/liveliness" || true)"
  _check "litellm alive" "$code" 200
  # Free: every virtual key is checked with /key/info. Paid (~$0.0001): the calls below use the setup key only.
  for alias in claude-code open-webui setup $([ -z "$(get_env LITELLM_KEY_TERMINAL)" ] || echo claude-code-terminal); do
    case "$alias" in claude-code) envk=LITELLM_KEY_CLAUDE_CODE ;; open-webui) envk=LITELLM_KEY_OPENWEBUI ;; claude-code-terminal) envk=LITELLM_KEY_TERMINAL ;; *) envk=LITELLM_KEY_SETUP ;; esac
    k="$(get_env "$envk")"
    if [ -n "$k" ]; then code="$(litellm_key_status "$k")"; else code=missing; fi
    _check "LiteLLM key '$alias' is valid" "$code" 200
  done
  if [ -n "$haiku" ] && [ -n "$sk" ]; then
    code="$(curl_auth "$sk" -s -m 120 -o "$tmp" -w '%{http_code}' -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d "{\"model\":\"$haiku\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" "http://127.0.0.1:$lp/v1/messages" || true)"
    _check "anthropic /v1/messages ($haiku)" "$code" 200
    code="$(curl_auth "$sk" -s -m 120 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
      -d "{\"model\":\"$haiku\",\"max_tokens\":5,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" "http://127.0.0.1:$lp/v1/messages" || true)"
    _check "anthropic streaming" "$code" 200
  elif [ -z "$haiku" ]; then
    _skip "anthropic /v1/messages" "no Claude model enabled"
  else
    _skip "anthropic /v1/messages" "no setup key — run ./stack setup"
  fi
  if [ -n "$(get_env OWUI_EMBED_MODEL)" ] && [ -n "$sk" ]; then
    code="$(curl_auth "$sk" -s -m 120 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
      -d "{\"model\":\"$(get_env OWUI_EMBED_MODEL)\",\"input\":\"ping\"}" "http://127.0.0.1:$lp/v1/embeddings" || true)"
    _check "embeddings ($(get_env OWUI_EMBED_MODEL))" "$code" 200
  elif [ -z "$(get_env OWUI_EMBED_MODEL)" ]; then
    _skip "embeddings" "no embedding model enabled"
  else
    _skip "embeddings" "no setup key — run ./stack setup"
  fi
  _test_portal
  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$mp/healthz" || true)"
  _check "shared-mcp health" "$code" 200
  code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$mp/mcp" || true)"
  _check "shared-mcp rejects no token" "$code" 401
  code="$(curl_auth "$(get_env SHARED_MCP_TOKEN)" -s -m 30 -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "http://127.0.0.1:$mp/mcp" 2>/dev/null | grep -o '"search_knowledge"' | head -n1 || true)"
  _check "shared-mcp lists tools" "$code" '"search_knowledge"'
  stt_test_checks   # lib/stt.sh: Bedrock speech-to-text, when on (~$0.00005)
  terminal_test_checks   # lib/terminal.sh: the browser terminal's checks, when on (no Bedrock calls)
  projects_test_checks   # lib/projects.sh: the sandbox sees each project folder, read-only where chosen
  code_test_checks       # lib/code.sh: the Code page's checks, when on (no Bedrock calls)
  rm -f "$tmp"
}
