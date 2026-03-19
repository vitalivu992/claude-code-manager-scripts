#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)
session_name="${base_name}-REVIEWER"

LOCK_FILE="$datadir/${base_name}-REVIEWER.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "🔒 Another REVIEWER instance is running, exiting"; exit 0; }

executor_mail="$datadir/${base_name}-EXECUTOR.REVIEWER.mail"

if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "✅ REVIEWER session exists"
    if ! is_session_idle "REVIEWER"; then
        echo "⏳ REVIEWER session is still active, exiting"
        exit 0
    fi

    echo "💤 REVIEWER session is idle, checking output"
    output=$(capture_last_lines "REVIEWER" 30)

    plan_gaps_path=$(echo "$output" | grep "~/.claude/plans/" | awk '{print $NF}' | tail -1)
    plan_file_path=$(cat "$datadir/${base_name}.EXECUTOR.plan" 2>/dev/null)
    # must check if plan_gaps_path is not the same as plan_file_path
    if [ "$plan_gaps_path" == "$plan_file_path" ]; then
        echo "💤 Plan gap files was not created, waiting for the next round"
        exit 0
    fi
    if echo "$output" | grep -qE '^\s*REVIEWER_APPROVED\s*$'; then
        echo "📬 REVIEWER_APPROVED detected, writing to EXECUTOR mail"
        echo "REVIEWER_APPROVED" > "$datadir/${session_name}.EXECUTOR.mail"
        send_command "REVIEWER" "/exit"
        tmux kill-session -t "$session_name" 2>/dev/null
    elif [ -n "$plan_gaps_path" ]; then
        echo "📬 Plan gaps file detected: $plan_gaps_path, writing to EXECUTOR mail"
        echo "$plan_gaps_path" > "$datadir/${session_name}.EXECUTOR.mail"
        send_command "REVIEWER" "/exit"
        tmux kill-session -t "$session_name" 2>/dev/null
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
send_command "REVIEWER" "$AUTOCODE_CMD_REVIEWER"
sleep 10
send_command "REVIEWER" "/reviewer-review-impl-gaps $plan_file_path"
rm -f "$executor_mail"

exit 0
