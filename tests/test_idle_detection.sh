#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
source "$SCRIPT_DIR/test_helpers.sh"
source "$REPO_DIR/scripts/tmux-session.sh"

setup_test_env

# ---------------------------------------------------------------------------
# Mock tmux: has-session always succeeds (session "exists"); capture-pane
# returns $MOCK_OUTPUT. Tests override these as needed.
# ---------------------------------------------------------------------------
MOCK_OUTPUT="line one
line two
line three"

tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane) printf "%s\n" "$MOCK_OUTPUT" ;;
        *) command tmux "$@" 2>/dev/null || true ;;
    esac
}

# Helper: derive the datadir prefix used by is_session_idle
base=$(get_base_name "$TEST_REPO")
datadir="$HOME/.claude-auto-code"
prev_file="$datadir/${base}.EXECUTOR.log.prev"
log_file="$datadir/${base}.EXECUTOR.log"

# ---------------------------------------------------------------------------
describe "is_session_idle — first tick (no prev log)"
# ---------------------------------------------------------------------------

it "returns 1 (not idle) on first tick"
rm -f "$prev_file" "$log_file"
MOCK_OUTPUT="some session output"
is_session_idle "EXECUTOR" "$TEST_REPO"
assert_exit_code "1" "$?" "returns not-idle on first tick"

it "creates .log.prev after first tick"
assert_file_exists "$prev_file" ".log.prev exists after first tick"

it "does not leave .log after first tick (rotated to .log.prev)"
assert_file_not_exists "$log_file" ".log rotated away after first tick"

it ".log.prev contains the captured output"
content=$(cat "$prev_file")
assert_eq "some session output" "$content" ".log.prev has current snapshot"

# ---------------------------------------------------------------------------
describe "is_session_idle — idle detection (same content)"
# ---------------------------------------------------------------------------

it "returns 0 when pane output unchanged since last tick"
echo "stable output" > "$prev_file"
MOCK_OUTPUT="stable output"
is_session_idle "EXECUTOR" "$TEST_REPO"
assert_exit_code "0" "$?" "returns idle when content unchanged"

it "does not leave .log after idle check (rotated)"
assert_file_not_exists "$log_file" ".log rotated after idle check"

it ".log.prev updated with latest snapshot after idle"
content=$(cat "$prev_file")
assert_eq "stable output" "$content" ".log.prev still has stable content"

# ---------------------------------------------------------------------------
describe "is_session_idle — active detection (different content)"
# ---------------------------------------------------------------------------

it "returns 1 when pane output changed since last tick"
echo "old output" > "$prev_file"
MOCK_OUTPUT="new output from running session"
is_session_idle "EXECUTOR" "$TEST_REPO"
assert_exit_code "1" "$?" "returns not-idle when content changed"

it "does not leave .log after active check (rotated)"
assert_file_not_exists "$log_file" ".log rotated after active check"

it ".log.prev updated to latest snapshot after active check"
content=$(cat "$prev_file")
assert_eq "new output from running session" "$content" ".log.prev updated to new snapshot"

# ---------------------------------------------------------------------------
describe "is_session_idle — session does not exist"
# ---------------------------------------------------------------------------

it "returns 0 when tmux session is missing"
rm -f "$prev_file" "$log_file"
# Override tmux to report session missing for this test
tmux() {
    case "$1" in
        has-session) return 1 ;;
        capture-pane) printf "%s\n" "$MOCK_OUTPUT" ;;
        *) command tmux "$@" 2>/dev/null || true ;;
    esac
}
is_session_idle "EXECUTOR" "$TEST_REPO"
assert_exit_code "0" "$?" "idle when session does not exist"

it "does not create log files when session is missing"
assert_file_not_exists "$prev_file" "no .log.prev when session missing"
assert_file_not_exists "$log_file" "no .log when session missing"

# Restore mock
tmux() {
    case "$1" in
        has-session) return 0 ;;
        capture-pane) printf "%s\n" "$MOCK_OUTPUT" ;;
        *) command tmux "$@" 2>/dev/null || true ;;
    esac
}

# ---------------------------------------------------------------------------
describe "is_session_idle — log file cleanup (JANITOR pattern)"
# ---------------------------------------------------------------------------

it "cleanup loop removes .log and .log.prev for all roles"
for role in "PLANNER" "EXECUTOR" "REVIEWER" "JANITOR"; do
    touch "$datadir/${base}.${role}.log"
    touch "$datadir/${base}.${role}.log.prev"
done

for role in "PLANNER" "EXECUTOR" "REVIEWER" "JANITOR"; do
    rm -f "$datadir/${base}.${role}.log" "$datadir/${base}.${role}.log.prev"
done

all_gone=true
for role in "PLANNER" "EXECUTOR" "REVIEWER" "JANITOR"; do
    [ -f "$datadir/${base}.${role}.log" ] && all_gone=false
    [ -f "$datadir/${base}.${role}.log.prev" ] && all_gone=false
done
assert_eq "true" "$all_gone" "all .log and .log.prev files removed"

# ---------------------------------------------------------------------------
teardown_test_env
print_summary
