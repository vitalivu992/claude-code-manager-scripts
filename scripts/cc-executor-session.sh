#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)
session_name="${base_name}-EXECUTOR"

LOCK_FILE="$datadir/${base_name}-EXECUTOR.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "🔒 Another EXECUTOR instance is running, exiting"; exit 0; }

planner_mail="$datadir/${base_name}-PLANNER.EXECUTOR.mail"
reviewer_mail="$datadir/${base_name}-REVIEWER.EXECUTOR.mail"
executor_plan="$datadir/${base_name}.EXECUTOR.plan"

if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "✅ EXECUTOR session exists"
    if ! is_session_idle "EXECUTOR"; then
        echo "⏳ EXECUTOR session is still active, exiting"
        exit 0
    fi

    echo "💤 EXECUTOR session is idle, checking output"
    output=$(tmux capture-pane -S -50 -p -t "$session_name" 2>/dev/null)
    echo "$output"
    if echo "$output" | grep -qE '^\s*READY_FOR_REVIEW\s*$'; then
        plan_file_path=$(cat "$executor_plan" 2>/dev/null)
        if [ -n "$plan_file_path" ]; then
            echo "📬 READY_FOR_REVIEW detected, writing to REVIEWER mail"
            echo "$plan_file_path" > "$datadir/${session_name}.REVIEWER.mail"
            send_command "EXECUTOR" "/exit"
            tmux kill-session -t "$session_name" 2>/dev/null
        else
            echo "❌ Could not find plan file path to write to REVIEWER mail"
        fi
    fi
    exit 0
fi

if [ -f "$reviewer_mail" ]; then
    mail_content=$(cat "$reviewer_mail")

    if echo "$mail_content" | grep -q "REVIEWER_APPROVED"; then
        echo "✅ REVIEWER_APPROVED received, forwarding to JANITOR"
        echo "REVIEWER_APPROVED" > "$datadir/${session_name}.JANITOR.mail"
        rm -f "$reviewer_mail"
        exit 0
    fi

    if echo "$mail_content" | grep -q "~/.claude/plans/"; then
        plan_gaps_file_path=$(echo "$mail_content" | grep "~/.claude/plans/" | awk '{print $NF}')
        plan_file_path=$(cat "$executor_plan" 2>/dev/null)

        if [ -z "$plan_file_path" ]; then
            echo "❌ Could not find original plan file path from $executor_plan"
            rm -f "$reviewer_mail"
            exit 1
        fi

        create_session "EXECUTOR"
        send_command "EXECUTOR" "$AUTOCODE_CMD_EXECUTOR"
        sleep 10
        send_command "EXECUTOR" "/ralph-loop:ralph-loop \"review the code changes, existing source code, documents and the plan $plan_file_path and the gaps documented and plan in $plan_gaps_file_path, review if the gaps are valid or not, then fix the necessary gaps, make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW\" --completion-promise \"READY_FOR_REVIEW\""
        rm -f "$reviewer_mail"
        exit 0
    fi

    echo "❌ Unexpected content in REVIEWER mail: $mail_content"
    rm -f "$reviewer_mail"
    exit 1
fi

if [ -f "$planner_mail" ]; then
    plan_file_path=$(cat "$planner_mail" | grep "~/.claude/plans/" | awk '{print $NF}')
    if [ -z "$plan_file_path" ]; then
        echo "❌ Could not extract plan file path from PLANNER mail"
        # TODO inform user via telegram
        exit 1
    fi

    echo "$plan_file_path" > "$executor_plan"

    create_session "EXECUTOR"
    send_command "EXECUTOR" "$AUTOCODE_CMD_EXECUTOR"
    sleep 10
    send_command "EXECUTOR" "/ralph-loop:ralph-loop \"review existing source code, documents and execute the plan $plan_file_path, make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW\" --completion-promise \"READY_FOR_REVIEW\""
    rm -f "$planner_mail"
    exit 0
fi

echo "📭 No mail for EXECUTOR, exiting"
exit 0
