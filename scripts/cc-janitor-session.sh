#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source $SCRIPT_DIR/tmux-session.sh

datadir="~/.ai-coding-team"
mkdir -p $datadir
current_dir=$(pwd)
base_name=$(get_base_name $current_dir)
session_name="${base_name}-JANITOR"

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

create_session "JANITOR"
send_command "JANITOR" "git-commit-generate"
send_command "JANITOR" "git push"

rm -f "$executor_mail"

echo "🧹 Terminating all workflow sessions..."
for role in "PLANNER" "EXECUTOR" "REVIEWER" "JANITOR"; do
    role_session="${base_name}-${role}"
    if tmux has-session -t "$role_session" 2>/dev/null; then
        tmux kill-session -t "$role_session"
        echo "🛑 Killed session: $role_session"
    fi
done

exit 0
