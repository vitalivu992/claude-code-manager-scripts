#!/bin/bash
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/tmux-session.sh"
load_config

datadir="$HOME/.claude-auto-code"
mkdir -p "$datadir"
base_name=$(get_base_name)

current_state=$(read_state)
case "$current_state" in
    planner:done|executor:active|reviewer:gaps) ;;
    *) echo "Not EXECUTOR's turn (state: $current_state)"; exit 0 ;;
esac

acquire_role_lock "EXECUTOR" "$base_name" || exit 0

current_state=$(read_state)
case "$current_state" in
    planner:done|executor:active|reviewer:gaps) ;;
    *) echo "Not EXECUTOR's turn (state: $current_state)"; exit 0 ;;
esac

session_name="${base_name}-EXECUTOR"

if [ "$current_state" = "executor:active" ]; then
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "❌ EXECUTOR session disappeared while state is executor:active"
        exit 1
    fi

    if ! is_session_idle "EXECUTOR"; then
        write_meta "executor_idle_count" "0"
        echo "⏳ EXECUTOR session is still active, exiting"
        exit 0
    fi

    echo "💤 EXECUTOR session is idle, checking output"
    output=$(tmux capture-pane -S -50 -p -t "$session_name" 2>/dev/null)
    echo "$output"
    if echo "$output" | sed 's/●/ /' | grep -qE '^\s*READY_FOR_REVIEW\s*$'; then
        echo "📬 READY_FOR_REVIEW detected"
        write_meta "executor_idle_count" "0"
        write_state "executor:done"
        write_meta "updated_at" "$(date -Iseconds)"
        rm -f "$(pwd)/.claude/ralph-loop.local.md"
        send_command "EXECUTOR" "/exit"
        tmux kill-session -t "$session_name" 2>/dev/null
        exit 0
    fi

    # Increment consecutive idle counter
    idle_count=$(read_meta "executor_idle_count")
    idle_count=$(( ${idle_count:-0} + 1 ))
    write_meta "executor_idle_count" "$idle_count"

    if [ "$idle_count" -lt "$AUTOCODE_EXECUTOR_IDLE_THRESHOLD" ]; then
        echo "Idle tick $idle_count/$AUTOCODE_EXECUTOR_IDLE_THRESHOLD, waiting..."
        exit 0
    fi

    # Threshold reached — check restart bound
    restart_count=$(read_meta "executor_restart_count")
    restart_count=$(( ${restart_count:-0} + 1 ))

    if [ "$restart_count" -gt "$AUTOCODE_EXECUTOR_MAX_RESTARTS" ]; then
        echo "Max restarts ($AUTOCODE_EXECUTOR_MAX_RESTARTS) reached. Stopping."
        clear_state
        clear_meta
        for role in PLANNER EXECUTOR REVIEWER JANITOR; do
            tmux kill-session -t "${base_name}-${role}" 2>/dev/null
        done
        exit 0
    fi

    echo "Consecutive idle threshold reached, restarting (restart $restart_count/$AUTOCODE_EXECUTOR_MAX_RESTARTS)"
    tmux kill-session -t "$session_name" 2>/dev/null
    rm -f "$datadir/${base_name}.EXECUTOR.log.prev"
    rm -f "$(pwd)/.claude/ralph-loop.local.md"
    write_meta "executor_idle_count" "0"
    write_meta "executor_restart_count" "$restart_count"
    write_meta "updated_at" "$(date -Iseconds)"

    plan_file_path=$(read_meta "plan_path")
    gaps_path=$(read_meta "gaps_path")
    review_iteration=$(read_meta "review_iteration")

    restart_cmd=$(pick_cmd_for_role "executor")
    create_session "EXECUTOR"
    send_command "EXECUTOR" "$restart_cmd"
    wait_for_claude_prompt "EXECUTOR"

    if [ -n "$gaps_path" ] && [ "${review_iteration:-0}" -gt 0 ]; then
        send_command "EXECUTOR" "/ralph-loop:ralph-loop \"Fix implementation gaps. PRIMARY plan to implement: $gaps_path (this is the revised plan — it supersedes the original). Background context — original plan: $plan_file_path. Review the code changes against the gaps plan, validate which gaps are legitimate, then fix them. Make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW\" --completion-promise \"READY_FOR_REVIEW\""
    else
        send_command "EXECUTOR" "/ralph-loop:ralph-loop \"review existing source code, documents and execute the plan $plan_file_path, make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW\" --completion-promise \"READY_FOR_REVIEW\""
    fi
    # State stays executor:active — no state change needed
    exit 0
fi

plan_file_path=$(read_meta "plan_path")
if [ -z "$plan_file_path" ]; then
    echo "❌ No plan_path in metadata"
    exit 1
fi

# Early check for max iterations (before creating any session)
if [ "$current_state" = "reviewer:gaps" ]; then
    gaps_path=$(read_meta "gaps_path")
    review_iteration=$(read_meta "review_iteration")
    review_iteration=$((${review_iteration:-0} + 1))
    if [ "$review_iteration" -gt 3 ]; then
        echo "⚠️ Max review iterations (3) reached. Stopping workflow for manual review."
        echo "   Original plan: $plan_file_path"
        echo "   Latest gaps plan: $gaps_path"
        clear_state
        clear_meta
        for role in "PLANNER" "EXECUTOR" "REVIEWER" "JANITOR"; do
            role_session="${base_name}-${role}"
            if tmux has-session -t "$role_session" 2>/dev/null; then
                tmux kill-session -t "$role_session"
                echo "🛑 Killed session: $role_session"
            fi
        done
        exit 0
    fi
fi

fresh_cmd=$(pick_cmd_for_role "executor")
create_session "EXECUTOR"
send_command "EXECUTOR" "$fresh_cmd"
wait_for_claude_prompt "EXECUTOR"
write_meta "executor_idle_count" "0"
write_meta "executor_restart_count" "0"

if [ "$current_state" = "reviewer:gaps" ]; then
    write_meta "review_iteration" "$review_iteration"
    send_command "EXECUTOR" "/ralph-loop:ralph-loop \"Fix implementation gaps. PRIMARY plan to implement: $gaps_path (this is the revised plan — it supersedes the original). Background context — original plan: $plan_file_path. Review the code changes against the gaps plan, validate which gaps are legitimate, then fix them. Make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW\" --completion-promise \"READY_FOR_REVIEW\""
else
    write_meta "review_iteration" "0"
    send_command "EXECUTOR" "/ralph-loop:ralph-loop \"review existing source code, documents and execute the plan $plan_file_path, make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW\" --completion-promise \"READY_FOR_REVIEW\""
fi

write_state "executor:active"
write_meta "updated_at" "$(date -Iseconds)"
exit 0
