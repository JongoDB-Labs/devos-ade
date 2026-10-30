# shellcheck shell=bash
# The e2e harness's safety rules (tests/e2e/lib.sh, report.sh, notty) with a stubbed docker: a project that is not
# the suite's own is never touched, --teardown refuses it, --reuse checks everything, paths with spaces work.
. "$STACK_DIR/tests/e2e/lib.sh"

# _fake_docker — docker as a function: answers the read-only queries from FAKE_* variables and logs every call
_fake_docker() {
  ROOT="$TMP/root"; mkdir -p "$ROOT/tests/e2e/work"
  PROJECT=bne2e; OUT="$TMP/out"; LOGS="$OUT/logs"; RESULTS="$OUT/results.tsv"; mkdir -p "$LOGS"
  STACK="${STACK:-$ROOT/tests/e2e/work/bne2e}"
  FAKE_DIRS="${FAKE_DIRS:-}"; FAKE_OWNER="${FAKE_OWNER:-}"; FAKE_VOLS="${FAKE_VOLS:-}"; FAKE_PS="${FAKE_PS:-}"
  FAKE_USERS="${FAKE_USERS:-}"; FAKE_FAIL="${FAKE_FAIL:-}"; FAKE_NETS="${FAKE_NETS:-}"
  docker() {
    printf 'docker %s\n' "$*" >> "$TMP/docker"
    case "$FAKE_FAIL" in ?*) case "$*" in "$FAKE_FAIL"*) return 1 ;; esac ;; esac
    case "$*" in
      "volume ls -q") [ -z "$FAKE_OWNER" ] || echo "bne2e_bedrock-now-owner"; echo "unrelated_volume" ;;
      "ps -a --filter label=com.docker.compose.project.working_dir="*) [ -z "$FAKE_USERS" ] || printf '%s\n' "$FAKE_USERS" ;;
      "ps -a --filter label=com.docker.compose.project=bne2e --format {{.Label \"com.docker.compose.project.working_dir\"}}")
        [ -z "$FAKE_DIRS" ] || printf '%s\n' "$FAKE_DIRS" ;;
      "volume inspect --format"*bedrock-now-owner) [ -n "$FAKE_OWNER" ] || return 1; printf '%s\n' "$FAKE_OWNER" ;;
      "volume ls -q --filter label=com.docker.compose.project=bne2e") [ -z "$FAKE_VOLS" ] || printf '%s\n' "$FAKE_VOLS" ;;
      "network ls --format {{.Name}} --filter label=com.docker.compose.project=bne2e") [ -z "$FAKE_NETS" ] || printf '%s\n' "$FAKE_NETS" ;;
      "ps -a --filter label=com.docker.compose.project=bne2e --format {{.Label \"com.docker.compose.service\"}}"*)
        [ -z "$FAKE_PS" ] || printf '%s\n' "$FAKE_PS" ;;
    esac
    return 0
  }
}
_mutating_calls() { grep -E '^docker (compose|volume rm|image rm|rm )' "$TMP/docker" 2>/dev/null || true; }

test_e2e_only_suite_project_names_are_accepted() {
  for p in bne2e bne2e-2 bne2e-dev-1; do valid_project "$p" || { echo "refused $p" >&2; return 1; }; done
  for p in bedrock-now bn-dev bne2 bne2e- bne2e--x bne2e_x Bne2e bne2e-X "" xbne2e; do
    if valid_project "$p"; then echo "accepted $p" >&2; return 1; fi
  done
}

test_e2e_foreign_project_is_refused_without_a_single_docker_change() {
  mkdir -p "$TMP/other-install"; FAKE_DIRS="$TMP/other-install"; FAKE_VOLS="bne2e_pgdata"; _fake_docker
  # what run.sh does: the EXIT trap tears down — it must not touch a project it was refused
  if out="$( (trap teardown EXIT; claim_project) 2>&1)"; then echo "claim succeeded" >&2; return 1; fi
  assert_contains "$out" "belongs to $TMP/other-install"
  assert_contains "$out" "nothing was changed"
  assert_contains "$out" "Docker left untouched"
  assert_eq "$(_mutating_calls)" ""
}

test_e2e_docker_errors_fail_closed() {
  FAKE_FAIL="ps -a"; _fake_docker
  project_ownership; assert_eq "$OWN_STATE" foreign; assert_contains "$OWN_WHY" "Docker did not answer"
  FAKE_FAIL="volume ls"; project_ownership; assert_eq "$OWN_STATE" foreign
  FAKE_FAIL="volume inspect"; FAKE_OWNER="$STACK"; project_ownership; assert_eq "$OWN_STATE" foreign
  assert_contains "$OWN_WHY" "owner marker"
  if (claim_project) 2>/dev/null; then return 1; fi
  assert_eq "$(_mutating_calls)" ""
}

test_e2e_a_marked_folder_another_project_uses_is_kept() {
  _fake_docker; mkdir -p "$STACK"; : > "$STACK/.bedrock-now-e2e"; FAKE_DIRS="$STACK"
  FAKE_USERS="$(printf 'bne2e\nbne2e-other')"
  (teardown_only) 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "containers of project(s) bne2e-other were started from it"
  [ -d "$STACK" ] || { echo "folder deleted" >&2; return 1; }
  # and when Docker cannot say which projects use it, it is kept too
  FAKE_USERS=''; FAKE_FAIL="ps -a --filter label=com.docker.compose.project.working_dir"
  OWNED=1 teardown 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "Docker cannot tell"
  [ -d "$STACK" ] || return 1
  FAKE_FAIL=''; OWNED=1 teardown 2>/dev/null
  [ ! -e "$STACK" ] || { echo "folder kept although only bne2e uses it" >&2; return 1; }
}

test_e2e_teardown_retries_networks_and_says_what_it_left() {
  _fake_docker; mkdir -p "$STACK"; : > "$STACK/.bedrock-now-e2e"
  sleep() { echo "sleep $*" >> "$TMP/docker"; }
  # a network Docker will not let go (an endpoint of a container already gone): 5 tries, a second apart, then said
  FAKE_FAIL="network rm bne2e_terminal-out"; FAKE_NETS="bne2e_terminal-out"
  OWNED=1 teardown 2> "$TMP/err"
  assert_eq "$(grep -c '^docker network rm bne2e_terminal-out$' "$TMP/docker")" 5
  assert_eq "$(grep -c '^docker network rm bne2e_terminal-link$' "$TMP/docker")" 1
  assert_eq "$(grep -c '^sleep 1$' "$TMP/docker")" 4
  assert_contains "$(cat "$TMP/err")" "teardown left something behind: bne2e_terminal-out"
  # none left: complete
  : > "$TMP/docker"; FAKE_FAIL=''; FAKE_NETS=''
  OWNED=1 teardown 2> "$TMP/err"
  assert_contains "$(cat "$TMP/err")" "teardown complete: no containers, volumes, networks or checkout of bne2e left"
}

test_e2e_unanswered_spend_is_an_error_not_zero() {
  _fake_docker
  spend_now() { echo "${FAKE_SPEND:-}"; }
  FAKE_SPEND=0.0010; spend_start; FAKE_SPEND=0.0030; spend_cut; FAKE_SPEND=0.0005; spend_resume   # a restore
  FAKE_SPEND=0.0015
  assert_eq "$(spend_total)" "0.0030"
  FAKE_SPEND=''
  if out="$(spend_total 2>&1)"; then echo "an unanswered reading gave $out" >&2; return 1; fi
  assert_contains "$out" "unanswered"
  FAKE_SPEND=''; SPEND_ERR=''; spend_start; FAKE_SPEND=0.001
  if spend_total >/dev/null 2>&1; then return 1; fi
}

# no-opus-spend: this run's spend on Claude Opus, summed around restores like the total; an unanswered reading is an
# error; any Opus spend fails unless a check that ran is declared in needs-opus.tsv; the throwaways start on Haiku
test_e2e_opus_spend_fails_the_run_unless_a_check_that_ran_declared_it() {
  _fake_docker
  spend_now() { echo 0.001; }
  opus_now() { printf '%s\n' "${FAKE_OPUS-0.000000		0.000000}"; echo "since $1" >> "$TMP/opus-calls"; }
  OPUS_ACC=0; OPUS_MODELS=''; OPUS_ERR=''; OPUS_OTHER=0
  spend_start
  [ -n "$OPUS_FROM" ] || { echo "no window started" >&2; return 1; }
  FAKE_OPUS=$'0.012000\tclaude-opus-5-5\t0.000066'; spend_cut; FAKE_OPUS=$'0.000000\t\t0.000000'; spend_resume   # a restore in between
  FAKE_OPUS=$'0.003000\tclaude-opus-5-5\t0.000000'; spend_total > /dev/null
  assert_eq "$(opus_total)" "$(printf '0.0150\tclaude-opus-5-5,claude-opus-5-5\t0.000066')"
  assert_eq "$(grep -c since "$TMP/opus-calls")" 2
  # the verdicts: none, only setup's probe (said, not counted), a session's Opus spend (undeclared, declared and ran), unknown
  assert_eq "$(no_opus_verdict "$(printf '0.0000\t\t0.000000')" '' | cut -f1)" PASS
  v="$(no_opus_verdict "$(printf '0.0000\t\t0.000066')" '')"
  assert_eq "${v%%$'\t'*}" PASS
  assert_contains "$v" "setup's model probe and ./stack test: \$0.000066 on Opus, not counted"
  v="$(no_opus_verdict "$(printf '0.0150\tclaude-opus-5-5\t0.000066')" '')"
  assert_eq "${v%%$'\t'*}" FAIL
  assert_contains "$v" '$0.0150 on Claude Opus by a session (claude-opus-5-5): no check declared it needs Opus'
  assert_contains "$(no_opus_verdict "$(printf '0.0150\tclaude-opus-5-5\t0.000000')" browser/code-x)" $'PASS\t$0.0150 on Claude Opus (claude-opus-5-5), declared by browser/code-x'
  assert_contains "$(no_opus_verdict '' '')" $'FAIL\tLiteLLM'
  FAKE_OPUS=''; OPUS_ERR=''; OPUS_FROM=1; opus_cut
  if opus_total > /dev/null 2>&1; then echo "an unanswered reading gave a total" >&2; return 1; fi
  # declared checks count only when they ran (a tag after @ is the same check)
  printf '# suite/check\twhy\nbrowser/code-x\ta reason\n' > "$TMP/needs.tsv"
  printf 'browser\tcode-y\tPASS\t1\tok\nbrowser\tcode-x\tSKIP\t0\tno\n' > "$TMP/res.tsv"
  assert_eq "$(needs_opus_ran "$TMP/needs.tsv" "$TMP/res.tsv")" ""
  printf 'browser\tcode-x@stt\tFAIL\t3\tbad\nbrowser\tcode-x\tPASS\t3\tok\n' >> "$TMP/res.tsv"
  assert_eq "$(needs_opus_ran "$TMP/needs.tsv" "$TMP/res.tsv")" "browser/code-x"
  # the suite's own list declares none; every throwaway starts its sessions on Haiku
  assert_eq "$(grep -cv '^#' "$STACK_DIR/tests/e2e/needs-opus.tsv")" 0
  for f in run.sh upgrade.sh ui-sweep.sh; do grep -q '^ *seed_cheap_default' "$STACK_DIR/tests/e2e/$f" || { echo "$f does not seed the cheap default" >&2; return 1; }; done
  case "$E2E_DEFAULT_MODEL" in claude-haiku-*) ;; *) echo "default $E2E_DEFAULT_MODEL" >&2; return 1 ;; esac
}

# opus_spend.py against a stand-in LiteLLM: the master key from the throwaway's .env in the header (never printed), the
# rows since the moment on a model or model group naming Opus, every page, counted only for a session's key — setup's
# model probe (the setup key, or the master key before it exists: one 1-token request to every model) is said, never
# counted: a probe-only Opus row passes, a session's Opus row fails
test_e2e_opus_spend_counts_sessions_keys_never_setups_probe() {
  command -v python3 >/dev/null 2>&1 || return 77
  local key term cc owui setup
  key="sk-$(printf 'e2e-master-%s' "$$")"; term="sk-$(printf 'e2e-term-%s' "$$")"; cc="sk-$(printf 'e2e-cc-%s' "$$")"
  owui="sk-$(printf 'e2e-owui-%s' "$$")"; setup="sk-$(printf 'e2e-setup-%s' "$$")"
  cat > "$TMP/fake_litellm.py" <<'PY'
import hashlib, json, signal, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
signal.alarm(20)   # (it ends by itself: its requests, or 20 s)
key, scenario = sys.argv[1], sys.argv[2]
h = lambda k: hashlib.sha256(k.encode()).hexdigest()
term, cc, owui, setup = (h(k) for k in sys.argv[3:7])
probe = [{"model": "claude-opus-5-5", "model_group": "claude-opus-5-5", "api_key": setup, "spend": 0.000066, "startTime": "2026-10-26T10:00:01Z", "completion_tokens": 1},
         {"model": "claude-opus-4-1", "api_key": h(key), "spend": 0.00005, "startTime": "2026-10-26T10:00:02Z"},
         {"model": "claude-haiku-5-5", "api_key": term, "spend": 0.004, "startTime": "2026-10-26T10:00:06+00:00"}]
session = [{"model": "bedrock/us.anthropic.claude-opus-5-5", "model_group": "claude-opus-5-5", "api_key": term, "spend": 0.02, "startTime": "2026-10-26T10:00:05.000Z"},
           {"model": "claude-opus-5-5", "api_key": owui, "spend": 0.5, "startTime": "2026-10-26T09:59:00Z"}, "junk",
           {"model": "x-opus", "api_key": cc, "spend": "NaN", "startTime": "2026-10-26T10:00:07Z"},
           {"model": "claude-opus-4-1", "metadata": {"user_api_key_alias": "claude-code"}, "spend": 0.001, "startTime": "2026-10-26T10:01:00"}]
PAGES = {1: probe, 2: session if scenario == "session" else []}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.headers.get("Authorization") != f"Bearer {key}" or not self.path.startswith("/spend/logs/v2?"):
            self.send_response(401); self.end_headers(); return
        page = int(self.path.split("page=")[1].split("&")[0])
        body = json.dumps({"data": PAGES.get(page, []), "total_pages": 2}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
for _ in range(2):   # (both pages; a refused reading ends at the first, and the test asks once more)
    srv.handle_request()
PY
  since="$(python3 -I -c 'from datetime import datetime, timezone; print(int(datetime(2026, 10, 26, 10, 0, tzinfo=timezone.utc).timestamp() * 1000))')"
  _read() {   # _read SCENARIO ENV_MASTER -> what opus_spend.py printed (rc in $TMP/rc)
    rm -f "$TMP/port"
    python3 -I "$TMP/fake_litellm.py" "$key" "$1" "$term" "$cc" "$owui" "$setup" > "$TMP/port" 2> /dev/null < /dev/null &
    local pid=$! rc=0 out
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/port" ] && break; sleep 0.2; done
    printf 'LITELLM_PORT=%s\nLITELLM_MASTER_KEY=old\nLITELLM_MASTER_KEY=%s\nLITELLM_KEY_TERMINAL=%s\nLITELLM_KEY_CLAUDE_CODE=%s\nLITELLM_KEY_OPENWEBUI=%s\nLITELLM_KEY_SETUP=%s\n' \
      "$(cat "$TMP/port")" "$2" "$term" "$cc" "$owui" "$setup" > "$TMP/env"
    out="$(python3 -I "$STACK_DIR/tests/e2e/opus_spend.py" "$TMP/env" "$since" 2>&1)" || rc=$?
    [ "$2" = "$key" ] || { python3 -I -c 'import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=2)' "http://127.0.0.1:$(cat "$TMP/port")/end" > /dev/null 2>&1 || true; }
    wait "$pid" 2>/dev/null || true
    echo "$rc" > "$TMP/rc"; printf '%s\n' "$out"
  }
  # setup's probe alone (the setup key; the master key before it exists): nothing counted, said
  out="$(_read probe "$key")"
  assert_eq "$(cat "$TMP/rc")" 0
  assert_eq "$out" "$(printf '0.000000\t\t0.000116')"
  v="$(no_opus_verdict "$out" '')"
  assert_eq "${v%%$'\t'*}" PASS
  assert_contains "$v" "setup's model probe and ./stack test: \$0.000116 on Opus, not counted"
  # a session's Opus rows (the terminal's key; devos-claude's by its alias; not before the moment, not a bad figure): counted
  out="$(_read session "$key")"
  assert_eq "$out" "$(printf '0.021000\tclaude-opus-4-1,claude-opus-5-5\t0.000116')"
  v="$(no_opus_verdict "$out" '')"
  assert_eq "${v%%$'\t'*}" FAIL
  assert_contains "$v" '$0.021000 on Claude Opus by a session (claude-opus-4-1,claude-opus-5-5)'
  # a wrong master key: an error, never $0
  bad="$(_read probe wrong)"
  assert_eq "$(cat "$TMP/rc")" 1
  assert_contains "$bad" "did not answer"
  for k in "$key" "$term" "$cc" "$owui" "$setup"; do assert_not_contains "$out$bad" "$k"; done
}

test_e2e_volumes_of_unknown_origin_are_foreign() {
  FAKE_VOLS="bne2e_pgdata"; _fake_docker
  project_ownership
  assert_eq "$OWN_STATE" foreign
  assert_contains "$OWN_WHY" "unknown origin"
  # a free project is claimable; nothing changed by looking
  FAKE_VOLS=''; project_ownership; assert_eq "$OWN_STATE" none
  assert_eq "$(_mutating_calls)" ""
}

test_e2e_missing_folders_count_as_ours_only_under_the_work_root() {
  _fake_docker
  FAKE_DIRS="$TMP/deleted-elsewhere/bne2e"; project_ownership; assert_eq "$OWN_STATE" foreign
  FAKE_DIRS="$ROOT/tests/e2e/work/bne2e-old"; project_ownership; assert_eq "$OWN_STATE" ours
  FAKE_DIRS=''; FAKE_OWNER="$TMP/gone"; project_ownership; assert_eq "$OWN_STATE" foreign
  FAKE_OWNER="$ROOT/tests/e2e/work/gone"; project_ownership; assert_eq "$OWN_STATE" ours
}

test_e2e_teardown_only_refuses_foreign_and_unmarked() {
  mkdir -p "$TMP/other-install"; FAKE_DIRS="$TMP/other-install"; _fake_docker
  if out="$( (teardown_only) 2>&1)"; then echo "teardown ran" >&2; return 1; fi
  assert_contains "$out" "nothing was removed"
  assert_eq "$(_mutating_calls)" ""
  # our project, but a checkout folder the suite did not create (no marker): refused, folder kept
  FAKE_DIRS="$STACK"; mkdir -p "$STACK"; : > "$STACK/precious"
  if out="$( (teardown_only) 2>&1)"; then echo "teardown ran" >&2; return 1; fi
  assert_contains "$out" "no .bedrock-now-e2e marker"
  assert_eq "$(_mutating_calls)" ""
  [ -f "$STACK/precious" ] || return 1
}

test_e2e_paths_with_spaces_are_one_folder() {
  STACK="$TMP/my work dir/bne2e"; mkdir -p "$STACK"; : > "$STACK/.bedrock-now-e2e"
  FAKE_DIRS="$STACK"; FAKE_OWNER="$STACK"; _fake_docker
  project_ownership
  assert_eq "$OWN_STATE" ours
  (teardown_only) 2> "$TMP/err"
  assert_contains "$(_mutating_calls)" "docker compose -p bne2e down -v --remove-orphans"
  assert_contains "$(_mutating_calls)" "docker volume rm bne2e_bedrock-now-owner"
  [ ! -e "$STACK" ] || { echo "marked checkout not removed" >&2; return 1; }
  [ -d "$TMP/my work dir" ] || { echo "the parent folder went too" >&2; return 1; }
}

test_e2e_reuse_needs_marker_project_owner_and_every_service() {
  _fake_docker; mkdir -p "$STACK"
  if out="$( (reuse_check) 2>&1)"; then return 1; fi; assert_contains "$out" "no marker"
  : > "$STACK/.bedrock-now-e2e"; printf 'COMPOSE_PROJECT_NAME=bne2e-other\n' > "$STACK/.env"
  if out="$( (reuse_check) 2>&1)"; then return 1; fi; assert_contains "$out" "not for project bne2e"
  printf 'COMPOSE_PROJECT_NAME=bne2e\n' > "$STACK/.env"; FAKE_OWNER="$TMP/elsewhere"
  if out="$( (reuse_check) 2>&1)"; then return 1; fi; assert_contains "$out" "not owned by $STACK"
  FAKE_OWNER="$STACK"
  _ps() { printf 'caddy\trunning\tUp 1 hour (healthy)\nportal\trunning\tUp (healthy)\nopen-webui\trunning\tUp (healthy)\nlitellm\trunning\tUp (healthy)\nrustfs\trunning\tUp\nshared-mcp\trunning\tUp\npostgres\t%s\n' "$1"; }
  FAKE_PS="$(_ps 'exited	Exited (127)')"
  if out="$( (reuse_check) 2>&1)"; then return 1; fi; assert_contains "$out" "service postgres"
  FAKE_PS="$(_ps 'running	Up (unhealthy)')"
  if out="$( (reuse_check) 2>&1)"; then return 1; fi; assert_contains "$out" "service postgres"
  FAKE_PS="$(_ps 'running	Up (healthy)')"
  reuse_check 2>/dev/null
  assert_eq "$OWNED" 1
  assert_eq "$(_mutating_calls)" ""
}

test_e2e_aws_env_file_parsing() {
  f="$TMP/aws.env"
  printf 'OTHER=1\r\nexport AWS_ACCESS_KEY_ID=AKIAEXAMPLE1234\r\n  AWS_SECRET_ACCESS_KEY="se cret/+="\r\nAWS_REGION=eu-west-1\r\nAWS_SESSION_TOKEN=nope\r\n' > "$f"
  AWS_REGION_NAME=stale load_aws_file "$f"
  assert_eq "$AWS_ACCESS_KEY_ID" AKIAEXAMPLE1234
  assert_eq "$AWS_SECRET_ACCESS_KEY" "se cret/+="
  assert_eq "$AWS_REGION_NAME" eu-west-1
  assert_eq "${AWS_SESSION_TOKEN:-unset}" unset
  assert_eq "${OTHER:-unset}" unset
}

test_e2e_ports_skip_reserved_busy_and_chosen() {
  AVOID_PORTS=" 80 4000 8765 "
  port_in_use() { [ "$1" = 18480 ] || [ "$1" = 18482 ]; }
  a=""; b=""; c=""; pick_port a 18480; pick_port b 18480; pick_port c 4000
  assert_eq "$a $b $c" "18481 18483 4001"
  port_in_use() { return 0; }
  if (pick_port d 20000) 2>/dev/null; then return 1; fi
}

test_e2e_redact_and_env_has_keep_secrets_out() {
  _fake_docker; mkdir -p "$STACK"
  printf 'PORTAL_PASSWORD=hunter2hunter2\nRUSTFS_SECRET_KEY=abcdefgh12345678\nPORTAL_PORT=18480\n' > "$STACK/.env"
  printf 'login hunter2hunter2 and abcdefgh12345678 on 18480\n' > "$LOGS/x.log"
  AWS_ACCESS_KEY_ID=AKIAEXAMPLE1234 redact "$LOGS/x.log"
  assert_eq "$(cat "$LOGS/x.log")" "login *** and *** on 18480"
  env_has PORTAL_PASSWORD "xx hunter2hunter2 yy" || return 1
  if env_has PORTAL_PASSWORD "nothing here"; then return 1; fi
}

_report() { "$BASH" "$STACK_DIR/tests/e2e/report.sh" "$1" "$2" "$TMP/rep" 10 0.0050; }

test_e2e_report_groups_suites_and_applies_known_issues() {
  mkdir -p "$TMP/rep"; : > "$TMP/known"
  printf 'cli\ta\tPASS\t1\tok\nhttp\tb\tFAIL\t0\tbad\ncli\tc\tSKIP\t0\twhy\nmcp\td\tPASS\t0\tok\ncli\te\tFAIL\t2\tknown bug\n' > "$TMP/res"
  printf '# comment\ne\ta known bug\n' > "$TMP/known"
  if _report "$TMP/res" "$TMP/known" > "$TMP/out" 2>&1; then echo "a FAIL must fail the report" >&2; return 1; fi
  j="$(cat "$TMP/rep/junit.xml")"
  assert_eq "$(grep -c '<testsuite ' "$TMP/rep/junit.xml")" 3
  assert_contains "$j" '<testsuite name="cli" tests="3" failures="0" skipped="2">'
  assert_contains "$j" '<testsuite name="http" tests="1" failures="1" skipped="0">'
  assert_contains "$j" '<testsuite name="mcp" tests="1" failures="0" skipped="0">'
  assert_contains "$(cat "$TMP/rep/results-final.tsv")" "$(printf 'cli\te\tXFAIL')"
  assert_contains "$(cat "$TMP/out")" "5 checks: 2 passed, 1 failed, 1 known issues (xfail), 0 xpass, 1 skipped"
  # an empty known-issues file must not swallow the results (the old NR == FNR bug)
  : > "$TMP/known"; printf 'cli\ta\tPASS\t1\tok\n' > "$TMP/res"
  _report "$TMP/res" "$TMP/known" > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_contains "$(cat "$TMP/out")" "1 checks: 1 passed, 0 failed"
}

test_e2e_report_known_issue_with_a_pattern_matches_only_its_own_failure() {
  mkdir -p "$TMP/rep"
  # (an entry with a pattern, as the Python runner's was until v0.25.1 fixed it: its 401 only)
  printf 'chat-python-runner\tthe Python runner'"'"'s frame got 401\tpyodide\\.js carries no session cookie \\(401\\)\n' > "$TMP/known"
  assert_eq "$(awk -F'\t' '{ print NF }' "$TMP/known")" 3
  known401="AssertionError: the Python runner does not work in this stack yet: its sandboxed frame's request for pyodide.js carries no session cookie (401) — predates this release, to be fixed in v0.25.1"
  printf 'browser\tchat-python-runner\tFAIL\t9\t%s\n' "$known401" > "$TMP/res"
  _report "$TMP/res" "$TMP/known" > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_contains "$(cat "$TMP/rep/results-final.tsv")" "$(printf 'browser\tchat-python-runner\tXFAIL')"
  # another failure of that check — another cause, or a step before the runner — stays a FAIL, and says so
  for other in "AssertionError: the Python runner failed otherwise (not the known 401): ['500 GET /x']" \
               "AssertionError: new chat 500 internal error" "TimeoutError: Timeout 30000ms exceeded."; do
    printf 'browser\tchat-python-runner\tFAIL\t9\t%s\n' "$other" > "$TMP/res"
    if _report "$TMP/res" "$TMP/known" > "$TMP/out" 2>&1; then echo "not the known issue, yet not a failure: $other" >&2; return 1; fi
    assert_contains "$(cat "$TMP/rep/results-final.tsv")" "$(printf 'browser\tchat-python-runner\tFAIL')"
    assert_contains "$(cat "$TMP/rep/results-final.tsv")" "not the known issue ("
  done
  # it passes: XPASS (drop the line)
  printf 'browser\tchat-python-runner\tPASS\t9\tPython run in the browser (Pyodide): 42\n' > "$TMP/res"
  _report "$TMP/res" "$TMP/known" > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_contains "$(cat "$TMP/rep/results-final.tsv")" "$(printf 'browser\tchat-python-runner\tXPASS')"
  # an entry without a pattern: any failure of its check, as before
  printf 'e\ta known bug\n' > "$TMP/known"; printf 'cli\te\tFAIL\t2\twhatever it says\n' > "$TMP/res"
  _report "$TMP/res" "$TMP/known" > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_contains "$(cat "$TMP/rep/results-final.tsv")" "$(printf 'cli\te\tXFAIL')"
}

test_e2e_report_fails_without_results() {
  mkdir -p "$TMP/rep"; : > "$TMP/known"; : > "$TMP/res"
  if out="$(_report "$TMP/res" "$TMP/known" 2>&1)"; then return 1; fi
  assert_contains "$out" "no results"
  if out="$(_report "$TMP/missing" "$TMP/known" 2>&1)"; then return 1; fi
}

test_e2e_notty_has_no_terminal_and_passes_status_and_timeout() {
  command -v perl >/dev/null || { echo "no perl" >&2; return 77; }
  n="$STACK_DIR/tests/e2e/notty"
  if "$n" sh -c 'exec 3< /dev/tty' 2>/dev/null; then echo "a terminal was reachable" >&2; return 1; fi
  rc=0; "$n" sh -c 'exit 7' || rc=$?; assert_eq "$rc" 7
  rc=0; "$n" --timeout 1 sh -c 'sleep 20 & wait' || rc=$?; assert_eq "$rc" 124
}

test_e2e_teardown_removes_the_terminal_workspace_only_with_its_marker() {
  _fake_docker; mkdir -p "$STACK"; : > "$STACK/.bedrock-now-e2e"; FAKE_DIRS="$STACK"
  ws="$(terminal_workspace_dir)"
  assert_eq "$ws" "$ROOT/tests/e2e/work/bne2e-workspace"
  mkdir -p "$ws/project"; : > "$ws/.bedrock-now-e2e"
  OWNED=1 teardown 2>/dev/null
  [ ! -e "$ws" ] || { echo "marked workspace kept" >&2; return 1; }
  assert_contains "$(_mutating_calls)" "docker volume rm bne2e_terminal-home bne2e_terminal-socket"
  for n in bne2e_terminal bne2e_terminal-out bne2e_terminal-link bne2e_terminal-proxy; do
    assert_contains "$(cat "$TMP/docker")" "docker network rm $n" || return 1
  done
  assert_contains "$(cat "$TMP/docker")" "docker image rm bne2e/terminal-egress:local"
  # (Open WebUI's own build too: every run used to leave it behind)
  assert_contains "$(cat "$TMP/docker")" "docker image rm bne2e/open-webui:local"
  assert_contains "$(cat "$TMP/docker")" "docker image rm bne2e/open-webui:previous"
  # (the suite's git server, --git-server: by its own names, never compose's)
  assert_contains "$(cat "$TMP/docker")" "docker rm -f bne2e-gitsrv"
  assert_contains "$(cat "$TMP/docker")" "docker image rm bne2e/e2e-gitsrv:local"
  # a folder of that name the suite did not create stays
  mkdir -p "$ws"; : > "$ws/precious"
  OWNED=1 teardown 2> "$TMP/err"
  [ -f "$ws/precious" ] || return 1
  assert_contains "$(cat "$TMP/err")" "not deleting $ws"
}

# _fake_helper DIR — a stand-in for DIR/bin/bedrock-now-helper: prints its environment, starts a child (as a job's
# ./stack would be), offers Settings and writes a heartbeat every second while $TMP/alive is there (the runner deletes
# $TMP after each test, so a failed test leaves nothing running for long); FAKE_HELPER_EXIT=N: exits N at once
_fake_helper() {
  mkdir -p "$1/bin" "$1/.state/status" "$1/.state/requests" "$1/.state/helper"; : > "$TMP/alive"
  { printf '#!/usr/bin/env bash\nalive=%q\n' "$TMP/alive"; cat <<'SH'
[ -z "${FAKE_HELPER_EXIT:-}" ] || exit "$FAKE_HELPER_EXIT"
d="$1/.state/status"
printf 'knob=%s secret=%s\n' "${SETTINGS_MIN_INTERVAL_S:-unset}" "${E2E_FAKE_SECRET:-unset}"
sleep 60 & echo "child $!"
printf '{"settings": 1, "written_at": %s}\n' "$(date +%s)" > "$d/helper-settings.json" 2>/dev/null
while [ -e "$alive" ]; do printf '{"heartbeat": %s, "pid": %s}\n' "$(date +%s)" "$$" > "$d/helper.json" 2>/dev/null; sleep 1; done
SH
  } > "$1/bin/bedrock-now-helper"
  chmod 755 "$1/bin/bedrock-now-helper"
}
_alive() { kill -0 "$1" 2>/dev/null; }

test_e2e_helper_runs_with_its_knobs_only_and_stops_with_its_children() {
  command -v perl >/dev/null || { echo "no perl" >&2; return 77; }
  _fake_docker; NOTTY="$STACK_DIR/tests/e2e/notty"; _fake_helper "$STACK"
  E2E_FAKE_SECRET=leaked; export E2E_FAKE_SECRET
  e2e_helper_start
  log="$(cat "$LOGS/helper.log")"
  assert_contains "$log" "knob=5"
  assert_contains "$log" "secret=unset"    # a clean environment: nothing of this shell but the knobs
  child="$(printf '%s\n' "$log" | sed -n 's/^child //p')"; beat="$(sed -n 's/.*"pid": \([0-9]*\).*/\1/p' "$STACK/.state/status/helper.json")"
  if ! _alive "$child" || ! _alive "$beat"; then echo "helper or its child not running" >&2; return 1; fi
  [ "$(ps -o pgid= -p "$beat" | tr -d ' ')" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] || { echo "helper in this shell's process group" >&2; return 1; }
  printf '{}\n' > "$STACK/.state/requests/req-1.json"; : > "$STACK/.state/helper/last-settings.log"
  e2e_helper_stop
  assert_eq "$HELPER_ALIVE" 1
  for _ in 1 2 3 4 5 6; do _alive "$child" || _alive "$beat" || break; sleep 0.5; done
  if _alive "$child" || _alive "$beat"; then echo "still running after stop: helper $beat / child $child" >&2; return 1; fi
  [ ! -e "$STACK/.state/status/helper.json" ] && [ ! -e "$STACK/.state/requests/req-1.json" ] || { echo "heartbeat or request left" >&2; return 1; }
  [ -f "$LOGS/helper-last-settings.log" ] || { echo "the helper's last settings log was not kept" >&2; return 1; }
  assert_contains "$(cat "$LOGS/helper.log")" "e2e: helper stopped"
  e2e_helper_stop   # a second stop is harmless
}

test_e2e_helper_that_stops_by_itself_is_reported() {
  command -v perl >/dev/null || { echo "no perl" >&2; return 77; }
  _fake_docker; NOTTY="$STACK_DIR/tests/e2e/notty"; _fake_helper "$STACK"
  HELPER_KNOBS="SETTINGS_MIN_INTERVAL_S=5 FAKE_HELPER_EXIT=3"
  rc=0; e2e_helper_start 2> "$TMP/err" || rc=$?
  e2e_helper_stop
  assert_eq "$rc" 1
  assert_contains "$(cat "$TMP/err")" "stopped by itself"
  assert_eq "$HELPER_ALIVE $HELPER_RC" "0 3"
}

test_e2e_teardown_stops_a_helper_a_killed_run_left_but_no_other_checkouts() {
  command -v perl >/dev/null || { echo "no perl" >&2; return 77; }
  _fake_docker; NOTTY="$STACK_DIR/tests/e2e/notty"
  _fake_helper "$STACK"; _fake_helper "$STACK-rel"; : > "$STACK/.bedrock-now-e2e"
  # a run killed with -9: its notty is gone, the helper (its own session) still runs; and another checkout's helper
  "$NOTTY" "$STACK/bin/bedrock-now-helper" "$STACK" > /dev/null 2>&1 & n=$!
  "$NOTTY" "$STACK-rel/bin/bedrock-now-helper" "$STACK-rel" > /dev/null 2>&1 & other=$!
  for _ in $(seq 1 20); do [ -s "$STACK/.state/status/helper.json" ] && [ -s "$STACK-rel/.state/status/helper.json" ] && break; sleep 0.5; done
  kill -KILL "$n"; wait "$n" 2>/dev/null || true
  beat="$(sed -n 's/.*"pid": \([0-9]*\).*/\1/p' "$STACK/.state/status/helper.json")"
  rel="$(sed -n 's/.*"pid": \([0-9]*\).*/\1/p' "$STACK-rel/.state/status/helper.json")"
  _alive "$beat" || { echo "the orphaned helper is not running" >&2; return 1; }
  OWNED=1 teardown 2>/dev/null
  for _ in 1 2 3 4 5 6; do _alive "$beat" || break; sleep 0.5; done
  rc=0
  if _alive "$beat"; then echo "teardown left the helper of $STACK running" >&2; rc=1; fi
  _alive "$rel" || { echo "teardown stopped the helper of another checkout ($STACK-rel)" >&2; rc=1; }
  kill -TERM "$other" 2>/dev/null; wait "$other" 2>/dev/null || true
  return "$rc"
}

test_e2e_host_folders_default_to_the_work_folder_never_out() {
  ROOT="$STACK_DIR"; PROJECT=bne2e-x; OUT="/tmp/somewhere-out"
  local E2E_HOST_FOLDERS_DIR=''
  assert_eq "$(host_folders_parent)" "$STACK_DIR/tests/e2e/work/bne2e-x-host-folders"
  E2E_HOST_FOLDERS_DIR="$TMP/mine"
  assert_eq "$(host_folders_parent)" "$TMP/mine"
}

test_e2e_host_folders_a_parent_stack_project_refuses_is_said_at_once() {
  ROOT="$STACK_DIR"
  local why
  # a temporary folder (the tests' own folders are in one), a .claude folder that is not a worktree's
  why="$(host_folders_refused "$TMP/new/host-folders")" || { echo "accepted a temporary folder" >&2; return 1; }
  assert_contains "$why" "temporary or runtime folder"
  why="$(host_folders_refused "/nonexistent-root/src/.claude/skills/host-folders")" || { echo "accepted a .claude folder" >&2; return 1; }
  assert_contains "$why" "a .claude folder"
  # a Claude Code worktree's folder is fine
  if host_folders_refused "/nonexistent-root/repo/.claude/worktrees/w/tests/e2e/work/bne2e-host-folders" >/dev/null; then
    echo "refused a worktree's folder" >&2; return 1
  fi
  # run.sh says it before anything is set up (no docker, no setup), naming E2E_HOST_FOLDERS_DIR
  local out rc=0
  out="$(cd "$TMP" && E2E_HOST_FOLDERS_DIR="$TMP/hf" bash "$STACK_DIR/tests/e2e/run.sh" --host-folders --project bne2e-hf --aws-env /nonexistent 2>&1)" || rc=$?
  assert_eq "$rc" 2
  assert_contains "$out" "--host-folders: ./stack project would refuse folders in $TMP/hf"
  assert_contains "$out" "set E2E_HOST_FOLDERS_DIR=/abs/new-folder"
  [ ! -e "$TMP/hf" ] || { echo "made the folder anyway" >&2; return 1; }
  mkdir -p "$TMP/there"
  out="$(E2E_HOST_FOLDERS_DIR="$TMP/there" bash "$STACK_DIR/tests/e2e/run.sh" --host-folders --project bne2e-hf --aws-env /nonexistent 2>&1)" && return 1
  assert_contains "$out" "is there already"
}

# --host-egress: a throwaway of its own (bne2e-hostegress), with the Code page, never with --git-server — refused before
# anything is set up (no docker, no setup); its checks after the browser part, TERMINAL_EGRESS=off last
test_host_egress_runs_in_its_own_throwaway() {
  local out rc
  for args in "--project bne2e-x" "--no-code" "--git-server"; do
    rc=0
    # shellcheck disable=SC2086  # the words of one case
    out="$(cd "$TMP" && bash "$STACK_DIR/tests/e2e/run.sh" --host-egress $args --aws-env /nonexistent 2>&1)" || rc=$?
    assert_eq "$rc" 2
    assert_contains "$out" "--host-egress"
  done
  local r; r="$(cat "$STACK_DIR/tests/e2e/run.sh")"
  assert_contains "$r" '[ "$PROJECT_GIVEN" = 1 ] || PROJECT=bne2e-hostegress'
  assert_contains "$r" '[ "$GIT_SERVER" = 0 ] && [ "$HOST_EGRESS" = 0 ] || set_env TERMINAL_EGRESS host'
  # (its section after the browser part; the switch to off by the scripted apply, its order from Docker's events)
  local b h
  b="$(grep -n '^# --- 3\. the browser suite' "$STACK_DIR/tests/e2e/run.sh" | cut -d: -f1)"
  h="$(grep -n '^# --- 3a5\. the terminal' "$STACK_DIR/tests/e2e/run.sh" | cut -d: -f1)"
  [ -n "$b" ] && [ -n "$h" ] && [ "$h" -gt "$b" ] || { echo "the host-egress checks are not after the browser part ($b, $h)" >&2; return 1; }
  assert_contains "$r" 'config apply --stdin < "$LOGS/hostegress-off.in"'
  assert_contains "$r" '[ "$gone" -lt "$back" ]'
}

# --- terminal-isolation's public side (lib.sh public_probe_steady): fakes of the probe, the proxy's log and this
# computer's resolver ---
_public() { printf 'internet\t200\nproxy-public\t%s\nnode-fetch\t200\nnpm-install\tok\npip-download\t1\ngit-https\t1\ngit-ssh\t1\n' "$1"; }
_public_ok() { _public '200 200'; }
_public_refused() { _public '200 403'; }
# (fails its first two tries; a count in a file: each try runs in a subshell)
_public_twice() {
  local n; n=$(( $(cat "$TMP/tries" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/tries"
  if [ "$n" -le 2 ]; then _public_refused; else _public_ok; fi
}
# the proxy's log, as bn-egress.mjs writes it; the argument (SINCE) kept for the test
_egress_loopback() {
  printf '%s\n' "$1" >> "$TMP/since"
  printf '%s\n' '{"t":"2026-10-25T10:31:20.568Z","event":"refused","method":"GET","host":"example.com","port":80,"address":"127.0.0.1","status":403,"why":"example.com resolves to 127.0.0.1: loopback"}'
}
_egress_refusals_only() {
  printf '%s\n' '{"t":"2026-10-25T10:31:09.297Z","event":"refused","method":"GET","host":"127.0.0.1.nip.io","port":80,"address":"127.0.0.1","status":403,"why":"127.0.0.1.nip.io resolves to 127.0.0.1: loopback"}' \
    '{"t":"2026-10-25T10:31:10.541Z","event":"refused","method":"GET","host":"10.255.255.1","port":80,"address":"10.255.255.1","status":403,"why":"a private address (RFC 1918)"}'
}
_egress_none() { :; }
_dns_public() { local n; for n in "$@"; do printf '%s 104.20.23.154 2606:4700:10::6814:179a\n' "$n"; done; }
_dns_example_loopback() {
  local n; for n in "$@"; do case "$n" in example.com) printf '%s 127.0.0.1\n' "$n" ;; *) printf '%s 104.20.23.154\n' "$n" ;; esac; done
}

test_e2e_public_probes_are_tried_again_only_while_this_computers_dns_answers_privately() {
  local rc
  export E2E_PUBLIC_GAP_S=0 E2E_HOST_DNS=_dns_public
  # passes at once: one try, nothing found
  rc=0; public_probe_steady _public_ok _egress_loopback || rc=$?
  assert_eq "$rc/$PUBLIC_TRIES/$PUBLIC_DNS/$PUBLIC_DNS_SEEN" "0/1//"
  # the proxy refused example.com for the loopback address this computer's DNS gave it: tried again, passes at try 3
  rm -f "$TMP/tries" "$TMP/since"
  rc=0; public_probe_steady _public_twice _egress_loopback || rc=$?
  assert_eq "$rc/$PUBLIC_TRIES/$PUBLIC_DNS" "0/3/"
  assert_eq "$PUBLIC_DNS_SEEN" "this computer's DNS answered example.com with 127.0.0.1"
  assert_contains "$PUBLIC_LOG" "# public probes, try 3"
  assert_contains "$PUBLIC_LOG" "# this computer's DNS: example.com 104.20.23.154"
  assert_eq "$(printf '%s' "$PUBLIC_OUT" | awk -F'\t' '$1 == "proxy-public" { print $2 }')" "200 200"
  # (the log is read from the try's start, in unix seconds)
  assert_eq "$(grep -cE '^[0-9]{10}$' "$TMP/since")" 2
  # the same while it stays so: 1 + 3 tries, then a FAIL that says why
  rc=0; public_probe_steady _public_refused _egress_loopback || rc=$?
  assert_eq "$rc/$PUBLIC_TRIES" "1/4"
  assert_eq "$PUBLIC_DNS" "this computer's DNS answered example.com with 127.0.0.1"
  assert_eq "$(public_probe_bad "$PUBLIC_OUT")" " proxy-public:200 403"
  # E2E_PUBLIC_RETRIES bounds it
  rc=0; E2E_PUBLIC_RETRIES=1 public_probe_steady _public_refused _egress_loopback || rc=$?
  assert_eq "$rc/$PUBLIC_TRIES" "1/2"
  # the refusal not in the log (its window was full) but this computer's resolver answering privately: tried again too
  rc=0; E2E_HOST_DNS=_dns_example_loopback public_probe_steady _public_refused _egress_none || rc=$?
  assert_eq "$rc/$PUBLIC_TRIES/$PUBLIC_DNS" "1/4/this computer's DNS answered example.com with 127.0.0.1"
  # any other failure is final at once: the proxy's log has only refusals of names that are not the public probes'
  # (DNS rebinding, a private address), and this computer's DNS answers publicly
  rc=0; public_probe_steady _public_refused _egress_refusals_only || rc=$?
  assert_eq "$rc/$PUBLIC_TRIES/$PUBLIC_DNS/$PUBLIC_DNS_SEEN" "1/1//"
  rc=0; public_probe_steady _public_refused _egress_none || rc=$?
  assert_eq "$rc/$PUBLIC_TRIES/$PUBLIC_DNS" "1/1/"
  # a probe that says nothing fails every key
  assert_eq "$(public_probe_bad '')" " internet: proxy-public: node-fetch: npm-install: pip-download: git-https: git-ssh:"
}

test_e2e_public_dns_problem_reads_the_proxys_log_and_this_computers_answers() {
  local a out
  for a in 127.0.0.1 10.1.2.3 100.64.0.1 172.16.0.1 172.31.255.254 192.168.1.1 169.254.169.254 0.0.0.0 224.0.0.1 198.18.0.1 \
           192.0.2.1 203.0.113.5 ::1 :: fd00::1 FE80::1 ff02::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1; do
    not_public "$a" || { echo "$a counted as public" >&2; return 1; }
  done
  for a in 8.8.8.8 104.20.23.154 100.128.0.1 172.32.0.1 2606:4700::1 ::ffff:8.8.8.8 1.2.3 1.2.3.4.5 a.b.c.d ''; do
    ! not_public "$a" || { echo "$a counted as not public" >&2; return 1; }
  done
  # the proxy's own words: the address it refused, IPv6 too
  out="$(printf '%s\n' '{"event":"refused","method":"CONNECT","host":"registry.npmjs.org","port":443,"address":"::1","status":403,"why":"registry.npmjs.org resolves to ::1: loopback"}' |
    public_dns_problem '' registry.npmjs.org example.com)"
  assert_eq "$out" "this computer's DNS answered registry.npmjs.org with ::1"
  # a name that is not a public probe's, or a refusal without "resolves to", is not one
  ! _egress_refusals_only | public_dns_problem "$(_dns_public example.com)" example.com >/dev/null || return 1
  # this computer's own answer: an address no public name has, among others
  out="$(public_dns_problem "github.com 140.82.112.3 fd00::1
example.com 104.20.23.154" github.com example.com </dev/null)"
  assert_eq "$out" "this computer's DNS answered github.com with fd00::1"
  ! public_dns_problem "nip.io.example 127.0.0.1" github.com </dev/null >/dev/null || return 1
  # this computer's resolver, offline: localhost
  assert_contains "$(host_dns_answers localhost)" "127.0.0.1"
}

test_e2e_rebind_dns_problem_only_when_no_unrefused_name_got_its_address() {
  local names='127.0.0.1.nip.io 146.112.61.106
10.255.255.1.nip.io 146.112.61.106
169.254.169.254.nip.io 146.112.61.106'
  # none refused, none got their address (a filtering resolver's own page): those probes tested nothing
  assert_eq "$(rebind_dns_problem '0 0 0 ' "$names")" "this computer's DNS answered 127.0.0.1.nip.io with 146.112.61.106, not 127.0.0.1"
  assert_eq "$(rebind_dns_problem '1 0 1 ' "127.0.0.1.nip.io 127.0.0.1
10.255.255.1.nip.io -
169.254.169.254.nip.io 169.254.169.254")" "this computer's DNS answered 10.255.255.1.nip.io with -, not 10.255.255.1"
  # one not refused that did get its address: the proxy let it through — no excuse for any of them
  ! rebind_dns_problem '0 0 1 ' "127.0.0.1.nip.io 127.0.0.1
10.255.255.1.nip.io 146.112.61.106
169.254.169.254.nip.io 169.254.169.254" >/dev/null || return 1
  ! rebind_dns_problem '1 1 1 ' "$names" >/dev/null || return 1
  ! rebind_dns_problem '' "$names" >/dev/null || return 1
}

# run.sh: the refusals are judged once, from the first probe; only terminal_public_probe's keys are tried again,
# and they are exactly E2E_PUBLIC_EXPECT's; the names they reach are E2E_PUBLIC_HOSTS
test_e2e_terminal_isolation_tries_only_the_public_side_again() {
  local r main pub k h
  r="$(cat "$STACK_DIR/tests/e2e/run.sh")"
  main="$(awk '/^terminal_probe\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' "$STACK_DIR/tests/e2e/run.sh")"
  pub="$(awk '/^terminal_public_probe\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' "$STACK_DIR/tests/e2e/run.sh")"
  [ -n "$main" ] && [ -n "$pub" ] || { echo "terminal_probe or terminal_public_probe not found" >&2; return 1; }
  while IFS= read -r k; do
    k="${k%%=*}"
    assert_contains "$pub" "printf '$k\\t"
    assert_not_contains "$main" "printf '$k\\t"
  done <<< "$E2E_PUBLIC_EXPECT"
  for k in proxy-rebind proxy-host proxy-private proxy-tls-private proxy-port 'x -o' egress:3128; do assert_not_contains "$pub" "$k"; done
  for h in $(printf '%s\n' "$pub" | grep -oE 'https?://[a-z0-9.-]+|git@[a-z0-9.-]+' | sed -E 's#^(https?://|git@)##' | sort -u); do
    case " $E2E_PUBLIC_HOSTS " in *" $h "*) ;; *) echo "$h is not in E2E_PUBLIC_HOSTS" >&2; return 1 ;; esac
  done
  # the strict side as it was: every refusal in the one list, a rebinding probe not refused a FAIL
  assert_contains "$r" 'proxy-host="403 403 403 403 403 403 403 403 " proxy-private="403 403 403 403 403 403 403 403 403 "'
  assert_contains "$r" 'proxy-host-ssh=403 proxy-tls-private="403 403 403 " proxy-port=403; do'
  assert_contains "$r" '*0*|"") bad="$bad proxy-rebind:$rb$REBIND_BAD"'
  assert_contains "$r" 'public_probe_steady pub_try egress_since'
  assert_contains "$r" 'pbad="$(public_probe_bad "$PUBLIC_OUT")"; bad="$bad$pbad"'
  assert_contains "$r" '"${dns_note:+$dns_note — }unexpected:$bad'
}

# --- terminal-isolation's DNS-rebinding probes (lib.sh rebind_steady): the egress proxy's answers, faked ---
_RB1=http://127.0.0.1.nip.io/ _RB2=http://10.255.255.1.nip.io/ _RB3=http://169.254.169.254.nip.io/
# _rb URL RC CODE EGRESS BODY -> a line as tests/e2e/rebind-try.sh writes it
_rb() { printf 'proxy-rebind-try\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
_rb_answer() {   # URL KIND -> the proxy's answer of that kind (bn-egress.mjs's words)
  local n="${1#http://}"; n="${n%/}"
  case "$2" in
    refused) _rb "$1" 0 403 refused "DevOS ADE's sandbox proxy: refused — $n resolves to ${n%.nip.io}: loopback. This proxy lets …" ;;
    timeout) _rb "$1" 28 000 - - ;;
    lookup-timeout) _rb "$1" 0 504 failed "DevOS ADE's sandbox proxy: failed — looking up $n timed out." ;;
    dns) _rb "$1" 0 502 failed "DevOS ADE's sandbox proxy: failed — $n does not resolve (ENOTFOUND)." ;;
    reached) _rb "$1" 0 200 - "<html><body>a page</body></html>" ;;
    redirect) _rb "$1" 0 302 - - ;;
    other) _rb "$1" 0 502 failed "DevOS ADE's sandbox proxy: failed — $n:80 did not answer (ECONNREFUSED)." ;;
  esac
}
# the retry: answers from the kinds in $TMP/rb-next (one per call, the last one repeating), each call logged
_rb_retry() {
  local n kind
  printf '%s %s\n' "$1" "$2" >> "$TMP/rb-calls"
  n="$(wc -l < "$TMP/rb-calls" | tr -d ' ')"
  kind="$(sed -n "${n}p" "$TMP/rb-next")"; [ -n "$kind" ] || kind="$(tail -n 1 "$TMP/rb-next")"
  _rb_answer "$1" "$kind"
}
_rb_run() {   # FIRST-KINDS (3 words) RETRY-KINDS... -> rebind_steady on them; $TMP/rb-calls: the retries asked
  local k1 k2 k3; read -r k1 k2 k3 <<< "$1"; shift
  : > "$TMP/rb-calls"; printf '%s\n' "${@:-refused}" > "$TMP/rb-next"
  rebind_steady _rb_retry "$(_rb_answer "$_RB1" "$k1"; _rb_answer "$_RB2" "$k2"; _rb_answer "$_RB3" "$k3")"
}

test_e2e_rebind_class_reads_the_proxys_answer() {
  local k
  for k in refused:refused timeout:noanswer lookup-timeout:noanswer dns:dns reached:reached redirect:reached other:other; do
    assert_eq "$(_rb_answer "$_RB1" "${k%%:*}" | _rebind_state)" "$_RB1 ${k#*:} $(_rb_answer "$_RB1" "${k%%:*}" | cut -f4)"
  done
  # an answer that is not the proxy's (no X-Bn-Egress) reached the target, whatever its code or words
  assert_eq "$(rebind_class 0 403 - 'Forbidden: 127.0.0.1.nip.io resolves to 127.0.0.1')" reached
  # the proxy's words with the wrong code or header are not a refusal
  assert_eq "$(rebind_class 0 502 failed 'x resolves to 127.0.0.1: loopback')" other
  assert_eq "$(rebind_class 0 403 failed 'x resolves to 127.0.0.1: loopback')" other
  # the proxy's connection to an address that timed out is not its lookup timing out
  assert_eq "$(rebind_class 0 504 failed "DevOS ADE's sandbox proxy: failed — x.nip.io:80 did not answer (ETIMEDOUT).")" other
  assert_eq "$(rebind_class 7 000 - -)" noanswer
}

test_e2e_rebind_no_answer_is_asked_again_and_nothing_else_is() {
  export E2E_REBIND_GAP_S=0
  # no answer, then refused: passes, one retry with the longer limit
  _rb_run "timeout refused refused" refused
  assert_eq "$REBIND_RB|$REBIND_BAD|$REBIND_NOTE|$REBIND_TRIES" "1 1 1 |||2"
  assert_eq "$(cat "$TMP/rb-calls")" "$_RB1 30"
  assert_contains "$REBIND_LOG" "# DNS rebinding, try 2"
  # the proxy's own lookup timed out (504), then refused: the same
  _rb_run "refused lookup-timeout refused" refused
  assert_eq "$REBIND_RB|$REBIND_BAD|$REBIND_NOTE|$REBIND_TRIES" "1 1 1 |||2"
  assert_eq "$(cat "$TMP/rb-calls")" "$_RB2 30"
  # 200: the target was reached — a FAIL at once, never asked again
  _rb_run "reached refused refused"
  assert_eq "$REBIND_RB|$REBIND_BAD|$REBIND_NOTE|$REBIND_TRIES" "0 1 1 | 127.0.0.1.nip.io:reached(200)||1"
  assert_eq "$(cat "$TMP/rb-calls")" ""
  _rb_run "refused redirect refused"
  assert_eq "$REBIND_RB|$REBIND_BAD|$REBIND_NOTE" "1 0 1 | 10.255.255.1.nip.io:reached(302)|"
  assert_eq "$(cat "$TMP/rb-calls")" ""
  # no answer four times: a FAIL that says it is the environment
  _rb_run "timeout refused refused" timeout timeout lookup-timeout
  assert_eq "$REBIND_RB|$REBIND_BAD|$REBIND_TRIES" "0 1 1 | 127.0.0.1.nip.io:no-answer|4"
  assert_eq "$REBIND_NOTE" "the proxy did not answer for 127.0.0.1.nip.io (its DNS lookup timed out?): an environment problem, rerun"
  assert_eq "$(wc -l < "$TMP/rb-calls" | tr -d ' ')" 3
  # E2E_REBIND_RETRIES bounds it
  E2E_REBIND_RETRIES=1 _rb_run "timeout timeout refused" timeout
  assert_eq "$REBIND_RB|$REBIND_TRIES" "0 0 1 |2"
  assert_eq "$(wc -l < "$TMP/rb-calls" | tr -d ' ')" 2
  # nip.io itself not resolving: not checked, as before — and not asked again
  _rb_run "dns refused refused"
  assert_eq "$REBIND_RB|$REBIND_BAD|$REBIND_NOTE|$REBIND_TRIES" "dns 1 1 |||1"
  assert_eq "$(cat "$TMP/rb-calls")" ""
  # any other answer of the proxy's is final at once and no excuse
  _rb_run "other refused refused"
  assert_eq "$REBIND_RB|$REBIND_BAD|$REBIND_NOTE|$REBIND_TRIES" "0 1 1 | 127.0.0.1.nip.io:other(502)||1"
  # no environment note while any other one failed otherwise: strict
  _rb_run "timeout other refused" timeout
  assert_eq "$REBIND_RB|$REBIND_NOTE" "0 0 1 |"
  assert_contains "$REBIND_BAD" "127.0.0.1.nip.io:no-answer"
  assert_contains "$REBIND_BAD" "10.255.255.1.nip.io:other(502)"
  # no answer, then reached on a retry: a FAIL, no note
  _rb_run "timeout refused refused" reached
  assert_eq "$REBIND_RB|$REBIND_BAD|$REBIND_NOTE|$REBIND_TRIES" "0 1 1 | 127.0.0.1.nip.io:reached(200)||2"
  # a retry that says nothing usable stays no answer
  _rb_run "timeout refused refused" garbage
  assert_eq "$REBIND_RB|$REBIND_TRIES" "0 1 1 |4"
}

# rebind-try.sh itself, with a curl that answers as the proxy would: one line per answer, read back right
test_e2e_rebind_try_reports_each_answer_as_one_line() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
o=''; d=''
while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift ;; -D) d="$2"; shift ;; -w|-m|-x) shift ;; esac; shift; done
case "$FAKE_CURL" in
  refused) printf 'HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\nX-Bn-Egress: refused\r\nConnection: close\r\n\r\n' > "$d"
    printf "DevOS ADE's sandbox proxy: refused — 127.0.0.1.nip.io resolves to 127.0.0.1: loopback.\nThis proxy\tlets …\n" > "$o"; printf 403 ;;
  timeout) : > "$d"; : > "$o"; printf 000; exit 28 ;;
  reached) printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n' > "$d"; printf '<html>\n</html>\n' > "$o"; printf 200 ;;
esac
EOF
  chmod +x "$TMP/bin/curl"
  local line
  . "$STACK_DIR/tests/e2e/rebind-try.sh"
  line="$(PATH="$TMP/bin:$PATH" FAKE_CURL=refused rb_try "$_RB1" 15)"
  assert_eq "$(printf '%s\n' "$line" | awk -F'\t' '{ print NF, $1, $3, $4, $5 }')" "6 proxy-rebind-try 0 403 refused"
  assert_eq "$(printf '%s\n' "$line" | _rebind_state)" "$_RB1 refused 403"
  line="$(PATH="$TMP/bin:$PATH" FAKE_CURL=timeout rb_try "$_RB1" 15)"
  assert_eq "$line" "$(printf 'proxy-rebind-try\t%s\t28\t000\t-\t-' "$_RB1")"
  assert_eq "$(printf '%s\n' "$line" | _rebind_state)" "$_RB1 noanswer 000"
  line="$(PATH="$TMP/bin:$PATH" FAKE_CURL=reached rb_try "$_RB1" 15)"
  assert_eq "$(printf '%s\n' "$line" | _rebind_state)" "$_RB1 reached 200"
  # run.sh: the first three go with the probe, after its fresh log window; a retry alone; the verdict as before
  local r; r="$(cat "$STACK_DIR/tests/e2e/run.sh")"
  assert_contains "$r" 'for u in http://127.0.0.1.nip.io/ http://10.255.255.1.nip.io/ http://169.254.169.254.nip.io/; do rb_try "$u" 15; done'
  assert_contains "$r" '{ cat "$HERE/rebind-try.sh"; cat <<'"'"'SH'"'"'; } | docker exec -i'
  assert_contains "$r" 'rebind_steady rebind_try'
  assert_contains "$r" '*0*|"") bad="$bad proxy-rebind:$rb$REBIND_BAD"'
  assert_contains "$r" 'case "$rb" in 1*) printf '"'"'%s\n'"'"' "$elog" | grep '"'"'"address":"127.0.0.1".*resolves to 127.0.0.1'"'"' >/dev/null || bad="$bad egress-log-no-rebind" ;; esac'
}

# --- the suite's image cache (tests/e2e/docker-reuse/docker, for the throwaway's ./stack setup): a stand-in for the
# real docker logs every call and keeps images as files ($TMP/images/REPO_NAME_TAG) ---
_real_docker() {
  mkdir -p "$TMP/images"; : > "$TMP/calls"
  cat > "$TMP/realdocker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TMP/calls"
f() { printf '%s/images/%s' "$TMP" "$(printf '%s' "$1" | tr '/:' '__')"; }
case "$1" in
  image) [ "$2" = inspect ] && [ -f "$(f "$3")" ]; exit $? ;;
  tag) [ -f "$(f "$2")" ] || exit 1; cp "$(f "$2")" "$(f "$3")" ;;
  compose)   # a build: each service after the options is PROJECT/NAME:local, made anew
    [ -z "${FAIL_BUILD:-}" ] || exit 1
    p=''; prev=''; past=0
    for a in "$@"; do
      [ "$prev" != -p ] || p="$a"
      if [ "$past" = 1 ] && [ "$prev" != --build-arg ]; then
        case "$a" in -*) ;; chat-egress) echo "$$ $(date +%s)" > "$(f "$p/terminal-egress:local")" ;; *) echo "$$ $(date +%s)" > "$(f "$p/$a:local")" ;; esac
      fi
      [ "$a" != build ] || past=1; prev="$a"
    done ;;
esac
exit 0
EOF
  chmod +x "$TMP/realdocker"
  printf 'COMPOSE_PROJECT_NAME=x\nTERMINAL_UID=501\nTERMINAL_GID=20\n' > "$TMP/env"
  export TMP E2E_REAL_DOCKER="$TMP/realdocker" E2E_IMAGE_TREE=tree1 E2E_IMAGE_LOG="$TMP/image-cache.log"
}
# _build PROJECT [EXTRA...] — setup's build of the terminal image, as lib/terminal.sh terminal_build runs it through dc
_build() {
  local p="$1"; shift
  "$STACK_DIR/tests/e2e/docker-reuse/docker" compose -p "$p" --project-directory /s -f /s/compose.yaml -f /s/compose.terminal.yaml \
    --env-file "$TMP/env" build -q --build-arg APT_REFRESH=2026-43 --build-arg BN_AI_TOOLS=all "$@" terminal
}
_img() { [ -f "$TMP/images/$(printf '%s' "$1" | tr '/:' '__')" ]; }
_builds() { grep -c ' build ' "$TMP/calls" | tr -d ' '; }

test_e2e_image_cache_builds_an_image_once_per_tree() {
  _real_docker
  _build bne2e-a || return 1
  assert_eq "$(_builds)" 1
  _img bne2e-a/terminal:local || return 1
  local kept; kept="$(sed -n 's/.*kept as \(bne2e-cache\/terminal:[0-9a-f]*\)$/\1/p' "$TMP/image-cache.log")"
  [ -n "$kept" ] && _img "$kept" || { echo "not kept: $(cat "$TMP/image-cache.log")" >&2; return 1; }
  # the next run of the same files: its image is the kept one, nothing built
  : > "$TMP/calls"; _build bne2e-b || return 1
  assert_eq "$(_builds)" 0
  cmp -s "$TMP/images/bne2e-cache_terminal_${kept##*:}" "$TMP/images/bne2e-b_terminal_local" || { echo "not the kept image" >&2; return 1; }
  assert_contains "$(cat "$TMP/image-cache.log")" "reused terminal ($kept, built from this tree before)"
  assert_eq "$(image_cache_report "$TMP/image-cache.log")" "reused: terminal; built: terminal"
}

test_e2e_image_cache_never_reuses_across_trees_or_builds() {
  _real_docker
  _build bne2e-a || return 1
  # another tree; another build argument; another uid (the terminal's compose file passes it from .env); another
  # compose file: each built
  : > "$TMP/calls"; E2E_IMAGE_TREE=tree2 _build bne2e-b || return 1; assert_eq "$(_builds)" 1
  : > "$TMP/calls"; _build bne2e-c --build-arg EXTRA=1 || return 1; assert_eq "$(_builds)" 1
  sed -i.bak 's/^TERMINAL_UID=501/TERMINAL_UID=502/' "$TMP/env"
  : > "$TMP/calls"; _build bne2e-d || return 1; assert_eq "$(_builds)" 1
  mv "$TMP/env.bak" "$TMP/env"
  : > "$TMP/calls"
  "$STACK_DIR/tests/e2e/docker-reuse/docker" compose -p bne2e-e --project-directory /s -f /s/compose.yaml --env-file "$TMP/env" \
    build -q --build-arg APT_REFRESH=2026-43 --build-arg BN_AI_TOOLS=all terminal || return 1
  assert_eq "$(_builds)" 1
  # and the first tree's again: reused
  : > "$TMP/calls"; _build bne2e-f || return 1; assert_eq "$(_builds)" 0
}

test_e2e_image_cache_leaves_everything_else_to_docker() {
  _real_docker
  local d="$STACK_DIR/tests/e2e/docker-reuse/docker"
  # a build wanted as such, a service it does not know, another command, no tree: as given, nothing kept
  "$d" compose -p bne2e-a -f /s/compose.yaml build --no-cache terminal || return 1
  "$d" compose -p bne2e-a -f /s/compose.yaml build -q caddy || return 1
  "$d" compose -p bne2e-a -f /s/compose.yaml ps -q || return 1
  "$d" ps -a --filter name=x || return 1
  E2E_IMAGE_TREE='' "$d" compose -p bne2e-a -f /s/compose.yaml build -q terminal || return 1
  assert_eq "$(cat "$TMP/calls")" "compose -p bne2e-a -f /s/compose.yaml build --no-cache terminal
compose -p bne2e-a -f /s/compose.yaml build -q caddy
compose -p bne2e-a -f /s/compose.yaml ps -q
ps -a --filter name=x
compose -p bne2e-a -f /s/compose.yaml build -q terminal"
  [ ! -s "$TMP/image-cache.log" ] || { echo "kept: $(cat "$TMP/image-cache.log")" >&2; return 1; }
  # a build that fails: its status, nothing kept
  local rc=0; FAIL_BUILD=1 _build bne2e-b || rc=$?
  assert_eq "$rc" 1
  [ ! -s "$TMP/image-cache.log" ] || return 1
  # Chat's egress proxy: the terminal's egress proxy's image
  "$d" compose -p bne2e-c -f /s/compose.yaml --env-file "$TMP/env" build -q chat-egress || return 1
  assert_contains "$(cat "$TMP/image-cache.log")" "built terminal-egress; kept as bne2e-cache/terminal-egress:"
}

test_e2e_image_cache_keeps_one_trees_images() {
  _fake_docker
  printf '%s\n' "2026-10-25 12:00:00 reused portal (bne2e-cache/portal:aaa, built from this tree before)" \
    "2026-10-25 12:00:01 built code; kept as bne2e-cache/code:bbb" > "$TMP/log"
  docker() {
    printf 'docker %s\n' "$*" >> "$TMP/docker"
    case "$*" in "image ls --filter reference=bne2e-cache/* "*) printf '%s\n' bne2e-cache/portal:aaa bne2e-cache/portal:old bne2e-cache/code:bbb bne2e-cache/terminal:old ;; esac
  }
  image_cache_keep "$TMP/log"
  assert_eq "$(grep 'image rm' "$TMP/docker")" "docker image rm bne2e-cache/portal:old
docker image rm bne2e-cache/terminal:old"
  # nothing reused or kept in this run: nothing removed
  : > "$TMP/docker"; : > "$TMP/log"; image_cache_keep "$TMP/log"
  assert_eq "$(grep -c 'image rm' "$TMP/docker" | tr -d ' ')" 0
}

test_e2e_setup_alone_builds_through_the_image_cache() {
  local r; r="$(cat "$STACK_DIR/tests/e2e/run.sh")"
  assert_contains "$r" "ST_IMAGES=1 cli setup 0 'DevOS ADE is up' --aws setup --yes"
  [ "$(grep -c 'ST_IMAGES=1 ' "$STACK_DIR/tests/e2e/run.sh" | tr -d ' ')" = 1 ] || { echo "ST_IMAGES=1 beyond setup" >&2; return 1; }
  assert_contains "$r" '[ "${E2E_IMAGE_REUSE:-1}" = 0 ] || E2E_IMAGE_TREE="$(image_cache_tree)"'
}

# --- the browser suite's tidy-up after a Code page check that fails (tests/e2e/browser/code_tidy.py), against the Code
# page's mock backend (code/web/dev/mock-server.mjs: its limit of four open sessions, a question that waits for an
# answer); no browser, no stack ---
test_e2e_failed_code_check_closes_its_sessions_so_the_next_can_open_one() {
  command -v python3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 || { echo "no python3 or node" >&2; return 77; }
  [ -d "$STACK_DIR/code/web/node_modules/ws" ] || { echo "code/web has no node_modules (npm ci there): the mock backend needs ws" >&2; return 77; }
  local port pid rc=0
  # (the mock serves its preview site on PORT+100: both free, and below 65536 — an ephemeral port can be 65500)
  port="$(python3 -I -c '
import socket
for _ in range(500):
    s, t = socket.socket(), socket.socket()
    try:
        s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]
        if p + 100 < 65536:
            t.bind(("127.0.0.1", p + 100)); print(p); break
    except OSError:
        pass
    finally:
        s.close(); t.close()
')" && [ -n "$port" ] || return 1
  MOCK_QUIET=1 node "$STACK_DIR/code/web/dev/mock-server.mjs" --port "$port" --host 127.0.0.1 --fast > "$TMP/mock.log" 2>&1 &
  pid=$!
  cat > "$TMP/tidy.py" <<'PY'
import json, subprocess, sys, time, urllib.error, urllib.request
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import code_tidy
BASE = f"http://127.0.0.1:{sys.argv[2]}"

def api(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method, headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            status, text = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        status, text = e.code, e.read().decode()
    try:
        j = json.loads(text)
    except ValueError:
        j = None
    return {"status": status, "json": j, "text": text[:2000]}

def tracked(method, path, body=None):   # checks_code's Code.api: every answer noted
    r = api(method, path, body)
    code_tidy.note(method, path, r)
    return r

def opened():
    return {s["id"]: s for s in api("GET", "/api/state")["json"]["sessions"] if s["open"]}

def check(cond, what):
    if not cond:
        sys.exit(f"FAIL: {what}")

for _ in range(100):
    try:
        if api("GET", "/api/state")["status"] == 200:
            break
    except OSError:
        time.sleep(0.1)
else:
    sys.exit("FAIL: the mock backend did not start")
new = {"model": "claude-haiku-5-5", "mode": "default"}
# sessions the page opened itself (not through Code.api): one idle, one waiting for an answer to a question
keep = api("POST", "/api/sessions", new)["json"]["id"]
stuck = api("POST", "/api/sessions", new)["json"]["id"]
# (the page's WebSocket: ws, which the mock needs too — from code/web)
js = ("import WebSocket from 'ws'; const [port, sid] = process.argv.slice(1); const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);"
      "ws.on('open', () => { ws.send(JSON.stringify({ type: 'attach', session: sid, since: 0 }));"
      " ws.send(JSON.stringify({ type: 'prompt', session: sid, text: 'Ask me which retry policy to use' })); });"
      "setTimeout(() => process.exit(0), 1500);")
subprocess.run(["node", "--input-type=module", "-e", js, sys.argv[2], stuck], cwd=sys.argv[3], check=True, timeout=30)
t0 = time.time()
while time.time() - t0 < 10 and not (opened().get(stuck, {}).get("pending") or 0):
    time.sleep(0.1)
check(opened()[stuck]["state"] == "busy" and opened()[stuck]["pending"] == 1, f"the question is not waiting: {opened().get(stuck)}")
# a check opens two sessions through the page's API, then fails: the backend's limit is reached
mine = [tracked("POST", "/api/sessions", new)["json"]["id"] for _ in range(2)]
check(code_tidy.OPENED == set(mine), f"noted {code_tidy.OPENED}, opened {mine}")
r = tracked("POST", "/api/sessions", new)
check(r["status"] == 409 and "4 sessions are working or waiting for you" in r["text"], f"a fifth session without the tidy-up: {r}")
check(code_tidy.OPENED == set(mine), "a refused session was noted")
# the tidy-up: the check's two and the waiting one closed (that one stopped first), the idle one of the page kept
stopped = []
said = code_tidy.close_left(tracked, stopped.append)
check(stopped == [stuck], f"stopped {stopped}, not the waiting one only")
check(set(opened()) == {keep}, f"open after the tidy-up: {list(opened())} (want only {keep})")
check(said.startswith("closed 3 sessions it left: ") and f"{stuck[:8]} (busy, 1 waiting, stopped)" in said
      and all(f"{x[:8]} (idle)" in said for x in mine) and "still open" not in said, f"said {said!r}")
check(not code_tidy.OPENED, "OPENED kept after the tidy-up")
# the next check opens a session
r = tracked("POST", "/api/sessions", new)
check(r["status"] == 200, f"the next check's session: {r}")
code_tidy.OPENED.clear()   # (that check passed: what it left stays)
check(code_tidy.close_left(tracked) == "", "nothing was left, yet something was closed")
check(len(opened()) == 2, f"the idle sessions were closed: {list(opened())}")
# only a session opened is noted (…/continue too); a backend that does not answer: said, OPENED forgotten
sid = "0b5e5a4e-3c1d-4f6e-9a2b-7c8d9e0f1a2b"
code_tidy.note("POST", f"/api/sessions/{keep}/continue", {"status": 200, "json": {"id": sid}})
code_tidy.note("POST", "/api/projects", {"status": 200, "json": {"id": "1b5e5a4e-3c1d-4f6e-9a2b-7c8d9e0f1a2b"}})
code_tidy.note("GET", "/api/sessions", {"status": 200, "json": {"id": "2b5e5a4e-3c1d-4f6e-9a2b-7c8d9e0f1a2b"}})
code_tidy.note("POST", "/api/sessions", {"status": 200, "json": {"id": "../../etc"}})
check(code_tidy.OPENED == {sid}, f"noted {code_tidy.OPENED}")
try:
    code_tidy.close_left(lambda method, path: {"status": 502, "json": None, "text": "bad gateway"})
    sys.exit("FAIL: an unanswered /api/state was not said")
except RuntimeError as e:
    check("GET /api/state: 502" in str(e), f"said {e}")
check(not code_tidy.OPENED, "OPENED kept after a failed tidy-up")
print("ok:", said)
PY
  python3 -I "$TMP/tidy.py" "$STACK_DIR/tests/e2e/browser" "$port" "$STACK_DIR/code/web" > "$TMP/out" 2>&1 || rc=$?
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true   # (the mock: stopped either way)
  [ "$rc" = 0 ] || { cat "$TMP/out" "$TMP/mock.log" >&2; return 1; }
  assert_contains "$(cat "$TMP/out")" "ok: closed 3 sessions it left: "
}

# --- the layout sweep's own rules (tests/e2e/browser/layout_sweep.py; its measuring is the browser suite's
# browser/layout-no-overlap): which device measures which width, every allowlist entry reviewed (a reason, a check it
# names), a finding allowed only by an entry that matches it, workers' results merged as one; no browser ---
test_e2e_layout_sweep_widths_allowlist_and_merge() {
  command -v python3 >/dev/null 2>&1 || { echo "no python3" >&2; return 77; }
  cat > "$TMP/lay.py" <<'PY'
import json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import layout_sweep as L

def check(cond, what):
    if not cond:
        sys.exit(f"FAIL: {what}")

# widths: 320..1920 every 40 (41), phones under 768 with touch, tablets to 1099, the desktop from 1100 (full: also a
# narrowed desktop window from 768); the fast run's 12
check(L.FULL_WIDTHS[0] == 320 and L.FULL_WIDTHS[-1] == 1920 and len(L.FULL_WIDTHS) == 41, "full widths")
check(L.FAST_WIDTHS == [320, 360, 390, 600, 768, 820, 1024, 1100, 1280, 1366, 1440, 1920], "fast widths")
check(L.device_widths("phone", L.FULL_WIDTHS, "full") == list(range(320, 761, 40)), "phone widths")
check(L.device_widths("tablet", L.FAST_WIDTHS, "fast") == [768, 820, 1024], "tablet widths")
check(L.device_widths("desktop", L.FAST_WIDTHS, "fast") == [1024, 1100, 1280, 1366, 1440, 1920], "fast desktop widths")
check(L.device_widths("desktop", L.FULL_WIDTHS, "full")[0] == 800, "a narrowed desktop window in the full run")
check(L.DEVICES["phone"].get("has_touch") and L.DEVICES["tablet"].get("has_touch") and not L.DEVICES["desktop"], "touch")
c = L.Cfg(origin="http://x", password="p", out=None)
check(c.widths == L.FAST_WIDTHS and c.heights == [800], "fast by default")
c = L.Cfg(origin="http://x", password="p", out=None, mode="full")
check(c.heights == [600, 1000], "full heights")
# every reviewed entry: a reason and a check the sweep reports; its patterns compile
rows = json.loads(open(sys.argv[1] + "/layout-allowlist.json").read())
check(isinstance(rows, list), "the allowlist is a list")
for r in rows:
    check(isinstance(r, dict) and str(r.get("why", "")).strip(), f"an entry without its reason: {r}")
    check(r.get("check") in ("overlap", "clipped text", "squeezed", "sideways scroll", "small target", "unreachable"), f"unknown check: {r}")
    for k in ("sig", "state"):
        if r.get(k):
            import re; re.compile(r[k])
check(len(L.load_allowlist()) == len(rows), "every entry loaded")
# matching: the check, the signature and the state must all match
rows = [{"check": "overlap", "sig": r"^overlap\|code\|.*etab", "state": "^code", "why": "reviewed"}]
check(L.allowed(rows, "overlap", "overlap|code|div.etab > button|x", "code-page") == "reviewed", "a match")
check(L.allowed(rows, "small target", "overlap|code|div.etab > button|x", "code-page") is None, "another check")
check(L.allowed(rows, "overlap", "overlap|home|div.etab", "code-page") is None, "another signature")
check(L.allowed(rows, "overlap", "overlap|code|div.etab", "home") is None, "another state")
check(not L.load_allowlist() or all(r.get("why") for r in L.load_allowlist()), "no entry without a reason")
# a state's page: one finding per component and page, whatever the state
check(L.page_of("settings-providers") == "settings" and L.page_of("code-mock-session-permission") == "code" and L.page_of("home-details-open") == "home", "pages")
# a finding the sweep records is allowed by an entry whose sig names it as the summary prints it (its check first):
# the reviewed entries of layout-allowlist.json match the findings they were written for
sw = L.Sweep.__new__(L.Sweep)
sw.cfg = L.Cfg(origin="http://x", password="p", out=None, shots=False)
sw.findings, sw.allow = {}, L.load_allowlist()
at = lambda state: {"state": state, "device": "phone", "w": 320, "h": 800, "theme": "light"}
sw.add(None, "overlap", "control over control", "signin|form > div.pw-field > button#pw-toggle.pw-toggle|form > div.pw-field > input#password", at("signin"), a={"path": "p"}, detail="d")
sw.add(None, "clipped text", "ellipsis", "code|li[data-testid=session-row].sess > button.sess-main > span.sess-title", at("code-side-projects"), a={"path": "p"}, detail="d")
sw.add(None, "clipped text", "ellipsis", "code|div[data-testid=git-panel].gitp > label.gitr-repo.small > select[data-testid=git-repo]", at("code-side-git"), a={"path": "p"}, detail="d")
got = {k: v["allowed"] for k, v in sw.findings.items()}
check(got[next(k for k in got if k.startswith("overlap|signin"))] and got[next(k for k in got if k.endswith("span.sess-title"))], f"the reviewed entries match their findings: {got}")
check(not got[next(k for k in got if "git-repo" in k)], f"the Git panel's picker is no longer allowed to be cut (JON-512): {got}")
# workers' results: one finding seen by two is one, its sizes and states joined; the first screenshot kept
f = lambda **k: {"sig": "overlap|home|a|b", "check": "overlap", "allowed": False, "seen": 1, "widths": [], "heights": [800],
                 "themes": ["light"], "states": [], "devices": ["phone"], "shot": "", **k}
a = {"findings": [f(widths=[320], states=["home"], shot="shots/1.png")], "notes": [{"what": "x", "detail": "y"}], "counts": {"measurements": 4}, "secs": 3, "mode": "fast", "widths": [], "heights": [], "themes": []}
b = {"findings": [f(widths=[360, 320], states=["activity"], themes=["dark"]), f(sig="small target|home|c", check="small target")], "notes": [], "counts": {"measurements": 6}, "secs": 5}
m = L.merge([a, b])
check(len(m["findings"]) == 2 and m["counts"]["measurements"] == 10 and m["secs"] == 5 and len(m["notes"]) == 1, f"merged {m}")
o = next(x for x in m["findings"] if x["sig"] == "overlap|home|a|b")
check(o["widths"] == [320, 360] and o["states"] == ["activity", "home"] and o["themes"] == ["dark", "light"] and o["seen"] == 2 and o["shot"] == "shots/1.png", f"joined {o}")
print("ok")
PY
  python3 -I "$TMP/lay.py" "$STACK_DIR/tests/e2e/browser" > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_contains "$(cat "$TMP/out")" "ok"
}

test_e2e_a_check_cut_off_by_a_network_change_is_tried_once_more_and_says_so() {
  # (common.try_twice, taken out of tests/e2e/browser/common.py: the module itself only imports in the suite's container)
  cat > "$TMP/twice.py" <<'PY'
import ast, sys, traceback
src = open(sys.argv[1], encoding="utf-8").read()
fn = next(n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == "try_twice")
ns = {"traceback": traceback}
exec(compile(ast.Module([fn], []), "common.py", "exec"), ns)
try_twice = ns["try_twice"]

def check(cond, what):
    if not cond:
        print("FAIL:", what); sys.exit(1)

def runner(outcomes, changes):
    """each try: its outcome (a (status, msg) or an exception to raise), and how many network changes Chromium saw in it"""
    st = {"tries": 0, "changed": 0, "between": []}
    def run():
        i = st["tries"]; st["tries"] += 1
        st["changed"] += changes[i]
        if isinstance(outcomes[i], Exception):
            raise outcomes[i]
        return outcomes[i]
    return st, run, (lambda: st["changed"]), (lambda first: st["between"].append(first))

# a failure with no network change: a FAIL at once, tried once
st, run, changed, between = runner([AssertionError("pages without content")], [0])
status, msg, tb, first = try_twice(run, changed, between)
check((status, msg, first, st["tries"], st["between"]) == ("FAIL", "AssertionError: pages without content", "", 1, []), (status, msg, first, st))
check("AssertionError" in tb, "the traceback is kept")
# cut off by a network change, then passes: PASS, and the first failure is said
st, run, changed, between = runner([AssertionError("FAILED GET /static/login.css net::ERR_NETWORK_CHANGED"), ("PASS", "12 sections")], [3, 0])
status, msg, tb, first = try_twice(run, changed, between)
check((status, msg, tb, st["tries"]) == ("PASS", "12 sections", "", 2), (status, msg, st))
check(first == "AssertionError: FAILED GET /static/login.css net::ERR_NETWORK_CHANGED" and st["between"] == [first], (first, st))
# cut off twice: a FAIL after the second try, never a third
st, run, changed, between = runner([TimeoutError("timed out"), AssertionError("still")], [1, 1])
status, msg, tb, first = try_twice(run, changed, between)
check((status, msg, first, st["tries"]) == ("FAIL", "AssertionError: still", "TimeoutError: timed out", 2), (status, msg, first, st))
# a skip or a pass is never tried again
st, run, changed, between = runner([("SKIP", "no helper")], [2])
check(try_twice(run, changed, between) == ("SKIP", "no helper", "", "") and st["tries"] == 1, st)
print("ok")
PY
  python3 -I "$TMP/twice.py" "$STACK_DIR/tests/e2e/browser/common.py" > "$TMP/out" 2>&1 || { cat "$TMP/out" >&2; return 1; }
  assert_contains "$(cat "$TMP/out")" "ok"
}
