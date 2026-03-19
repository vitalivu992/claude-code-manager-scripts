#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)

LOCK_FILE="$datadir/${base_name}-PLANNER.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "🔒 Another PLANNER instance is running, exiting"; exit 0; }

function enter_planning_session() {
    echo "Entering the planning session..."
    if [ -f "$datadir/${base_name}.PLANNER.mail" ]; then
        requirements=$(cat "$datadir/${base_name}.PLANNER.mail")
        rm -f "$datadir/${base_name}.PLANNER.mail"
        send_command "PLANNER" "$AUTOCODE_CMD_PLANNER"
        sleep 10
        send_command "PLANNER" "/planner-create-plan $requirements"
    else
        send_command "PLANNER" "$AUTOCODE_CMD_PLANNER /planner-auto-plan"
    fi
}

function extract_plan_file_path() {
    local sn="${base_name}-PLANNER"
    tmux capture-pane -S -200 -p -t "$sn" 2>/dev/null | grep "~/.claude/plans/" | awk '{print $NF}' | tail -1
    return 0
}

for role in "EXECUTOR" "REVIEWER" "JANITOR"; do
    session_name=$(get_session_name "$role")
    if [ -n "$session_name" ]; then
        echo "❌ $role session exists"
        echo "  🔎 to enter the $role session, run tmux attach -t $session_name"
        exit 0
    fi
done

session_name=$(get_session_name "PLANNER")
if [ -z "$session_name" ]; then
    echo "PLANNER session does not exist, creating..."
    create_session "PLANNER"
    session_name=$(get_session_name "PLANNER")
    if [ -z "$session_name" ]; then
        echo "❌ Failed to create PLANNER session after 1st retry"
        exit 1
    fi
    enter_planning_session
else
    echo "✅ PLANNER session exists"
    if ! is_session_idle "PLANNER"; then
        echo "⏳ PLANNER session is still active"
        echo "🔎 to enter the PLANNER session, run tmux attach -t $session_name"
        exit 0
    fi

    echo "💤 PLANNER session is idle, extracting plan file path"
    plan_file_path=$(extract_plan_file_path)
    if [ -z "$plan_file_path" ]; then
        echo "❌ Failed to extract plan file path"
        # TODO inform user via telegram
        exit 1
    fi
    echo "📄 plan file path: $plan_file_path"
    echo "$plan_file_path" > "$datadir/${base_name}-PLANNER.EXECUTOR.mail"
    tmux kill-session -t "$session_name" 2>/dev/null
fi

exit 0
