# Janitor workflow (cc-janitor-session.sh)

This describes how the janitor works when you run `scripts/cc-janitor-session.sh` via cron or `autocode run`.

## Overview

The **JANITOR** is the final stage of the pipeline. It is triggered when the REVIEWER approves the implementation (state `reviewer:approved`). Its job is to commit, push, and terminate all workflow sessions, leaving the repo in a clean state.

All state is under `~/.claude-auto-code/`, keyed by the current working directory (repo path).

## State-Based Guards

The JANITOR script only runs when:
- State is **`reviewer:approved`** — start commit
- State is **`janitor:commit`** — check if commit is done, start push
- State is **`janitor:push`** — check if push is done, clean up

For all other states, the script exits immediately.

## Concurrency

The script uses a shared flock (`${base_name}.lock`) shared by all roles.

## What the script does each run

### 1. State is `reviewer:approved` → start commit

- Creates the JANITOR tmux session.
- Sends `$AUTOCODE_CMD_JANITOR -p "/git-commit"` (default: `claude -p "/git-commit"`).
- Writes state `janitor:commit`.

### 2. State is `janitor:commit` → check commit, start push

- Verifies the JANITOR session exists and is idle.
- Sends `$AUTOCODE_CMD_GIT push` (default: `git push`).
- Writes state `janitor:push`.

### 3. State is `janitor:push` → check push, clean up

- Verifies the JANITOR session exists and is idle.
- Clears the state file and metadata file.
- Removes the lock file.
- Kills all four role tmux sessions (PLANNER, EXECUTOR, REVIEWER, JANITOR).

After cleanup, no workflow sessions remain, all state files are removed, and the repo has been committed and pushed.

## Data directory and files

- **Directory:** `~/.claude-auto-code/`
- **Session base name:** from `get_base_name $(pwd)` in `tmux-session.sh`.

| File | Purpose |
|------|---------|
| `<base>.lock` | Shared flock for all roles (removed during cleanup) |
| `<base>.state` | Workflow state (reads `reviewer:approved`, writes `janitor:commit`/`janitor:push`, cleared at end) |
| `<base>.meta` | Metadata (cleared during cleanup) |

## End-to-end flow

1. **Runs before approval:** State is not `reviewer:approved`/`janitor:*` → exit.
2. **First run after REVIEWER approves:** State is `reviewer:approved` → create session, start commit, write state `janitor:commit`. Exit.
3. **Run after commit completes:** State is `janitor:commit`, session idle → start push, write state `janitor:push`. Exit.
4. **Run after push completes:** State is `janitor:push`, session idle → clean up all state, kill all sessions. Exit.
5. **Subsequent runs:** State is empty (cleaned up) → exit.

## Dependencies

- **tmux:** session creation and key sending.
- **tmux-session.sh:** provides `get_base_name`, `create_session`, `send_command`, `is_session_idle`, `capture_last_lines`, `read_state`, `write_state`, `clear_state`, `clear_meta`.
- **git:** used for `git push` (configurable via `AUTOCODE_CMD_GIT`).
