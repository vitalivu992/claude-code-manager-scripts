#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source $SCRIPT_DIR/tmux-session.sh

datadir="~/.ai-coding-team"
mkdir -p $datadir
current_dir=$(pwd)
base_name=$(get_base_name $current_dir)
session_name="${base_name}-REVIEWER"

executor_mail="$datadir/${base_name}-EXECUTOR.REVIEWER.mail"

if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "✅ REVIEWER session exists"
    if ! is_session_idle "REVIEWER"; then
        echo "⏳ REVIEWER session is still active, exiting"
        exit 0
    fi

    echo "💤 REVIEWER session is idle, checking output"
    output=$(tmux capture-pane -S -50 -p -t "$session_name" 2>/dev/null)
    echo "$output"

    plan_gaps_path=$(echo "$output" | grep "~/.claude/plans/" | awk '{print $NF}' | tail -1)
    if echo "$output" | grep -q "REVIEWER_APPROVED"; then
        echo "📬 REVIEWER_APPROVED detected, writing to EXECUTOR mail"
        echo "REVIEWER_APPROVED" > "$datadir/${session_name}.EXECUTOR.mail"
    elif [ -n "$plan_gaps_path" ]; then
        echo "📬 Plan gaps file detected: $plan_gaps_path, writing to EXECUTOR mail"
        echo "$plan_gaps_path" > "$datadir/${session_name}.EXECUTOR.mail"
    fi
    exit 0
fi

if [ ! -f "$executor_mail" ]; then
    echo "📭 No mail for REVIEWER, exiting"
    exit 0
fi

plan_file_path=$(cat "$executor_mail")
if [ -z "$plan_file_path" ]; then
    echo "❌ EXECUTOR mail is empty"
    rm -f "$executor_mail"
    exit 1
fi

create_session "REVIEWER"
send_command "REVIEWER" "claude-zaiglm /reviewer-review-impl-gaps $plan_file_path"
rm -f "$executor_mail"

exit 0
