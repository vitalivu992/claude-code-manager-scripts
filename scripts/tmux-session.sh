#!/bin/bash
# Hands-on tmux scripting for your repo workflow (PLANNER / EXECUTOR / REVIEWER)

get_state_file() {
    local repo_path="${1:-$(pwd)}"
    local base=$(get_base_name "$repo_path")
    echo "$HOME/.claude-auto-code/${base}.state"
}

read_state() {
    local repo_path="${1:-$(pwd)}"
    cat "$(get_state_file "$repo_path")" 2>/dev/null || true
}

write_state() {
    local state="$1"
    local repo_path="${2:-$(pwd)}"
    echo "$state" > "$(get_state_file "$repo_path")"
}

clear_state() {
    local repo_path="${1:-$(pwd)}"
    rm -f "$(get_state_file "$repo_path")"
}

get_meta_file() {
    local repo_path="${1:-$(pwd)}"
    local base=$(get_base_name "$repo_path")
    echo "$HOME/.claude-auto-code/${base}.meta"
}

write_meta() {
    local key="$1"
    local value="$2"
    local repo_path="${3:-$(pwd)}"
    local meta_file
    meta_file=$(get_meta_file "$repo_path")
    if [ -f "$meta_file" ] && grep -q "^${key}=" "$meta_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$meta_file"
    else
        echo "${key}=${value}" >> "$meta_file"
    fi
}

read_meta() {
    local key="$1"
    local repo_path="${2:-$(pwd)}"
    local meta_file
    meta_file=$(get_meta_file "$repo_path")
    grep "^${key}=" "$meta_file" 2>/dev/null | cut -d= -f2- || true
}

clear_meta() {
    local repo_path="${1:-$(pwd)}"
    rm -f "$(get_meta_file "$repo_path")"
}

load_config() {
    local config_file="$HOME/.claude-auto-code/config"
    [ -f "$config_file" ] && source "$config_file"
    AUTOCODE_CMD_PLANNER="${AUTOCODE_CMD_PLANNER:-claude}"
    AUTOCODE_CMD_EXECUTOR="${AUTOCODE_CMD_EXECUTOR:-claude}"
    AUTOCODE_CMD_REVIEWER="${AUTOCODE_CMD_REVIEWER:-claude}"
    AUTOCODE_CMD_JANITOR="${AUTOCODE_CMD_JANITOR:-claude}"
    AUTOCODE_CMD_GIT="${AUTOCODE_CMD_GIT:-git}"
}

acquire_role_lock() {
    local role="$1"
    local base_name="$2"
    local datadir="$HOME/.claude-auto-code"
    AUTOCODE_LOCK_DIR="$datadir/${base_name}.lockdir"

    if ! mkdir "$AUTOCODE_LOCK_DIR" 2>/dev/null; then
        local lockpid
        lockpid=$(cat "$AUTOCODE_LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$lockpid" ] && kill -0 "$lockpid" 2>/dev/null; then
            echo "🔒 Another role is running (pid $lockpid), exiting $role"
            return 1
        fi
        rm -rf "$AUTOCODE_LOCK_DIR"
        if ! mkdir "$AUTOCODE_LOCK_DIR" 2>/dev/null; then
            echo "🔒 Lock race, exiting $role"
            return 1
        fi
    fi
    echo $$ > "$AUTOCODE_LOCK_DIR/pid"
    trap 'rm -rf "$AUTOCODE_LOCK_DIR"' EXIT
    return 0
}

# ----------------------------------------------------------------------------
# Helper: clean path → session base name (replace / with - exactly as you asked)
# ----------------------------------------------------------------------------
get_base_name() {
    local repo_path="${1:-$(pwd)}"
    # Make absolute (safe), replace every / with -, remove leading -
    realpath "$repo_path" 2>/dev/null | tr '/' '-' | sed 's/^-//'
}

get_session_name() {
    local role="${1:-EXECUTOR}"
    local repo_path="${2:-$(pwd)}"
    local base=$(get_base_name "$repo_path")
    local session="${base}-${role}"
    if tmux has-session -t "$session" 2>/dev/null; then
        echo "$session"
        return 0
    else
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 1. CREATE SESSION FUNCTION
#    Creates a session with the given role:
#      <repo-path>-(PLANNER|EXECUTOR|REVIEWER|JANITOR)
#    cd into the repo automatically
# ----------------------------------------------------------------------------
create_session() {
    local role="${1:-EXECUTOR}"
    local repo_path="${2:-$(pwd)}"
    local base=$(get_base_name "$repo_path")

    local session="${base}-${role}"

    if tmux has-session -t "$session" 2>/dev/null; then
        echo "Session exists: $session"
        return 0
    fi

    if ! tmux new-session -d -s "$session" "${SHELL:-/usr/bin/zsh} -l" 2>/dev/null; then
        echo "❌ tmux new-session failed for $session"
        return 1
    fi
    tmux send-keys -t "$session" "cd '$(realpath "$repo_path")'" C-m
    echo "Created session: $session"

    return 0
}

# ----------------------------------------------------------------------------
# 2. SEND COMMAND FUNCTION (and convenient wrappers)
#    You just call the wrapper you need — it automatically appends -PLANNER / -EXECUTOR / -REVIEWER / -JANITOR
# ----------------------------------------------------------------------------
send_command() {
    local role="${1:-EXECUTOR}"
    local cmd="$2"
    local repo_path="${3:-$(pwd)}"
    local base=$(get_base_name "$repo_path")
    local session="${base}-${role}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "❌ Session $session does not exist"
        create_session "$role" "$repo_path"
        if ! tmux has-session -t "$session" 2>/dev/null; then
            echo "❌ Failed to create session $session after retry"
            return 1
        fi
    fi

    tmux send-keys -t "$session" "$cmd" C-m
    echo "✅ Sent to $session → $cmd"
    return 0
}

# ----------------------------------------------------------------------------
# 3. CAPTURE + CHECK FUNCTION
#    Grabs last 10 lines of any role session and checks everything you asked:
#      • Is session running?
#      • Plan finished? → extracts plan file path
#      • "IMPLEMENTATION DONE"
#      • "REVIEWER APPROVED"
# ----------------------------------------------------------------------------
capture_last_lines() {
    local role="$1"                     # PLANNER / EXECUTOR / REVIEWER / JANITOR
    local length="${2:-30}"
    local repo_path="${3:-$(pwd)}"
    local base=$(get_base_name "$repo_path")
    local session="${base}-${role}"

    # 1. Is the session running?
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "❌ Session $session is NOT running"
        return 1
    fi
    echo "✅ Session $session is RUNNING"

    # 2. Capture last $length lines (exact tmux syntax)
    local output
    output=$(tmux capture-pane -S -"$length" -p -t "$session" 2>/dev/null | head -n "$((length -5))")

    echo "$output"
}

# Returns 0 if the session pane output has not changed between two captures
# (i.e. the process is idle/stopped), 1 if it is still producing output.
is_session_idle() {
    local role="$1"
    local repo_path="${2:-$(pwd)}"
    local base=$(get_base_name "$repo_path")
    local session="${base}-${role}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        return 0
    fi

    local snap1 snap2
    snap1=$(capture_last_lines "$role" 30)
    sleep 5
    snap2=$(capture_last_lines "$role" 30)

    if [ "$snap1" = "$snap2" ]; then
        return 0
    else
        echo "💜 Session $session is still active"
        echo "#####"
        snaplength=$(echo "$snap2" | wc -l)
        echo "$snap2" | tail -n 10 | sed 's/^/> /'
        echo ""
        return 1
    fi
}

# Interrupt (Ctrl+C) the current command in a role's pane
interrupt_current_command() {
    local role="$1"                     # PLANNER / EXECUTOR / REVIEWER / JANITOR
    local repo_path="${2:-$(pwd)}"
    local base=$(get_base_name "$repo_path")
    local session="${base}-${role}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "✅ Session $session not found"
        return 0
    fi

    tmux send-keys -t "$session" C-c
    echo "🛑 Sent Ctrl+C (interrupt) to $session"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "✅ Session $session terminated"
        return 0
    fi

    tmux send-keys -t "$session" C-c C-m   # C-m = Enter
    echo "🛑 Sent Ctrl+C + Enter to $session"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "✅ Session $session terminated"
        return 0
    fi
    echo "❌ Session $session cannot be interrupted"
    return 1
}
