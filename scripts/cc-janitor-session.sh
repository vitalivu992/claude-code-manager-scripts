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

create_session "JANITOR"

send_command "JANITOR" "$AUTOCODE_CMD_JANITOR -p \"/git-commit\""
sleep 3
while ! is_session_idle "JANITOR"; do sleep 5; done

send_command "JANITOR" "$AUTOCODE_CMD_GIT push"
sleep 3
while ! is_session_idle "JANITOR"; do sleep 5; done

rm -f "$executor_mail"
rm -f "$datadir/${base_name}.EXECUTOR.plan"
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
