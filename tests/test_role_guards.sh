#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
source "$SCRIPT_DIR/test_helpers.sh"
source "$REPO_DIR/scripts/tmux-session.sh"

setup_test_env
cd "$TEST_REPO"

describe "PLANNER role guard"

it "PLANNER runs when state is empty"
clear_state "$TEST_REPO"
output=$("$REPO_DIR/scripts/cc-planner-session.sh" 2>&1 || true)
echo "$output" | grep -qv "Not PLANNER's turn"
assert_exit_code "0" "$?" "does not reject empty state"

it "PLANNER runs when state is planner:active"
write_state "planner:active" "$TEST_REPO"
output=$("$REPO_DIR/scripts/cc-planner-session.sh" 2>&1 || true)
echo "$output" | grep -qv "Not PLANNER's turn"
assert_exit_code "0" "$?" "does not reject planner:active"

for state in "planner:done" "executor:active" "executor:done" "reviewer:active" "reviewer:approved" "reviewer:gaps" "janitor:commit" "janitor:push"; do
    it "PLANNER rejects state: $state"
    write_state "$state" "$TEST_REPO"
    output=$("$REPO_DIR/scripts/cc-planner-session.sh" 2>&1 || true)
    echo "$output" | grep -q "Not PLANNER's turn"
    assert_exit_code "0" "$?" "rejects $state"
done

describe "EXECUTOR role guard"

for state in "planner:done" "executor:active" "reviewer:gaps"; do
    it "EXECUTOR accepts state: $state"
    write_state "$state" "$TEST_REPO"
    output=$("$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 || true)
    echo "$output" | grep -qv "Not EXECUTOR's turn"
    assert_exit_code "0" "$?" "does not reject $state"
done

for state in "" "planner:active" "executor:done" "reviewer:active" "reviewer:approved" "janitor:commit" "janitor:push"; do
    it "EXECUTOR rejects state: '${state:-empty}'"
    if [ -z "$state" ]; then
        clear_state "$TEST_REPO"
    else
        write_state "$state" "$TEST_REPO"
    fi
    output=$("$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 || true)
    echo "$output" | grep -q "Not EXECUTOR's turn"
    assert_exit_code "0" "$?" "rejects '${state:-empty}'"
done

describe "REVIEWER role guard"

for state in "executor:done" "reviewer:active"; do
    it "REVIEWER accepts state: $state"
    write_state "$state" "$TEST_REPO"
    output=$("$REPO_DIR/scripts/cc-reviewer-session.sh" 2>&1 || true)
    echo "$output" | grep -qv "Not REVIEWER's turn"
    assert_exit_code "0" "$?" "does not reject $state"
done

for state in "" "planner:active" "planner:done" "executor:active" "reviewer:approved" "reviewer:gaps" "janitor:commit" "janitor:push"; do
    it "REVIEWER rejects state: '${state:-empty}'"
    if [ -z "$state" ]; then
        clear_state "$TEST_REPO"
    else
        write_state "$state" "$TEST_REPO"
    fi
    output=$("$REPO_DIR/scripts/cc-reviewer-session.sh" 2>&1 || true)
    echo "$output" | grep -q "Not REVIEWER's turn"
    assert_exit_code "0" "$?" "rejects '${state:-empty}'"
done

describe "JANITOR role guard"

for state in "reviewer:approved" "janitor:commit" "janitor:push"; do
    it "JANITOR accepts state: $state"
    write_state "$state" "$TEST_REPO"
    output=$("$REPO_DIR/scripts/cc-janitor-session.sh" 2>&1 || true)
    echo "$output" | grep -qv "Not JANITOR's turn"
    assert_exit_code "0" "$?" "does not reject $state"
done

for state in "" "planner:active" "planner:done" "executor:active" "executor:done" "reviewer:active" "reviewer:gaps"; do
    it "JANITOR rejects state: '${state:-empty}'"
    if [ -z "$state" ]; then
        clear_state "$TEST_REPO"
    else
        write_state "$state" "$TEST_REPO"
    fi
    output=$("$REPO_DIR/scripts/cc-janitor-session.sh" 2>&1 || true)
    echo "$output" | grep -q "Not JANITOR's turn"
    assert_exit_code "0" "$?" "rejects '${state:-empty}'"
done

describe "EXECUTOR max iteration guard"

it "EXECUTOR exits when review_iteration would exceed 3"
write_state "reviewer:gaps" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
write_meta "gaps_path" "~/.claude/plans/gaps.md" "$TEST_REPO"
write_meta "review_iteration" "3" "$TEST_REPO"
output=$("$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 || true)
echo "$output" | grep -q "Max review iterations"
assert_exit_code "0" "$?" "exits at iteration 4 (review_iteration=3 → 4)"
result_state=$(read_state "$TEST_REPO")
assert_eq "" "$result_state" "state cleared after max iterations"

it "EXECUTOR proceeds at review_iteration 3 (last allowed)"
write_state "reviewer:gaps" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
write_meta "gaps_path" "~/.claude/plans/gaps.md" "$TEST_REPO"
write_meta "review_iteration" "2" "$TEST_REPO"
output=$("$REPO_DIR/scripts/cc-executor-session.sh" 2>&1 || true)
echo "$output" | grep -qv "Max review iterations"
assert_exit_code "0" "$?" "proceeds at iteration 3 (review_iteration=2 → 3)"

clear_state "$TEST_REPO"
teardown_test_env
print_summary
