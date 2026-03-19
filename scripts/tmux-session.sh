#!/bin/bash
# Hands-on tmux scripting for your repo workflow (PLANNER / EXECUTOR / REVIEWER)


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

    tmux new-session -d -s "$session"

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
    local length="${2:-15}"
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
    output=$(tmux capture-pane -S -$length -p -t "$session" 2>/dev/null)

    echo -e "\n📋 Last $length lines"
    echo "---"
    echo "$output"
    echo "---"
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
    snap1=$(tmux capture-pane -S -20 -p -t "$session" 2>/dev/null)
    sleep 2
    snap2=$(tmux capture-pane -S -20 -p -t "$session" 2>/dev/null)

    if [ "$snap1" = "$snap2" ]; then
        return 0
    else
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
