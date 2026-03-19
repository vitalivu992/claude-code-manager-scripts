#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/../scripts/tmux-session.sh"

setup_test_env

describe "State functions"

it "write_state and read_state round-trip"
write_state "planner:active" "$TEST_REPO"
result=$(read_state "$TEST_REPO")
assert_eq "planner:active" "$result"

it "write_state overwrites previous state"
write_state "executor:active" "$TEST_REPO"
result=$(read_state "$TEST_REPO")
assert_eq "executor:active" "$result"

it "read_state returns empty for non-existent state"
local_repo=$(mktemp -d)
result=$(read_state "$local_repo")
assert_empty "$result"
rmdir "$local_repo"

it "clear_state removes the state file"
write_state "janitor:commit" "$TEST_REPO"
clear_state "$TEST_REPO"
result=$(read_state "$TEST_REPO")
assert_empty "$result"

it "get_state_file returns correct path"
state_file=$(get_state_file "$TEST_REPO")
assert_eq "$HOME/.claude-auto-code/$(get_base_name "$TEST_REPO").state" "$state_file"

describe "Metadata functions"

it "write_meta and read_meta round-trip"
write_meta "plan_path" "~/.claude/plans/test.md" "$TEST_REPO"
result=$(read_meta "plan_path" "$TEST_REPO")
assert_eq "~/.claude/plans/test.md" "$result"

it "write_meta adds multiple keys"
write_meta "gaps_path" "~/.claude/plans/gaps.md" "$TEST_REPO"
write_meta "requirements" "Add auth" "$TEST_REPO"
result_gaps=$(read_meta "gaps_path" "$TEST_REPO")
result_req=$(read_meta "requirements" "$TEST_REPO")
assert_eq "~/.claude/plans/gaps.md" "$result_gaps" "read gaps_path"
assert_eq "Add auth" "$result_req" "read requirements"

it "write_meta overwrites existing key"
write_meta "plan_path" "~/.claude/plans/new.md" "$TEST_REPO"
result=$(read_meta "plan_path" "$TEST_REPO")
assert_eq "~/.claude/plans/new.md" "$result"

it "write_meta preserves other keys when overwriting"
result=$(read_meta "requirements" "$TEST_REPO")
assert_eq "Add auth" "$result"

it "read_meta returns empty for non-existent key"
result=$(read_meta "nonexistent" "$TEST_REPO")
assert_empty "$result"

it "read_meta returns empty for non-existent file"
local_repo=$(mktemp -d)
result=$(read_meta "plan_path" "$local_repo")
assert_empty "$result"
rmdir "$local_repo"

it "clear_meta removes the metadata file"
clear_meta "$TEST_REPO"
result=$(read_meta "plan_path" "$TEST_REPO")
assert_empty "$result"
assert_file_not_exists "$(get_meta_file "$TEST_REPO")" "meta file removed"

it "get_meta_file returns correct path"
meta_file=$(get_meta_file "$TEST_REPO")
assert_eq "$HOME/.claude-auto-code/$(get_base_name "$TEST_REPO").meta" "$meta_file"

describe "get_base_name"

it "converts path to base name using real path"
test_dir=$(mktemp -d)
expected=$(realpath "$test_dir" | tr '/' '-' | sed 's/^-//')
result=$(get_base_name "$test_dir")
assert_eq "$expected" "$result"
rmdir "$test_dir"

it "uses pwd when no argument given"
test_dir=$(mktemp -d)
result=$(cd "$test_dir" && get_base_name)
expected=$(realpath "$test_dir" | tr '/' '-' | sed 's/^-//')
assert_eq "$expected" "$result"
rmdir "$test_dir"

describe "State + Meta integration"

it "write_meta with review_iteration increment"
write_meta "review_iteration" "0" "$TEST_REPO"
iter=$(read_meta "review_iteration" "$TEST_REPO")
iter=$((iter + 1))
write_meta "review_iteration" "$iter" "$TEST_REPO"
result=$(read_meta "review_iteration" "$TEST_REPO")
assert_eq "1" "$result"

it "write_meta updated_at stores timestamp"
write_meta "updated_at" "2026-03-19T10:00:00+00:00" "$TEST_REPO"
result=$(read_meta "updated_at" "$TEST_REPO")
assert_eq "2026-03-19T10:00:00+00:00" "$result"

teardown_test_env
print_summary
