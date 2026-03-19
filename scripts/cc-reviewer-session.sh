#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)

current_state=$(read_state)
case "$current_state" in
    executor:done|reviewer:active) ;;
    *) echo "Not REVIEWER's turn (state: $current_state)"; exit 0 ;;
esac

acquire_role_lock "REVIEWER" "$base_name" || exit 0

current_state=$(read_state)
case "$current_state" in
    executor:done|reviewer:active) ;;
    *) echo "Not REVIEWER's turn (state: $current_state)"; exit 0 ;;
esac

session_name="${base_name}-REVIEWER"

if [ "$current_state" = "reviewer:active" ]; then
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "❌ REVIEWER session disappeared while state is reviewer:active"
        exit 1
    fi

    if ! is_session_idle "REVIEWER"; then
        echo "⏳ REVIEWER session is still active, exiting"
        exit 0
    fi

    echo "💤 REVIEWER session is idle, checking output"
    output=$(capture_last_lines "REVIEWER" 50)
    echo "$output"|sed 's/^/>>> /'

    if echo "$output" | grep -qE '^\s*REVIEWER_APPROVED\s*$'; then
        echo "📬 REVIEWER_APPROVED detected"
        write_state "reviewer:approved"
        write_meta "updated_at" "$(date -Iseconds)"
        send_command "REVIEWER" "/exit"
        tmux kill-session -t "$session_name" 2>/dev/null
        exit 0
    fi

    plan_file_path=$(read_meta "plan_path")
    plan_gaps_path=$(echo "$output" | grep "~/.claude/plans/" | awk '{print $NF}' | tail -1)
    if [ "$plan_gaps_path" == "$plan_file_path" ]; then
        echo "💤 Plan gap files was not created, waiting for the next round"
        exit 0
    fi
    if [ -n "$plan_gaps_path" ]; then
        echo "📬 Plan gaps file detected: $plan_gaps_path"
        write_meta "gaps_path" "$plan_gaps_path"
        write_state "reviewer:gaps"
        write_meta "updated_at" "$(date -Iseconds)"
        send_command "REVIEWER" "/exit"
        tmux kill-session -t "$session_name" 2>/dev/null
    fi
    exit 0
fi

plan_file_path=$(read_meta "plan_path")
if [ -z "$plan_file_path" ]; then
    echo "❌ No plan_path in metadata"
    exit 1
fi

create_session "REVIEWER"
send_command "REVIEWER" "$AUTOCODE_CMD_REVIEWER"
sleep 10
send_command "REVIEWER" "/reviewer-review-impl-gaps $plan_file_path"

write_state "reviewer:active"
write_meta "updated_at" "$(date -Iseconds)"

exit 0
