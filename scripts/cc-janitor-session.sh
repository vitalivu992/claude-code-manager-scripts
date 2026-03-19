#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)
session_name="${base_name}-JANITOR"

LOCK_FILE="$datadir/${base_name}-JANITOR.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "🔒 Another JANITOR instance is running, exiting"; exit 0; }

executor_mail="$datadir/${base_name}-EXECUTOR.JANITOR.mail"

if [ ! -f "$executor_mail" ]; then
    echo "📭 No mail for JANITOR, exiting"
    exit 0
fi

mail_content=$(cat "$executor_mail")

if ! echo "$mail_content" | grep -q "REVIEWER_APPROVED"; then
    echo "❌ Unexpected mail content: $mail_content"
    rm -f "$executor_mail"
    exit 1
fi

echo "✅ REVIEWER_APPROVED received, starting JANITOR tasks"

if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "✅ JANITOR session exists"
    if ! is_session_idle "JANITOR"; then
        echo "⏳ JANITOR session is still active, exiting"
        exit 0
    fi

    echo "💤 JANITOR session is idle, checking output"
    output=$(capture_last_lines "JANITOR" 30)
    echo "$output"

    current_state=$(read_state)

    if [ "$current_state" = "janitor:git-commit" ]; then
        echo "💬 git-commit done, running git push"
        write_state "janitor:git-push"
        send_command "JANITOR" "$AUTOCODE_CMD_GIT push"
        exit 0
    fi

    if [ "$current_state" = "janitor:git-push" ]; then
        echo "🎉 git push done, cleaning up"
        rm -f "$executor_mail"
        rm -f "$datadir/${base_name}.EXECUTOR.plan"
        clear_state
        for lock in "$datadir/${base_name}"-*.lock; do
            [ -f "$lock" ] && rm -f "$lock"
        done
        echo "🧹 Terminating all workflow sessions..."
        for role in "PLANNER" "EXECUTOR" "REVIEWER" "JANITOR"; do
            role_session="${base_name}-${role}"
            if tmux has-session -t "$role_session" 2>/dev/null; then
                tmux kill-session -t "$role_session"
                echo "🛑 Killed session: $role_session"
            fi
        done
        exit 0
    fi

    echo "❓ Unknown state: $current_state, exiting"
    exit 0
fi

create_session "JANITOR"

write_state "janitor:git-commit"
send_command "JANITOR" "$AUTOCODE_CMD_JANITOR -p \"/git-commit\""
exit 0
