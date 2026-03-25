#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
source "$SCRIPT_DIR/test_helpers.sh"
source "$REPO_DIR/scripts/tmux-session.sh"

setup_test_env
cd "$TEST_REPO"

base=$(get_base_name "$TEST_REPO")
datadir="$HOME/.claude-auto-code"
prev_file="$datadir/${base}.EXECUTOR.log.prev"

# ---------------------------------------------------------------------------
# PATH-based mocks for tmux and sleep so subprocesses pick them up.
#
# Mock tmux reads from files in $MOCK_BIN:
#   .tmux-has-exit   : exit code for has-session (default 0 = exists)
#   .tmux-capture    : stdout for capture-pane
#   .tmux-killed     : kill-session appends session name here
#   .tmux-sent       : send-keys appends "SENDKEYS:<session>:<cmd>" here
# ---------------------------------------------------------------------------
MOCK_BIN="$TEST_HOME/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/tmux" << 'TMUX_EOF'
#!/bin/bash
MOCK_BIN="$(cd "$(dirname "$0")" && pwd)"
case "$1" in
    has-session)
        code=$(cat "$MOCK_BIN/.tmux-has-exit" 2>/dev/null); exit "${code:-0}" ;;
    capture-pane)
        cat "$MOCK_BIN/.tmux-capture" 2>/dev/null || true ;;
    kill-session)
        # tmux kill-session -t <name>
        echo "$3" >> "$MOCK_BIN/.tmux-killed" ;;
    send-keys)
        # tmux send-keys -t <session> <cmd> C-m
        echo "SENDKEYS:$3:$4" >> "$MOCK_BIN/.tmux-sent" ;;
    new-session)
        true ;;
    *)
        true ;;
esac
TMUX_EOF
chmod +x "$MOCK_BIN/tmux"

cat > "$MOCK_BIN/sleep" << 'SLEEP_EOF'
#!/bin/bash
true
SLEEP_EOF
chmod +x "$MOCK_BIN/sleep"

export PATH="$MOCK_BIN:$PATH"
export AUTOCODE_CMD_EXECUTOR="echo"

# Helpers
set_session_exists()  { echo 0 > "$MOCK_BIN/.tmux-has-exit"; }
set_session_missing() { echo 1 > "$MOCK_BIN/.tmux-has-exit"; }
set_capture()         { printf "%s" "$1" > "$MOCK_BIN/.tmux-capture"; }
clear_killed()        { rm -f "$MOCK_BIN/.tmux-killed"; }
clear_sent()          { rm -f "$MOCK_BIN/.tmux-sent"; }
session_was_killed()  { grep -qF "$1" "$MOCK_BIN/.tmux-killed" 2>/dev/null; }
sent_contains()       { grep -qF "$1" "$MOCK_BIN/.tmux-sent" 2>/dev/null; }

set_session_exists

EXECUTOR_SESSION="${base}-EXECUTOR"

# ---------------------------------------------------------------------------
describe "Idle counting — increments on idle without signal"
# ---------------------------------------------------------------------------

it "idle_count starts at 0, increments to 1 after first idle tick"
write_state "executor:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
write_meta "executor_idle_count" "0" "$TEST_REPO"
echo "stable" > "$prev_file"
set_capture "stable"
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 >/dev/null || true
result=$(read_meta "executor_idle_count" "$TEST_REPO")
assert_eq "1" "$result" "idle_count incremented to 1"

it "output mentions idle tick count"
write_state "executor:active" "$TEST_REPO"
write_meta "executor_idle_count" "0" "$TEST_REPO"
echo "stable" > "$prev_file"
set_capture "stable"
output=$(AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 || true)
echo "$output" | grep -q "Idle tick"
assert_exit_code "0" "$?" "prints idle tick message"

# ---------------------------------------------------------------------------
describe "Idle counting — resets on active session"
# ---------------------------------------------------------------------------

it "idle_count resets to 0 when session is not idle"
write_state "executor:active" "$TEST_REPO"
write_meta "executor_idle_count" "5" "$TEST_REPO"
echo "old output" > "$prev_file"
set_capture "new different output"
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 >/dev/null || true
result=$(read_meta "executor_idle_count" "$TEST_REPO")
assert_eq "0" "$result" "idle_count reset to 0 when active"

# ---------------------------------------------------------------------------
describe "Idle counting — resets on READY_FOR_REVIEW"
# ---------------------------------------------------------------------------

it "idle_count resets to 0 when READY_FOR_REVIEW is detected"
write_state "executor:active" "$TEST_REPO"
write_meta "executor_idle_count" "1" "$TEST_REPO"
# prev_file and capture must match for idle detection, and contain READY_FOR_REVIEW
echo "READY_FOR_REVIEW" > "$prev_file"
set_capture "READY_FOR_REVIEW"
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 >/dev/null || true
result_idle=$(read_meta "executor_idle_count" "$TEST_REPO")
assert_eq "0" "$result_idle" "idle_count reset to 0 on READY_FOR_REVIEW"

it "state transitions to executor:done on READY_FOR_REVIEW"
result_state=$(read_state "$TEST_REPO")
assert_eq "executor:done" "$result_state" "state set to executor:done"

# ---------------------------------------------------------------------------
describe "Restart trigger — at threshold"
# ---------------------------------------------------------------------------

it "kills EXECUTOR session when idle_count reaches threshold"
clear_killed
write_state "executor:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
write_meta "executor_idle_count" "1" "$TEST_REPO"
write_meta "executor_restart_count" "0" "$TEST_REPO"
write_meta "review_iteration" "0" "$TEST_REPO"
echo "stable" > "$prev_file"
set_capture "stable"
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 >/dev/null || true
session_was_killed "$EXECUTOR_SESSION"
assert_exit_code "0" "$?" "EXECUTOR session killed at threshold"

it "idle_count reset to 0 after restart"
result=$(read_meta "executor_idle_count" "$TEST_REPO")
assert_eq "0" "$result" "idle_count reset after restart"

it "restart_count incremented after restart"
result=$(read_meta "executor_restart_count" "$TEST_REPO")
assert_eq "1" "$result" "restart_count incremented to 1"

it ".log.prev removed on restart"
assert_file_not_exists "$prev_file" ".log.prev removed on restart"

it "state stays executor:active after restart"
result_state=$(read_state "$TEST_REPO")
assert_eq "executor:active" "$result_state" "state stays executor:active"

# ---------------------------------------------------------------------------
describe "Command selection on restart"
# ---------------------------------------------------------------------------

it "uses initial plan command when no gaps_path on restart"
clear_sent
write_state "executor:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
write_meta "executor_idle_count" "1" "$TEST_REPO"
write_meta "executor_restart_count" "0" "$TEST_REPO"
write_meta "review_iteration" "0" "$TEST_REPO"
# ensure no gaps_path in meta
meta_file="$datadir/${base}.meta"
grep -v "^gaps_path=" "$meta_file" > "${meta_file}.tmp" 2>/dev/null && mv "${meta_file}.tmp" "$meta_file" 2>/dev/null || true
echo "stable" > "$prev_file"
set_capture "stable"
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 >/dev/null || true
sent_contains "execute the plan"
assert_exit_code "0" "$?" "sends initial plan command on restart when no gaps"

it "uses gap-fix command when gaps_path set and review_iteration > 0 on restart"
clear_sent
write_state "executor:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
write_meta "gaps_path" "~/.claude/plans/gaps.md" "$TEST_REPO"
write_meta "review_iteration" "1" "$TEST_REPO"
write_meta "executor_idle_count" "1" "$TEST_REPO"
write_meta "executor_restart_count" "0" "$TEST_REPO"
echo "stable" > "$prev_file"
set_capture "stable"
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 >/dev/null || true
sent_contains "Fix implementation gaps"
assert_exit_code "0" "$?" "sends gap-fix command on restart when gaps_path set"

# ---------------------------------------------------------------------------
describe "Max restart bound"
# ---------------------------------------------------------------------------

it "stops workflow when restart_count exceeds max"
write_state "executor:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
write_meta "executor_idle_count" "1" "$TEST_REPO"
write_meta "executor_restart_count" "3" "$TEST_REPO"
echo "stable" > "$prev_file"
set_capture "stable"
output=$(AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 || true)
echo "$output" | grep -q "Max restarts"
assert_exit_code "0" "$?" "prints max restarts message"

it "clears state when max restarts exceeded"
result_state=$(read_state "$TEST_REPO")
assert_eq "" "$result_state" "state cleared after max restarts"

it "clears meta when max restarts exceeded"
result_meta=$(read_meta "plan_path" "$TEST_REPO")
assert_eq "" "$result_meta" "meta cleared after max restarts"

# ---------------------------------------------------------------------------
describe "Fresh session creation resets idle and restart counts"
# ---------------------------------------------------------------------------

it "executor_idle_count set to 0 on planner:done"
write_state "planner:done" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 >/dev/null || true
result=$(read_meta "executor_idle_count" "$TEST_REPO")
assert_eq "0" "$result" "executor_idle_count initialized to 0 on new session"

it "executor_restart_count set to 0 on planner:done"
result=$(read_meta "executor_restart_count" "$TEST_REPO")
assert_eq "0" "$result" "executor_restart_count initialized to 0 on new session"

# ---------------------------------------------------------------------------
teardown_test_env
print_summary
