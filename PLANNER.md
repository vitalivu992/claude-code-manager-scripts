# Planner workflow (cc-planner-session.sh)

This describes how the planner works when you run `scripts/cc-planner-session.sh` via cron or `claude-code-manager run`.

## Overview

The script drives a **PLANNER** tmux session that creates a plan; when the planner is done (session idle), it extracts the plan file path, saves it to metadata, and transitions state to `planner:done` for the EXECUTOR. It is designed to be run repeatedly so that:

1. If no workflow is active (state is empty), a new planner session is started.
2. If the planner is still running (state is `planner:active`), the script reports status.
3. When the planner becomes idle, the script detects it and transitions state for the next stage.

All state is under `~/.claude-auto-code/`, keyed by the current working directory (repo path).

## State-Based Guards

The PLANNER script only runs when:
- State is **empty** (no active workflow) — starts planning
- State is **`planner:active`** — checks if planning is done

For all other states, the script exits immediately. This replaces the previous approach of checking for other role tmux sessions.

## Concurrency

The script uses a shared flock (`${base_name}.lock`) shared by all roles. At most one role script executes at a time.

## What the script does each run

### 1. State is empty → create session and start planning

- Creates a detached tmux session named `<repo-base>-PLANNER`.
- If `~/.claude-auto-code/<base_name>.PLANNER.mail` exists: reads requirements, saves them to metadata, runs `claude /planner-create-plan <requirements>`, then deletes the mail file.
- Otherwise: runs `claude /planner-auto-plan`.
- Writes state `planner:active` and `updated_at` to metadata.

### 2. State is `planner:active` → check idle vs running

- Verifies the PLANNER tmux session still exists.
- Calls `is_session_idle "PLANNER"`: takes two pane snapshots 5 seconds apart.
  - **Still active (snapshots differ):** prints that the session is running. Exits.
  - **Idle (snapshots identical):** extracts the plan file path from pane output.
    - Writes `plan_path` to metadata.
    - Writes state `planner:done`.
    - Kills the PLANNER session.

## Data directory and files

- **Directory:** `~/.claude-auto-code/` (script uses `mkdir -p`).
- **Session base name:** from `get_base_name $(pwd)` in `tmux-session.sh` (absolute path with `/` replaced by `-`, leading `-` removed).

| File | Purpose |
|------|---------|
| `<base>.lock` | Shared flock for all roles |
| `<base>.state` | Workflow state (set to `planner:active`, then `planner:done`) |
| `<base>.meta` | Metadata: `plan_path`, `requirements`, `updated_at` |
| `<base>.PLANNER.mail` | Optional user-provided requirements (consumed on first run) |

## End-to-end flow

1. **First run (state empty):** Create session, run `/planner-auto-plan` or `/planner-create-plan`. Write state `planner:active`. Exit.
2. **Next runs (planner still working):** State is `planner:active`, session is active → report status, exit.
3. **Run after planner finishes:** State is `planner:active`, session is idle → extract plan path, write to metadata, write state `planner:done`, kill session. Exit.
4. **Later:** State is `planner:done` or beyond → script exits at guard (not PLANNER's turn).

## Dependencies

- **tmux:** session creation and pane capture.
- **tmux-session.sh:** provides `get_base_name`, `create_session`, `send_command`, `is_session_idle`, `write_state`, `write_meta`.
- **claude:** used inside the PLANNER session for `/planner-create-plan` and `/planner-auto-plan`.

## Attaching to the PLANNER

```bash
tmux attach -t <session_name>
```

Example: `tmux attach -t home-ltvu-myproject-PLANNER`.
