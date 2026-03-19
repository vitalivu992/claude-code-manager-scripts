# Executor workflow (cc-executor-session.sh)

This describes how the executor works when you run `scripts/cc-executor-session.sh` every 5 minutes via cron.

## Overview

The script drives an **EXECUTOR** tmux session that implements a plan produced by the PLANNER. It is designed to be run repeatedly by cron so that:

1. If the EXECUTOR session is already running, the script checks its output for `READY_FOR_REVIEW` and forwards the plan path to the REVIEWER if found.
2. If no session is running, the script reads the mail box and acts on its content.
3. When the REVIEWER sends back a gaps plan, the EXECUTOR re-runs with the gap-fix context.
4. When the REVIEWER approves, the EXECUTOR forwards `REVIEWER_APPROVED` to the JANITOR.

All state is under `~/.ai-coding-team/`, keyed by the current working directory (repo path) when the script runs.

## Cron setup

Run from the repo you want to execute against (so `pwd` is that repo):

```cron
*/5 * * * * cd /path/to/your/repo && /path/to/workspace/skills/ai-coding-team/scripts/cc-executor-session.sh
```

## What the script does each run

### 1. EXECUTOR session is running → check output

If an **EXECUTOR** tmux session exists for this repo:

- Captures the last 10 lines of the EXECUTOR pane.
- If output contains `READY_FOR_REVIEW`:
  - Reads the saved plan file path from `<session_name>.EXECUTOR.plan`.
  - Writes that path to `<session_name>.REVIEWER.mail` so the REVIEWER picks it up.
- Exits. Does not start or poke the session further.

### 2. No session + no mail → idle exit

If there is no EXECUTOR session and no `<session_name>.EXECUTOR.mail` file, the script exits silently.

### 3. No session + mail contains `REVIEWER_APPROVED`

If the REVIEWER has approved the implementation:

- Writes `REVIEWER_APPROVED` to `<session_name>.JANITOR.mail`.
- Removes the EXECUTOR mail.
- Exits. The JANITOR will pick this up on its next cron run.

### 4. No session + mail contains a plan gaps file path

If the REVIEWER sent back a gaps plan (a `~/.claude/plans/` path):

- Reads the original plan file path from `<session_name>.EXECUTOR.plan`.
- Creates the EXECUTOR session if needed.
- Interrupts the current command in the EXECUTOR pane (in case the previous `/ralph-loop` is still attached).
- Sends the fix-gaps command to the EXECUTOR:
  ```
  claude-zaiglm /ralph-loop:ralph-loop "review the code changes, existing source code,
  documents and the plan <PLAN_FILE> and the gaps documented and plan in <GAPS_FILE>,
  review if the gaps are valid or not, then fix the necessary gaps,
  make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW"
  --completion-promise "READY_FOR_REVIEW"
  ```
- Removes the EXECUTOR mail.

### 5. No session + mail contains the original plan file path (from PLANNER)

First time the EXECUTOR receives a task:

- Extracts the plan file path from the mail.
- Saves it to `<session_name>.EXECUTOR.plan` for future reference.
- Creates the EXECUTOR session.
- Sends the initial execution command:
  ```
  claude-zaiglm /ralph-loop:ralph-loop "review existing source code, documents and execute
  the plan <PLAN_FILE>, make sure all requirements are fulfilled,
  all tests pass then output READY_FOR_REVIEW"
  --completion-promise "READY_FOR_REVIEW"
  ```
- Removes the EXECUTOR mail.

## Data directory and files

- **Directory:** `~/.ai-coding-team/` (script uses `mkdir -p`).
- **Session base name:** from `get_base_name $(pwd)` in `tmux-session.sh`.

| File | Purpose |
|------|---------|
| `<base>-PLANNER.EXECUTOR.mail` | Inbound mail from PLANNER. Contains the plan file path. Deleted after processing. |
| `<base>-REVIEWER.EXECUTOR.mail` | Inbound mail from REVIEWER. Contains either a gaps plan path or `REVIEWER_APPROVED`. Deleted after processing. |
| `<base>.EXECUTOR.plan` | Persists the original plan file path across cron runs so gap-fix iterations can reference it. |
| `<base>-EXECUTOR.REVIEWER.mail` | Written by this script when `READY_FOR_REVIEW` is detected; consumed by the REVIEWER. |
| `<base>-EXECUTOR.JANITOR.mail` | Written by this script when `REVIEWER_APPROVED` is received; consumed by the JANITOR. |

## End-to-end flow with cron every 5 minutes

1. **First run after PLANNER writes mail:** No session → create session, launch `/ralph-loop` with plan. Exit.
2. **Next runs (executor still working):** Session running, no `READY_FOR_REVIEW` in output → print status, exit.
3. **Run after executor outputs `READY_FOR_REVIEW`:** Session running, `READY_FOR_REVIEW` found → write plan path to `.REVIEWER.mail`. Exit.
4. **After REVIEWER sends gaps plan:** No session (previous finished), mail has gaps path → interrupt, re-launch with gap-fix context. Exit.
5. **After REVIEWER approves:** No session, mail has `REVIEWER_APPROVED` → forward to `.JANITOR.mail`. Exit.

## Dependencies

- **tmux:** session creation, pane capture, key sending.
- **tmux-session.sh:** provides `get_base_name`, `get_session_name`, `create_session`, `send_command`, `interrupt_current_command`, `capture_last_lines`.
- **claude-zaiglm:** used inside the EXECUTOR session for `/ralph-loop:ralph-loop`.
