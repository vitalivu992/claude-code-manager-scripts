#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source $SCRIPT_DIR/tmux-session.sh

datadir="~/.ai-coding-team"
mkdir -p $datadir
current_dir=$(pwd)


function enter_planning_session() {
    echo "Entering the planning session..."
    if [ -f $datadir/$session_name.PLANNER.mail ]; then
        requirements=$(cat $datadir/$session_name.PLANNER.mail)
        send_command "PLANNER" "claude-zaiglm /planner-create-plan $requirements"
    else
        send_command "PLANNER" "claude-zaiglm /planner-auto-plan"
    fi
    capture_last_lines "PLANNER" 10
}


function extract_plan_file_path() {
    tmux capture-pane -S -200 -p -t "$session_name" 2>/dev/null | grep "~/.claude/plans/" | awk '{print $NF}' | tail -1
    return 0
}

for role in "EXECUTOR" "REVIEWER" "JANITOR"; do
    session_name=$(get_session_name "$role")
    if [ -n "$session_name" ]; then
        echo "❌ $role session exists"
        capture_last_lines $role 10
        echo "---"
        echo "🔎 to enter the $role session, run tmux attach -t $session_name"
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
    echo "$plan_file_path" > $datadir/$session_name.EXECUTOR.mail
fi

exit 0
