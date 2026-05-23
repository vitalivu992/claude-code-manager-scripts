#!/bin/bash
# End-to-end tests: verify each role script sends a command from its configured list
# Uses the same PATH-mock pattern as test_executor_idle_restart.sh
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
source "$SCRIPT_DIR/test_helpers.sh"
source "$REPO_DIR/scripts/tmux-session.sh"

setup_test_env
cd "$TEST_REPO"

base=$(get_base_name "$TEST_REPO")
datadir="$HOME/.claude-auto-code"

# ---------------------------------------------------------------------------
# Build mock bin directory (same pattern as test_executor_idle_restart.sh)
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
        echo "$3" >> "$MOCK_BIN/.tmux-killed" ;;
    send-keys)
        # tmux send-keys -t <session> <cmd> C-m  →  args: $2=-t $3=<session> $4=<cmd>
        echo "SENDKEYS:$3:$4" >> "$MOCK_BIN/.tmux-sent" ;;
    new-session)
        # After a new-session, mark has-session as succeeding so send_command can proceed
        echo 0 > "$MOCK_BIN/.tmux-has-exit"
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

# Delegate to real yq (needed for pick_cmd_for_role and load_config)
YQ_REAL=$(command -v yq)
cat > "$MOCK_BIN/yq" << YQEOF
#!/bin/bash
"$YQ_REAL" "\$@"
YQEOF
chmod +x "$MOCK_BIN/yq"

export PATH="$MOCK_BIN:$PATH"
export AUTOCODE_CLAUDE_PROMPT_TIMEOUT=4   # 2 poll cycles with no-op sleep in tests

# Config dir inside TEST_HOME so we don't touch real config
CFG_DIR="$TEST_HOME/.claude-code-manager"
mkdir -p "$CFG_DIR"
CFG="$CFG_DIR/config.yaml"

# Helpers
set_session_exists()  { echo 0 > "$MOCK_BIN/.tmux-has-exit"; }
set_session_missing() { echo 1 > "$MOCK_BIN/.tmux-has-exit"; }
set_capture()         { printf "%s" "$1" > "$MOCK_BIN/.tmux-capture"; }
clear_sent()          { rm -f "$MOCK_BIN/.tmux-sent"; }
first_sendkeys_cmd()  {
    # Extract the <cmd> part (field after second colon) from first SENDKEYS line
    head -1 "$MOCK_BIN/.tmux-sent" 2>/dev/null | cut -d: -f3-
}
sent_contains()       { grep -qF "$1" "$MOCK_BIN/.tmux-sent" 2>/dev/null; }

set_session_missing   # sessions don't exist yet → role scripts will create them

# ---------------------------------------------------------------------------
describe "PLANNER — picks command from config list"
# ---------------------------------------------------------------------------

it "planner uses first command from single-item list"
cat > "$CFG" << 'YAML'
roles:
  planner:
    commands:
      - my-planner-cmd
YAML
clear_sent
clear_state "$TEST_REPO"
mkdir -p "$(pwd)/.git"
"$REPO_DIR/scripts/cc-planner-session.sh" 2>/dev/null || true
sent_contains "my-planner-cmd"
assert_exit_code "0" "$?" "PLANNER sends my-planner-cmd"

it "planner selects a command from a two-item list"
cat > "$CFG" << 'YAML'
roles:
  planner:
    commands:
      - planner-cmd-a
      - planner-cmd-b
YAML
saw_any=false
for i in $(seq 1 5); do
    clear_sent
    clear_state "$TEST_REPO"
    set_session_missing
    "$REPO_DIR/scripts/cc-planner-session.sh" 2>/dev/null || true
    if sent_contains "planner-cmd-a" || sent_contains "planner-cmd-b"; then
        saw_any=true
        break
    fi
done
if $saw_any; then
    PASS=$((PASS + 1))
    echo "  ✅ PLANNER selected a command from the list"
else
    FAIL=$((FAIL + 1))
    echo "  ❌ PLANNER did not select from list"
fi

# ---------------------------------------------------------------------------
describe "EXECUTOR — picks command from config list on fresh start"
# ---------------------------------------------------------------------------

it "executor uses command from single-item list on planner:done"
cat > "$CFG" << 'YAML'
roles:
  executor:
    commands:
      - my-executor-cmd
    idle_threshold: 2
    max_restarts: 3
YAML
clear_sent
write_state "planner:done" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
set_session_missing
"$REPO_DIR/scripts/cc-executor-session.sh" 2>/dev/null || true
sent_contains "my-executor-cmd"
assert_exit_code "0" "$?" "EXECUTOR sends my-executor-cmd on planner:done"

it "executor selects a command from two-item list on fresh session"
cat > "$CFG" << 'YAML'
roles:
  executor:
    commands:
      - exec-cmd-a
      - exec-cmd-b
    idle_threshold: 2
    max_restarts: 3
YAML
saw_any=false
for i in $(seq 1 5); do
    clear_sent
    clear_meta "$TEST_REPO"
    write_state "planner:done" "$TEST_REPO"
    write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
    set_session_missing
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>/dev/null || true
    if sent_contains "exec-cmd-a" || sent_contains "exec-cmd-b"; then
        saw_any=true
        break
    fi
done
if $saw_any; then
    PASS=$((PASS + 1))
    echo "  ✅ EXECUTOR selected from list"
else
    FAIL=$((FAIL + 1))
    echo "  ❌ EXECUTOR did not select from list"
fi

# ---------------------------------------------------------------------------
describe "EXECUTOR — picks command on restart"
# ---------------------------------------------------------------------------

prev_file="$datadir/${base}.EXECUTOR.log.prev"

it "executor restart uses command from list"
cat > "$CFG" << 'YAML'
roles:
  executor:
    commands:
      - restart-cmd-x
      - restart-cmd-y
    idle_threshold: 2
    max_restarts: 3
YAML
write_state "executor:active" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
write_meta "executor_idle_count" "1" "$TEST_REPO"
write_meta "executor_restart_count" "0" "$TEST_REPO"
write_meta "review_iteration" "0" "$TEST_REPO"
echo "stable" > "$prev_file"
set_capture "stable"
set_session_exists
clear_sent
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2 AUTOCODE_EXECUTOR_MAX_RESTARTS=3 \
    "$REPO_DIR/scripts/cc-executor-session.sh" 2>/dev/null || true
cmd=$(first_sendkeys_cmd)
if [ "$cmd" = "restart-cmd-x" ] || [ "$cmd" = "restart-cmd-y" ]; then
    PASS=$((PASS + 1))
    echo "  ✅ EXECUTOR restart sent: $cmd"
else
    FAIL=$((FAIL + 1))
    echo "  ❌ EXECUTOR restart sent unexpected: '$cmd'"
fi

# ---------------------------------------------------------------------------
describe "REVIEWER — picks command from config list"
# ---------------------------------------------------------------------------

it "reviewer uses command from single-item list"
cat > "$CFG" << 'YAML'
roles:
  reviewer:
    commands:
      - my-reviewer-cmd
YAML
clear_sent
write_state "executor:done" "$TEST_REPO"
write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
set_session_missing
"$REPO_DIR/scripts/cc-reviewer-session.sh" 2>/dev/null || true
sent_contains "my-reviewer-cmd"
assert_exit_code "0" "$?" "REVIEWER sends my-reviewer-cmd"

it "reviewer selects a command from two-item list"
cat > "$CFG" << 'YAML'
roles:
  reviewer:
    commands:
      - reviewer-cmd-a
      - reviewer-cmd-b
YAML
saw_any=false
for i in $(seq 1 5); do
    clear_sent
    clear_meta "$TEST_REPO"
    write_state "executor:done" "$TEST_REPO"
    write_meta "plan_path" "~/.claude/plans/plan.md" "$TEST_REPO"
    set_session_missing
    "$REPO_DIR/scripts/cc-reviewer-session.sh" 2>/dev/null || true
    if sent_contains "reviewer-cmd-a" || sent_contains "reviewer-cmd-b"; then
        saw_any=true
        break
    fi
done
if $saw_any; then
    PASS=$((PASS + 1))
    echo "  ✅ REVIEWER selected from list"
else
    FAIL=$((FAIL + 1))
    echo "  ❌ REVIEWER did not select from list"
fi

# ---------------------------------------------------------------------------
describe "JANITOR — picks command from config list"
# ---------------------------------------------------------------------------

it "janitor uses command from single-item list"
cat > "$CFG" << 'YAML'
roles:
  janitor:
    commands:
      - my-janitor-cmd
git:
  command: git
  push: false
YAML
clear_sent
write_state "reviewer:approved" "$TEST_REPO"
set_session_missing
"$REPO_DIR/scripts/cc-janitor-session.sh" 2>/dev/null || true
sent_contains "my-janitor-cmd"
assert_exit_code "0" "$?" "JANITOR sends my-janitor-cmd"

it "janitor selects a command from two-item list"
cat > "$CFG" << 'YAML'
roles:
  janitor:
    commands:
      - janitor-cmd-a
      - janitor-cmd-b
git:
  command: git
  push: false
YAML
saw_any=false
for i in $(seq 1 5); do
    clear_sent
    write_state "reviewer:approved" "$TEST_REPO"
    set_session_missing
    "$REPO_DIR/scripts/cc-janitor-session.sh" 2>/dev/null || true
    if sent_contains "janitor-cmd-a" || sent_contains "janitor-cmd-b"; then
        saw_any=true
        break
    fi
done
if $saw_any; then
    PASS=$((PASS + 1))
    echo "  ✅ JANITOR selected from list"
else
    FAIL=$((FAIL + 1))
    echo "  ❌ JANITOR did not select from list"
fi

# ---------------------------------------------------------------------------
describe "Fallback — no config file uses claude"
# ---------------------------------------------------------------------------

it "roles fall back to claude when config.yaml is missing"
rm -f "$CFG"
result=$(pick_cmd_for_role "executor")
assert_eq "claude" "$result"

# ---------------------------------------------------------------------------
clear_state "$TEST_REPO"
clear_meta "$TEST_REPO"
teardown_test_env
print_summary
