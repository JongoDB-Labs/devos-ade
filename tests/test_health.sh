# shellcheck shell=bash
# shellcheck disable=SC2329,SC2034  # stubs are called by the code under test; HEALTH_EVENTS_MAX is read by lib/health.sh
# Local container health (lib/health.sh, JON-440 G4): restart counts, exit codes and unhealthy transitions recorded
# into .state/status/container-health.json for Activity. A synthetic, disposable failure: a stand-in Docker answers
# what `docker inspect` would for a container that restarts, goes unhealthy and exits; no real container is touched
# (tests/e2e/container-health.sh does the same with real disposable containers). Nothing here is sent anywhere.
. "$STACK_DIR/lib/commands.sh"   # also sources lib/health.sh

_hl_env() { mkdir -p "$STATE_DIR"; printf 'AWS_REGION_NAME=us-east-1\n' > "$ENV_FILE"; }
_ev() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(json.dumps(d["events"], sort_keys=True))' "$(health_json_file)"; }

test_a_healthy_stack_records_no_events() {
  _hl_env
  health_record_write "$(printf 'litellm|0|running|0|healthy|false|0001-01-01T00:00:00Z\nrustfs-init|0|exited|0||false|2026-10-27T10:00:00.5Z\n')"
  assert_eq "$(perm_of "$(health_json_file)")" 644
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))
assert d["version"] == 1 and d["events"] == [], d
assert [r["service"] for r in d["services"]] == ["litellm", "rustfs-init"], d' "$(health_json_file)"
}

test_a_restart_an_unhealthy_turn_and_a_failed_exit_are_each_recorded_once() {
  _hl_env
  health_record_write "$(printf 'litellm|0|running|0|healthy|false|0001-01-01T00:00:00Z\nportal|0|running|0|healthy|false|0001-01-01T00:00:00Z\ncaddy|0|running|0|none|false|0001-01-01T00:00:00Z\n')"
  # the failure: litellm restarted twice, portal turned unhealthy, caddy exited with code 3
  local bad
  bad="$(printf 'litellm|2|running|0|healthy|false|2026-10-27T10:00:00Z\nportal|0|running|0|unhealthy|false|0001-01-01T00:00:00Z\ncaddy|0|exited|3||false|2026-10-27T10:01:00Z\n')"
  health_record_write "$bad"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); e = {(x["service"], x["kind"]): x for x in d["events"]}
assert set(e) == {("litellm", "restart"), ("portal", "unhealthy"), ("caddy", "exit")}, e
assert e[("litellm", "restart")]["count"] == 2 and e[("caddy", "exit")]["exit_code"] == 3, e
assert all(x["at"] > 1_700_000_000 for x in d["events"]), e' "$(health_json_file)"
  # seen again unchanged: not counted again (dedupe)
  health_record_write "$bad"; health_record_write "$bad"
  assert_eq "$(_ev | python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)))')" 3
  # one more restart: only the difference
  health_record_write "$(printf 'litellm|5|running|0|healthy|false|2026-10-27T10:00:00Z\nportal|0|running|0|unhealthy|false|0001-01-01T00:00:00Z\ncaddy|0|exited|3||false|2026-10-27T10:01:00Z\n')"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))
r = [x["count"] for x in d["events"] if x["service"] == "litellm"]
assert r == [2, 3], d' "$(health_json_file)"
  # recovered then unhealthy again: a new transition
  health_record_write "$(printf 'portal|0|running|0|healthy|false|0001-01-01T00:00:00Z\n')"
  health_record_write "$(printf 'portal|0|running|0|unhealthy|false|0001-01-01T00:00:00Z\n')"
  assert_eq "$(python3 -I -c 'import json, sys; print(sum(1 for x in json.load(open(sys.argv[1]))["events"] if x["kind"] == "unhealthy"))' "$(health_json_file)")" 2
}

test_a_clean_stop_and_a_recreated_container_are_not_failures() {
  _hl_env
  health_record_write "$(printf 'litellm|4|running|0|healthy|false|0001-01-01T00:00:00Z\n')"   # first look: 4 restarts already counted
  assert_eq "$(_ev | python3 -I -c 'import json, sys; print([(x["kind"], x["count"]) for x in json.load(sys.stdin)])')" "[('restart', 4)]"
  # docker stop (143), a one-shot that finished (0), and a killed one (137 without memory) are not exits; ./stack down+up
  # (the count starts over) is not a restart
  health_record_write "$(printf 'litellm|0|exited|143|healthy|false|2026-10-27T11:00:00Z\nrustfs-init|0|exited|0||false|2026-10-27T11:00:01Z\nsearxng|0|exited|137||false|2026-10-27T11:00:02Z\n')"
  assert_eq "$(_ev | python3 -I -c 'import json, sys; print(len(json.load(sys.stdin)))')" 1
  # killed for memory: recorded
  health_record_write "$(printf 'searxng|0|exited|137||true|2026-10-27T11:05:00Z\n')"
  assert_contains "$(_ev)" '"kind": "oom"'
}

test_only_docker_words_reach_the_record_and_a_silent_docker_writes_nothing() {
  _hl_env
  health_record_write "$(printf 'evil"}|1|run"ning|0\\n|healthy<x>|false|2026\n')"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); assert d["services"][0]["service"] == "other" and d["services"][0]["state"] == "running", d' "$(health_json_file)"
  before="$(cat "$(health_json_file)")"
  health_record_write ""
  assert_eq "$(cat "$(health_json_file)")" "$before"
  docker() { return 1; }
  health_record_write
  assert_eq "$(cat "$(health_json_file)")" "$before"
}

test_the_event_log_is_capped_and_the_service_status_write_calls_it() {
  _hl_env
  local i
  HEALTH_EVENTS_MAX=5
  for i in 1 2 3 4 5 6 7 8; do health_record_write "$(printf 'portal|%s|running|0|healthy|false|0001-01-01T00:00:00Z\n' "$i")"; done
  assert_eq "$(python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1]))["events"]))' "$(health_json_file)")" 5
  assert_contains "$(sed -n '/^services_status_write()/,/^}/p' "$STACK_DIR/lib/commands.sh")" "health_record_write"
  # local only: no network tool anywhere in it
  assert_eq "$(grep -cE '\b(curl|wget|nc|ssh)\b' "$STACK_DIR/lib/health.sh" | tr -d ' ' || true)" 0
}

test_services_status_write_also_records_health() {
  _hl_env
  docker() {
    case "$*" in
      *" ps -a --format "*) printf 'litellm\trunning\thealthy\n' ;;
      *" ps -a -q"*) printf 'abc123abc123\n' ;;
      inspect*) printf 'litellm|3|running|0|healthy|false|0001-01-01T00:00:00Z\n' ;;
    esac
  }
  services_status_write
  assert_contains "$(cat "$(health_json_file)")" '"kind": "restart", "count": 3'
}

test_only_the_stacks_own_services_are_named_and_anything_else_is_other() {
  _hl_env
  health_record_write "$(printf 'litellm|0|running|0|healthy|false|0001-01-01T00:00:00Z\nmy-secret-project-db|0|running|0|healthy|false|0001-01-01T00:00:00Z\nother-thing|0|running|0|healthy|false|0001-01-01T00:00:00Z\n')"
  health_record_write "$(printf 'litellm|0|running|0|healthy|false|0001-01-01T00:00:00Z\nmy-secret-project-db|2|running|0|healthy|false|0001-01-01T00:00:00Z\nother-thing|0|exited|9|healthy|false|2026-10-27T10:00:00Z\n')"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))
e = sorted((x["service"], x["kind"], x["count"], x["exit_code"]) for x in d["events"])
assert e == [("other", "exit", 0, 9), ("other", "restart", 2, 0)], e   # two different strangers: each its own baseline
assert sorted(r["service"] for r in d["services"]) == ["litellm", "other", "other"], d' "$(health_json_file)"
  local f
  for f in "$(health_json_file)" "$STATE_DIR/status/container-events.tsv"; do assert_not_contains "$(cat "$f")" "secret-project"; done
}

test_the_subject_set_is_the_compose_files_services() {
  local want got
  want="$(cd "$STACK_DIR" && for f in compose*.yaml; do awk '/^services:/{s=1;next} /^[a-z]/{s=0} s&&/^  [a-z][a-z0-9_-]*:/{sub(":","",$1);print $1}' "$f"; done | sort -u | tr '\n' ' ')"
  got="$(printf '%s\n' $HEALTH_SERVICES | sort -u | tr '\n' ' ')"
  assert_eq "$got" "$want"
  # the contract lists the same set and the same step names (lib/*.sh timed_step literals)
  local svc step doc="$STACK_DIR/docs/event-schema.md"
  for svc in $HEALTH_SERVICES other; do assert_contains "$(cat "$doc")" "\`$svc\`"; done
  grep -ho 'timed_step "[^"]*"' "$STACK_DIR"/lib/*.sh | sed 's/^timed_step "//; s/"$//' | sort -u > "$TMP/steps"
  while IFS= read -r step; do assert_contains "$(cat "$doc")" "\`$step\`"; done < "$TMP/steps"
}

test_event_rows_never_change_once_written() {
  _hl_env
  local ev="$STATE_DIR/status/container-events.tsv" before
  health_record_write "$(printf 'portal|0|running|0|healthy|false|0001-01-01T00:00:00Z\n')"
  health_record_write "$(printf 'portal|2|running|0|unhealthy|false|0001-01-01T00:00:00Z\n')"
  before="$(cat "$ev")"
  sleep 1   # (the clock moves on: the old rows keep their time, count and exit code)
  health_record_write "$(printf 'portal|2|running|0|unhealthy|false|0001-01-01T00:00:00Z\n')"
  health_record_write "$(printf 'portal|3|exited|5|healthy|false|2026-10-27T10:00:00Z\n')"
  assert_eq "$(head -n "$(printf '%s\n' "$before" | wc -l | tr -d ' ')" "$ev")" "$before"
  # (restart events carry the exit code Docker had then, an oom its own as reported)
  health_record_write "$(printf 'caddy|0|exited|137|healthy|true|2026-10-27T11:00:00Z\n')"
  assert_contains "$(cat "$ev")" "|caddy|oom|0|137"
}
