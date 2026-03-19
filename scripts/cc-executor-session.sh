#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)

LOCK_FILE="$datadir/${base_name}.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "🔒 Another role is running, exiting EXECUTOR"; exit 0; }

current_state=$(read_state)
case "$current_state" in
    planner:done|executor:active|reviewer:gaps) ;;
    *) echo "Not EXECUTOR's turn (state: $current_state)"; exit 0 ;;
esac

session_name="${base_name}-EXECUTOR"

if [ "$current_state" = "executor:active" ]; then
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "❌ EXECUTOR session disappeared while state is executor:active"
        exit 1
    fi

    if ! is_session_idle "EXECUTOR"; then
        echo "⏳ EXECUTOR session is still active, exiting"
        exit 0
    fi

    echo "💤 EXECUTOR session is idle, checking output"
    output=$(tmux capture-pane -S -50 -p -t "$session_name" 2>/dev/null)
    echo "$output"
    if echo "$output" | grep -qE '^\s*READY_FOR_REVIEW\s*$'; then
        echo "📬 READY_FOR_REVIEW detected"
        write_state "executor:done"
        write_meta "updated_at" "$(date -Iseconds)"
        send_command "EXECUTOR" "/exit"
        tmux kill-session -t "$session_name" 2>/dev/null
    fi
    exit 0
fi

plan_file_path=$(read_meta "plan_path")
if [ -z "$plan_file_path" ]; then
    echo "❌ No plan_path in metadata"
    exit 1
fi

create_session "EXECUTOR"
send_command "EXECUTOR" "$AUTOCODE_CMD_EXECUTOR"
sleep 10

if [ "$current_state" = "reviewer:gaps" ]; then
    gaps_path=$(read_meta "gaps_path")
    review_iteration=$(read_meta "review_iteration")
    review_iteration=$((${review_iteration:-0} + 1))
    write_meta "review_iteration" "$review_iteration"
    send_command "EXECUTOR" "/ralph-loop:ralph-loop \"review the code changes, existing source code, documents and the plan $plan_file_path and the gaps documented and plan in $gaps_path, review if the gaps are valid or not, then fix the necessary gaps, make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW\" --completion-promise \"READY_FOR_REVIEW\""
else
    write_meta "review_iteration" "0"
    send_command "EXECUTOR" "/ralph-loop:ralph-loop \"review existing source code, documents and execute the plan $plan_file_path, make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW\" --completion-promise \"READY_FOR_REVIEW\""
fi

write_state "executor:active"
write_meta "updated_at" "$(date -Iseconds)"
exit 0
