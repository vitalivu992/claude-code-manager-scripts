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
    local config_file="$HOME/.claude-code-manager/config.yaml"
    AUTOCODE_CMD_GIT="git"
    AUTOCODE_GIT_PUSH="true"
    AUTOCODE_EXECUTOR_IDLE_THRESHOLD="2"
    AUTOCODE_EXECUTOR_MAX_RESTARTS="3"
    AUTOCODE_INTERVAL="${AUTOCODE_INTERVAL:-30}"

    if [ ! -f "$config_file" ]; then
        return 0
    fi

    # Read all scalar config values in a single yq invocation (separator: |)
    # Use null-safe if/else to correctly handle booleans (false) and zeros.
    # Strip surrounding quotes that Python-based yq adds around the joined string.
    local raw
    raw=$(yq '[
        (.git.command // ""),
        (if .git.push == null then "" else (.git.push | tostring) end),
        (if .interval == null then "" else (.interval | tostring) end),
        (if .roles.executor.idle_threshold == null then "" else (.roles.executor.idle_threshold | tostring) end),
        (if .roles.executor.max_restarts == null then "" else (.roles.executor.max_restarts | tostring) end)
    ] | join("|")' "$config_file" 2>/dev/null | tr -d '"') || return 0

    local git_cmd git_push interval idle_threshold max_restarts
    IFS='|' read -r git_cmd git_push interval idle_threshold max_restarts <<< "$raw"

    [ -n "$git_cmd" ]       && [ "$git_cmd" != "null" ]       && AUTOCODE_CMD_GIT="$git_cmd"
    [ -n "$git_push" ]      && [ "$git_push" != "null" ]      && AUTOCODE_GIT_PUSH="$git_push"
    [ -n "$interval" ]      && [ "$interval" != "null" ]      && AUTOCODE_INTERVAL="$interval"
    [ -n "$idle_threshold" ] && [ "$idle_threshold" != "null" ] && AUTOCODE_EXECUTOR_IDLE_THRESHOLD="$idle_threshold"
    [ -n "$max_restarts" ]  && [ "$max_restarts" != "null" ]  && AUTOCODE_EXECUTOR_MAX_RESTARTS="$max_restarts"
}

# Pick a random command from the list configured for a role in config.yaml.
# Usage: pick_cmd_for_role <role>   (role = planner | executor | reviewer | janitor)
# Echoes the selected command string. Falls back to "claude" if config/list is missing.
pick_cmd_for_role() {
    local role="${1,,}"   # lowercase
    local config_file="$HOME/.claude-code-manager/config.yaml"

    if [ ! -f "$config_file" ]; then
        echo "claude"
        return 0
    fi

    # Read count and all command entries in a single yq invocation
    # Output format: "<count>|<cmd0>|<cmd1>|..."
    # Strip surrounding quotes that Python-based yq adds.
    local raw
    raw=$(yq ".roles.${role}.commands | (length | tostring) + \"|\" + join(\"|\")" \
         "$config_file" 2>/dev/null | tr -d '"') || true

    local count
    count=$(echo "$raw" | cut -d'|' -f1)

    if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" -eq 0 ] 2>/dev/null; then
        echo "claude"
        return 0
    fi

    # Pick a random 0-based index and extract the corresponding field (fields are 1-based after count)
    local idx=$(( RANDOM % count ))
    local cmd
    cmd=$(echo "$raw" | cut -d'|' -f$(( idx + 2 )))

    if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
        echo "claude"
        return 0
    fi
    echo "$cmd"
}

# Wait until the claude interactive prompt is visible in a role's pane.
# Polls every 2 seconds up to max_wait seconds (default 120).
# The prompt is identified by the ">" character that claude renders at the
# start of an input line, or by the box-drawing character "╭" that appears
# in claude's idle UI.  Either is sufficient to confirm readiness.
#
# Usage: wait_for_claude_prompt ROLE [max_wait] [repo_path]
wait_for_claude_prompt() {
    local role="$1"
    local max_wait="${2:-${AUTOCODE_CLAUDE_PROMPT_TIMEOUT:-120}}"
    local repo_path="${3:-$(pwd)}"
    local base
    base=$(get_base_name "$repo_path")
    local session="${base}-${role}"
    local elapsed=0
    local poll_interval=2

    echo "⏳ Waiting for $role prompt (up to ${max_wait}s)..."
    while [ "$elapsed" -lt "$max_wait" ]; do
        local pane
        pane=$(tmux capture-pane -S -10 -p -t "$session" 2>/dev/null)
        # Claude's idle prompt contains a ">" at the start of the input line,
        # or the box-drawing top-left corner "╭" of its UI frame.
        if echo "$pane" | grep -qE '(^|\s)>\s*$|╭'; then
            echo "✅ $role prompt detected (${elapsed}s)"
            return 0
        fi
        sleep "$poll_interval"
        elapsed=$(( elapsed + poll_interval ))
    done
    echo "⚠️  $role prompt not detected after ${max_wait}s, sending command anyway"
    return 0
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
    local length="${2:-50}"
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
    output=$(tmux capture-pane -S -"$length" -p -t "$session" 2>/dev/null)

    echo "$output"
}

# Returns 0 if the session pane output has not changed since the previous tick
# (i.e. the process is idle/stopped), 1 if it is still producing output.
# Compares current capture against ~/.claude-auto-code/{base}.{role}.log.prev
# written on the prior tick; no blocking sleep required.
is_session_idle() {
    local role="$1"
    local repo_path="${2:-$(pwd)}"
    local base=$(get_base_name "$repo_path")
    local session="${base}-${role}"
    local datadir="$HOME/.claude-auto-code"
    local log_file="$datadir/${base}.${role}.log"
    local prev_file="$datadir/${base}.${role}.log.prev"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        return 0
    fi

    # Capture current pane output (50 lines, no decorative header)
    local current
    current=$(tmux capture-pane -S -50 -p -t "$session" 2>/dev/null)

    # First tick: no baseline yet — create empty prev, save current, return not-idle
    if [ ! -f "$prev_file" ]; then
        touch "$prev_file"
        echo "$current" > "$log_file"
        mv "$log_file" "$prev_file"
        return 1
    fi

    echo "$current" > "$log_file"

    if diff -q "$prev_file" "$log_file" > /dev/null 2>&1; then
        # Same as last tick: session is idle
        mv "$log_file" "$prev_file"
        return 0
    else
        # Different from last tick: session is still running
        echo "💜 Session $session is running"
        grep -vE '^\s*$' "$log_file" | grep -vE '^\s*─────\s*$' | sed 's/^/>>> /' | tail -n 10
        echo ""
        mv "$log_file" "$prev_file"
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
