# shellcheck shell=bash
# lib/model_browser.sh: when the update helper reads the model browser's lists (model_browser_tick, each loop).
. "$STACK_DIR/lib/commands.sh"

# _mb_fake — ./stack is a fake that notes each "models browse" it is asked for ($TMP/reads), and the lock is free
_mb_fake() {
  mkdir -p "$TMP/fake" "$(helper_dir)" "$(request_dir)"
  printf '#!/bin/sh\necho "$*" >> "%s/reads"\n' "$TMP" > "$TMP/fake/stack"; chmod +x "$TMP/fake/stack"
  STACK_DIR="$TMP/fake"
  stack_lock_holder() { :; }
}
_mb_reads() { local n; sleep 0.3; n="$(grep -c 'models browse' "$TMP/reads" 2>/dev/null)"; echo "${n:-0}"; }

test_a_stack_with_no_list_read_reads_them_once_by_itself() {
  _mb_fake
  model_browser_tick
  assert_eq "$(_mb_reads)" 1      # the first open of the page finds the lists there
  model_browser_tick
  assert_eq "$(_mb_reads)" 1      # once: after that, only when the page asks
  : > "$(model_browser_wanted_file)"
  model_browser_tick
  assert_eq "$(_mb_reads)" 1      # and a request a moment later waits out MODEL_BROWSER_TICK_MIN
}

test_a_request_reads_the_lists_and_is_spent() {
  _mb_fake; echo 1767225600 > "$(helper_dir)/model-browser-last"; touch -t 202601010000 "$(helper_dir)/model-browser-last"
  : > "$(model_browser_wanted_file)"
  model_browser_tick
  assert_eq "$(_mb_reads)" 1
  [ ! -e "$(model_browser_wanted_file)" ]
}

test_a_request_waits_while_the_stack_is_busy_and_is_not_lost() {
  _mb_fake; echo 1767225600 > "$(helper_dir)/model-browser-last"; touch -t 202601010000 "$(helper_dir)/model-browser-last"
  : > "$(model_browser_wanted_file)"
  stack_lock_holder() { echo "4242 update"; }
  model_browser_tick
  assert_eq "$(_mb_reads)" 0
  [ -e "$(model_browser_wanted_file)" ]   # kept for the next loop
  stack_lock_holder() { :; }
  model_browser_tick
  assert_eq "$(_mb_reads)" 1
}

test_a_request_waits_while_a_read_runs() {
  _mb_fake; echo 1767225600 > "$(helper_dir)/model-browser-last"; touch -t 202601010000 "$(helper_dir)/model-browser-last"
  : > "$(model_browser_wanted_file)"
  sleep 30 & echo "$!" > "$(helper_dir)/model-browser.pid"
  model_browser_tick
  kill "$(cat "$(helper_dir)/model-browser.pid")" 2>/dev/null; wait 2>/dev/null
  assert_eq "$(_mb_reads)" 0
  [ -e "$(model_browser_wanted_file)" ]
}

test_requests_are_read_at_most_every_tick_minutes() {
  _mb_fake; date +%s > "$(helper_dir)/model-browser-last"   # a read just now
  : > "$(model_browser_wanted_file)"
  model_browser_tick
  assert_eq "$(_mb_reads)" 0
  [ ! -e "$(model_browser_wanted_file)" ]   # (read a moment ago: nothing new to read)
}
