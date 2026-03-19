# Planner workflow (cc-planner-session.sh)

This describes how the planner works when you run `scripts/cc-planner-session.sh` every 5 minutes via cron.

## Overview

The script drives a **PLANNER** tmux session that creates a plan; when the planner is done (session idle), it hands off the plan file path to the EXECUTOR via a mail file. It is designed to be run repeatedly by cron so that:

1. If no planner is running, one is started (or a new plan is triggered).
2. If the planner is still running, the cron run just reports status.
3. When the planner becomes idle, the script detects it and writes the plan path to `EXECUTOR.mail` for the next stage.

All state is under `~/.ai-coding-team/`, keyed by the current working directory (repo path) when the script runs.

## Cron setup

Run from the repo you want to plan (so `pwd` is that repo):

```cron
*/5 * * * * cd /path/to/your/repo && /path/to/workspace/skills/ai-coding-team/scripts/cc-planner-session.sh
```

Use the real path to the script and ensure the cron environment can see `tmux` and `claude-zaiglm` (or adjust `PATH` in the cron job).

## What the script does each run

### 1. Guard: other roles running

If an **EXECUTOR**, **REVIEWER**, or **JANITOR** tmux session exists for this repo, the script:

- Prints that the role session exists and shows the last 10 lines of that session.
- Exits without touching the PLANNER. So cron will not start or poke the planner while execution/review is in progress.

### 2. No PLANNER session → create and start planning

If there is **no** PLANNER session for this repo:

- Creates a detached tmux session named `<repo-base>-PLANNER` (e.g. `home-ltvu-myproject-PLANNER`).
- Enters the planning session:
  - If `~/.ai-coding-team/<base_name>.PLANNER.mail` exists: runs  
    `claude-zaiglm /planner-create-plan <contents of .PLANNER.mail>`.
  - Otherwise: runs `claude-zaiglm /planner-auto-plan`.
- Captures and prints the last 10 lines of the PLANNER pane.
- Exits. The planner keeps running in tmux; the next cron run will see the session.

### 3. PLANNER session exists → check idle vs running

If a PLANNER session **does** exist:

- Calls `is_session_idle "PLANNER"` (from `tmux-session.sh`): takes two pane snapshots 2 seconds apart.
  - **Still active (snapshots differ):** prints that the PLANNER session is running and how to attach:
    `tmux attach -t <session_name>`. Exits.
  - **Idle (snapshots identical):** proceeds to extract the plan file path.
    - Captures the full pane output, finds the line containing `~/.claude/plans/`, takes the last field.
    - Writes that path to `~/.ai-coding-team/<session_name>.EXECUTOR.mail`.
    - Downstream (e.g. an EXECUTOR script) can read this file to know which plan to run.

## Data directory and files

- **Directory:** `~/.ai-coding-team/` (script uses `mkdir -p`).
- **Session base name:** from `get_base_name $(pwd)` in `tmux-session.sh` (absolute path with `/` replaced by `-`, leading `-` removed). Example: `home-ltvu-myproject` → session `home-ltvu-myproject-PLANNER`.

| File | Purpose |
|------|--------|
| `<base_name>.PLANNER.mail` | Optional. If present when starting the planner, its contents are passed to `/planner-create-plan` as requirements. |
| `<base_name>-PLANNER.EXECUTOR.mail` | Written when planner is idle; contains the plan file path (e.g. `~/.claude/plans/sequential-imagining-cosmos.md`) for the EXECUTOR. |

## End-to-end flow with cron every 5 minutes

1. **First run:** No PLANNER → create session, run `/planner-auto-plan` or `/planner-create-plan` (if `.PLANNER.mail` exists). Exit.
2. **Next runs (planner still working):** PLANNER exists, log differs from previous → “PLANNER session is running”, exit.
3. **Run after planner finishes:** PLANNER exists, log unchanged → “PLANNER session is idle/stopped”, extract plan path, write to `.EXECUTOR.mail`, kill PLANNER session, exit.
4. **Later:** If EXECUTOR (or REVIEWER/JANITOR) is up, script exits at the guard step and does not create or poke the PLANNER.

So the planner is started or continued by cron; when it goes idle, the script automatically hands the plan path to the EXECUTOR via `.EXECUTOR.mail`.

## Dependencies

- **tmux:** session creation and pane capture.
- **tmux-session.sh:** provides `get_base_name`, `get_session_name`, `create_session`, `send_command`, `capture_last_lines`, `is_session_idle`.
- **claude-zaiglm:** used inside the PLANNER session for `/planner-create-plan` and `/planner-auto-plan` (must be available in the environment of the tmux session, i.e. when cron runs the script from the repo).

## Attaching to the PLANNER

To watch or interact with the planner:

```bash
tmux attach -t <session_name>
```

Example: `tmux attach -t home-ltvu-myproject-PLANNER`. The script prints the exact `session_name` when it reports “PLANNER session is running”.
