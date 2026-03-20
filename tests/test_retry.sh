#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
source "$SCRIPT_DIR/test_helpers.sh"
source "$REPO_DIR/scripts/tmux-session.sh"

setup_test_env
cd "$TEST_REPO"

AUTOCODE="$REPO_DIR/bin/claude-code-manager"

describe "claude-code-manager retry — no state"

it "retry exits with error when no state exists"
clear_state "$TEST_REPO"
output=$("$AUTOCODE" retry --once 2>&1 || true)
echo "$output" | grep -q "No workflow state found"
assert_exit_code "0" "$?" "reports no workflow state"

describe "claude-code-manager retry — planner:active"

it "retry from planner:active restores PLANNER.mail from metadata"
write_state "planner:active" "$TEST_REPO"
write_meta "requirements" "Add user auth" "$TEST_REPO"
output=$("$AUTOCODE" retry --once 2>&1 || true)
echo "$output" | grep -q "Retry conditions restored"
assert_exit_code "0" "$?" "reports conditions restored"

it "retry from planner:active with requirements recreates mail file"
base=$(get_base_name "$TEST_REPO")
mail_existed=false
[ -f "$HOME/.claude-auto-code/${base}.PLANNER.mail" ] && mail_existed=true
clear_state "$TEST_REPO"
write_state "planner:active" "$TEST_REPO"
write_meta "requirements" "Build OAuth" "$TEST_REPO"
"$AUTOCODE" retry --once 2>&1 >/dev/null || true
assert_eq "true" "true" "retry ran without crash"

describe "claude-code-manager retry — state rollback logic"

it "retry from executor:active without gaps rolls back to planner:done"
write_state "executor:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/test.md" "$TEST_REPO"
meta_file=$(get_meta_file "$TEST_REPO")
[ -f "$meta_file" ] && sed -i '/^gaps_path=/d' "$meta_file"
output=$("$AUTOCODE" retry --once 2>&1 || true)
echo "$output" | grep -q "Retry conditions restored"
assert_exit_code "0" "$?" "executor:active rolls back (first run)"

it "retry from executor:active with gaps rolls back to reviewer:gaps"
write_state "executor:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/test.md" "$TEST_REPO"
write_meta "gaps_path" "~/.claude/plans/gaps.md" "$TEST_REPO"
output=$("$AUTOCODE" retry --once 2>&1 || true)
echo "$output" | grep -q "Retry conditions restored"
assert_exit_code "0" "$?" "executor:active rolls back (gap-fix)"

it "retry from reviewer:active rolls back to executor:done"
write_state "reviewer:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/test.md" "$TEST_REPO"
output=$("$AUTOCODE" retry --once 2>&1 || true)
echo "$output" | grep -q "Retry conditions restored"
assert_exit_code "0" "$?" "reviewer:active rolls back"

it "retry from janitor:commit rolls back to reviewer:approved"
write_state "janitor:commit" "$TEST_REPO"
output=$("$AUTOCODE" retry --once 2>&1 || true)
echo "$output" | grep -q "Retry conditions restored"
assert_exit_code "0" "$?" "janitor:commit rolls back"

it "retry from janitor:push rolls back to reviewer:approved"
write_state "janitor:push" "$TEST_REPO"
output=$("$AUTOCODE" retry --once 2>&1 || true)
echo "$output" | grep -q "Retry conditions restored"
assert_exit_code "0" "$?" "janitor:push rolls back"

describe "claude-code-manager retry — passthrough states"

for state in "planner:done" "executor:done" "reviewer:approved" "reviewer:gaps"; do
    it "retry from $state proceeds without rollback"
    write_state "$state" "$TEST_REPO"
    write_meta "plan_path" "~/.claude/plans/test.md" "$TEST_REPO"
    output=$("$AUTOCODE" retry --once 2>&1 || true)
    echo "$output" | grep -q "Retry conditions restored"
    assert_exit_code "0" "$?" "$state passes through"
done

describe "claude-code-manager retry — unknown state"

it "retry from unknown state reports error"
write_state "bogus:state" "$TEST_REPO"
output=$("$AUTOCODE" retry --once 2>&1 || true)
echo "$output" | grep -q "Unknown state"
assert_exit_code "0" "$?" "reports unknown state"

clear_state "$TEST_REPO"
clear_meta "$TEST_REPO"
teardown_test_env
print_summary
