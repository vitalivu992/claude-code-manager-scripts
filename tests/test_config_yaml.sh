#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
source "$SCRIPT_DIR/test_helpers.sh"
source "$REPO_DIR/scripts/tmux-session.sh"

setup_test_env
# Point config home at the test home so we don't touch the real ~/.claude-code-manager
CFG_DIR="$TEST_HOME/.claude-code-manager"
mkdir -p "$CFG_DIR"
CFG="$CFG_DIR/config.yaml"

# Helper: write a fresh config.yaml
write_cfg() { printf '%s\n' "$1" > "$CFG"; }

# ---------------------------------------------------------------------------
describe "load_config — defaults when no config file"
# ---------------------------------------------------------------------------

it "AUTOCODE_CMD_GIT defaults to git"
rm -f "$CFG"
load_config
assert_eq "git" "$AUTOCODE_CMD_GIT"

it "AUTOCODE_GIT_PUSH defaults to true"
rm -f "$CFG"
load_config
assert_eq "true" "$AUTOCODE_GIT_PUSH"

it "AUTOCODE_EXECUTOR_IDLE_THRESHOLD defaults to 2"
rm -f "$CFG"
load_config
assert_eq "2" "$AUTOCODE_EXECUTOR_IDLE_THRESHOLD"

it "AUTOCODE_EXECUTOR_MAX_RESTARTS defaults to 3"
rm -f "$CFG"
load_config
assert_eq "3" "$AUTOCODE_EXECUTOR_MAX_RESTARTS"

it "AUTOCODE_INTERVAL defaults to 30"
rm -f "$CFG"
unset AUTOCODE_INTERVAL
load_config
assert_eq "30" "$AUTOCODE_INTERVAL"

# ---------------------------------------------------------------------------
describe "load_config — reads values from config.yaml"
# ---------------------------------------------------------------------------

it "reads git.command"
write_cfg "git:
  command: gh
  push: false
interval: 45
roles:
  executor:
    idle_threshold: 5
    max_restarts: 7
    commands:
      - claude"
load_config
assert_eq "gh" "$AUTOCODE_CMD_GIT"

it "reads git.push"
assert_eq "false" "$AUTOCODE_GIT_PUSH"

it "reads interval"
assert_eq "45" "$AUTOCODE_INTERVAL"

it "reads executor idle_threshold"
assert_eq "5" "$AUTOCODE_EXECUTOR_IDLE_THRESHOLD"

it "reads executor max_restarts"
assert_eq "7" "$AUTOCODE_EXECUTOR_MAX_RESTARTS"

# ---------------------------------------------------------------------------
describe "load_config — partial config keeps defaults for missing keys"
# ---------------------------------------------------------------------------

it "missing git block keeps default git command"
write_cfg "interval: 60"
load_config
assert_eq "git" "$AUTOCODE_CMD_GIT"

it "missing interval keeps default"
write_cfg "git:
  command: git"
unset AUTOCODE_INTERVAL
load_config
assert_eq "30" "$AUTOCODE_INTERVAL"

it "missing executor thresholds keep defaults"
write_cfg "roles:
  executor:
    commands:
      - claude"
load_config
assert_eq "2" "$AUTOCODE_EXECUTOR_IDLE_THRESHOLD"
assert_eq "3" "$AUTOCODE_EXECUTOR_MAX_RESTARTS"

# ---------------------------------------------------------------------------
describe "pick_cmd_for_role — no config file"
# ---------------------------------------------------------------------------

it "returns claude when config file missing"
rm -f "$CFG"
result=$(pick_cmd_for_role "executor")
assert_eq "claude" "$result"

# ---------------------------------------------------------------------------
describe "pick_cmd_for_role — single command"
# ---------------------------------------------------------------------------

it "returns the only command in a single-item list"
write_cfg "roles:
  planner:
    commands:
      - my-claude
  executor:
    commands:
      - claude"
result=$(pick_cmd_for_role "planner")
assert_eq "my-claude" "$result"

it "returns the only executor command"
result=$(pick_cmd_for_role "executor")
assert_eq "claude" "$result"

# ---------------------------------------------------------------------------
describe "pick_cmd_for_role — multiple commands"
# ---------------------------------------------------------------------------

it "returns one of the listed commands for a two-item list"
write_cfg "roles:
  executor:
    commands:
      - cmd-alpha
      - cmd-beta"
result=$(pick_cmd_for_role "executor")
if [ "$result" = "cmd-alpha" ] || [ "$result" = "cmd-beta" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ result is one of [cmd-alpha, cmd-beta]: $result"
else
    FAIL=$((FAIL + 1))
    echo "  ❌ unexpected result: '$result' (expected cmd-alpha or cmd-beta)"
fi

it "distributes across both commands over many calls"
write_cfg "roles:
  executor:
    commands:
      - cmd-a
      - cmd-b"
saw_a=false; saw_b=false
for i in $(seq 1 20); do
    r=$(pick_cmd_for_role "executor")
    [ "$r" = "cmd-a" ] && saw_a=true
    [ "$r" = "cmd-b" ] && saw_b=true
    $saw_a && $saw_b && break
done
if $saw_a && $saw_b; then
    PASS=$((PASS + 1))
    echo "  ✅ both commands appeared in up to 20 samples"
else
    FAIL=$((FAIL + 1))
    echo "  ❌ distribution test failed: saw_a=$saw_a saw_b=$saw_b"
fi

it "handles commands with spaces (flags)"
write_cfg "roles:
  executor:
    commands:
      - claude --model claude-opus-4-5
      - claude --model claude-sonnet-4-5"
result=$(pick_cmd_for_role "executor")
if [ "$result" = "claude --model claude-opus-4-5" ] || [ "$result" = "claude --model claude-sonnet-4-5" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ command with flags selected correctly: $result"
else
    FAIL=$((FAIL + 1))
    echo "  ❌ unexpected result for spaced command: '$result'"
fi

# ---------------------------------------------------------------------------
describe "pick_cmd_for_role — missing or empty role"
# ---------------------------------------------------------------------------

it "falls back to claude for a role not listed in config"
write_cfg "roles:
  executor:
    commands:
      - claude"
result=$(pick_cmd_for_role "reviewer")
assert_eq "claude" "$result"

it "falls back to claude for empty commands list"
write_cfg "roles:
  executor:
    commands: []"
result=$(pick_cmd_for_role "executor")
assert_eq "claude" "$result"

# ---------------------------------------------------------------------------
teardown_test_env
print_summary
