#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)

LOCK_FILE="$datadir/${base_name}.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "🔒 Another role is running, exiting JANITOR"; exit 0; }

current_state=$(read_state)
case "$current_state" in
    reviewer:approved|janitor:commit|janitor:push) ;;
    *) echo "Not JANITOR's turn (state: $current_state)"; exit 0 ;;
esac

session_name="${base_name}-JANITOR"

if [ "$current_state" = "reviewer:approved" ]; then
    echo "✅ REVIEWER_APPROVED, starting JANITOR tasks"
    create_session "JANITOR"
    write_state "janitor:commit"
    write_meta "updated_at" "$(date -Iseconds)"
    send_command "JANITOR" "$AUTOCODE_CMD_JANITOR -p \"/git-commit\""
    exit 0
fi

if ! tmux has-session -t "$session_name" 2>/dev/null; then
    echo "❌ JANITOR session disappeared while state is $current_state"
    exit 1
fi

if ! is_session_idle "JANITOR"; then
    echo "⏳ JANITOR session is still active, exiting"
    exit 0
fi

echo "💤 JANITOR session is idle, checking state"
output=$(capture_last_lines "JANITOR" 30)
echo "$output"

if [ "$current_state" = "janitor:commit" ]; then
    echo "💬 git-commit done, running git push"
    write_state "janitor:push"
    write_meta "updated_at" "$(date -Iseconds)"
    send_command "JANITOR" "$AUTOCODE_CMD_GIT push"
    exit 0
fi

if [ "$current_state" = "janitor:push" ]; then
    echo "🎉 git push done, cleaning up"
    clear_state
    clear_meta
    rm -f "$datadir/${base_name}.lock"
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

exit 0
