#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)

current_state=$(read_state)
case "$current_state" in
    ""|planner:active) ;;
    *) echo "Not PLANNER's turn (state: $current_state)"; exit 0 ;;
esac

acquire_role_lock "PLANNER" "$base_name" || exit 0

current_state=$(read_state)
case "$current_state" in
    ""|planner:active) ;;
    *) echo "Not PLANNER's turn (state: $current_state)"; exit 0 ;;
esac

session_name="${base_name}-PLANNER"

function start_planning_session() {
    echo "Entering the planning session..."
    if [ -f "$datadir/${base_name}.PLANNER.mail" ]; then
        requirements=$(cat "$datadir/${base_name}.PLANNER.mail")
        rm -f "$datadir/${base_name}.PLANNER.mail"
        write_meta "requirements" "$requirements"
        send_command "PLANNER" "$AUTOCODE_CMD_PLANNER"
        sleep 10
        send_command "PLANNER" "/planner-create-plan $requirements"
    else
        send_command "PLANNER" "$AUTOCODE_CMD_PLANNER /planner-auto-plan"
    fi
}

function extract_plan_file_path() {
    tmux capture-pane -S -200 -p -t "$session_name" 2>/dev/null | grep "~/.claude/plans/" | awk '{print $NF}' | tail -1
    return 0
}

if [ "$current_state" = "planner:active" ]; then
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "❌ PLANNER session disappeared while state is planner:active"
        exit 1
    fi

    if ! is_session_idle "PLANNER"; then
        echo "⏳ PLANNER session is still active"
        echo "🔎 to enter the PLANNER session, run tmux attach -t $session_name"
        exit 0
    fi

    echo "💤 PLANNER session is idle, extracting plan file path"
    plan_file_path=$(extract_plan_file_path)
    if [ -z "$plan_file_path" ]; then
        echo "❌ Failed to extract plan file path"
        exit 1
    fi
    echo "📄 plan file path: $plan_file_path"
    write_meta "plan_path" "$plan_file_path"
    write_state "planner:done"
    write_meta "updated_at" "$(date -Iseconds)"
    tmux kill-session -t "$session_name" 2>/dev/null
    exit 0
fi

echo "PLANNER session does not exist, creating..."
create_session "PLANNER"
if ! tmux has-session -t "$session_name" 2>/dev/null; then
    echo "❌ Failed to create PLANNER session"
    exit 1
fi
start_planning_session
write_state "planner:active"
write_meta "updated_at" "$(date -Iseconds)"
exit 0
