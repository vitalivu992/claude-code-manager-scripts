# Reviewer workflow (cc-reviewer-session.sh)

This describes how the reviewer works when you run `scripts/cc-reviewer-session.sh` every 5 minutes via cron.

## Overview

The script drives a **REVIEWER** tmux session that checks the EXECUTOR's implementation for gaps. It is designed to be run repeatedly by cron so that:

1. If the REVIEWER session is already running, the script polls its output for a decision: either a gaps plan file path or the literal text `REVIEWER_APPROVED`.
2. If no session is running, the script reads the mail box and starts a review when the EXECUTOR has signalled `READY_FOR_REVIEW`.

All state is under `~/.ai-coding-team/`, keyed by the current working directory (repo path) when the script runs.

## Cron setup

Run from the repo (so `pwd` is that repo):

```cron
*/5 * * * * cd /path/to/your/repo && /path/to/workspace/skills/ai-coding-team/scripts/cc-reviewer-session.sh
```

## What the script does each run

### 1. REVIEWER session is running → check output

If a **REVIEWER** tmux session exists for this repo:

- Checks if the session is idle. If still active, exits.
- If idle, captures the last 50 lines of the REVIEWER pane.
- Checks output (in order):
  - **`REVIEWER_APPROVED` found**: writes `REVIEWER_APPROVED` to `<session_name>.EXECUTOR.mail`. Sends `/exit` and kills the session.
  - **Gaps plan found** (`~/.claude/plans/` path detected): writes that path to `<session_name>.EXECUTOR.mail` so the EXECUTOR picks up the gap-fix task. Sends `/exit` and kills the session.
- Exits.

### 2. No session + no mail → idle exit

If there is no REVIEWER session and no `<session_name>.REVIEWER.mail` file, the script exits silently.

### 3. No session + mail present → start review

When the EXECUTOR writes the plan path to the mail box (after outputting `READY_FOR_REVIEW`):

- Reads the plan file path from `<session_name>.REVIEWER.mail`.
- Creates the REVIEWER tmux session.
- Sends the review command:
  ```
  claude-zaiglm /reviewer-review-impl-gaps <PLAN_FILE_PATH>
  ```
- Removes the REVIEWER mail.
- Exits. The reviewer runs in tmux; subsequent cron runs will see the session and poll its output.

## What the REVIEWER outputs

The `/reviewer-review-impl-gaps` command will produce one of two outcomes, detectable in the pane output:

| Output | Meaning | Next action |
|--------|---------|-------------|
| A `~/.claude/plans/` file path | Gaps were found; a new plan describes what to fix | Script writes that path to `.EXECUTOR.mail` |
| `REVIEWER_APPROVED` | Implementation is complete and correct | Script writes `REVIEWER_APPROVED` to `.EXECUTOR.mail` |

## Data directory and files

- **Directory:** `~/.ai-coding-team/` (script uses `mkdir -p`).
- **Session base name:** from `get_base_name $(pwd)` in `tmux-session.sh`.

| File | Purpose |
|------|---------|
| `<base>-EXECUTOR.REVIEWER.mail` | Inbound mail from EXECUTOR. Contains the plan file path after `READY_FOR_REVIEW`. Deleted after processing. |
| `<base>-REVIEWER.EXECUTOR.mail` | Written by this script with either a gaps plan path or `REVIEWER_APPROVED`; consumed by the EXECUTOR. |

## End-to-end flow with cron every 5 minutes

1. **First run after EXECUTOR writes mail:** No session → create session, launch `/reviewer-review-impl-gaps`. Exit.
2. **Next runs (reviewer still working):** Session running, no decision yet in output → print status, exit.
3. **Run after reviewer outputs gaps plan:** Session idle, `~/.claude/plans/` path found → write gaps path to `.EXECUTOR.mail`, send `/exit`, kill REVIEWER session. Exit.
4. **Run after reviewer outputs `REVIEWER_APPROVED`:** Session idle, `REVIEWER_APPROVED` found → write `REVIEWER_APPROVED` to `.EXECUTOR.mail`, send `/exit`, kill REVIEWER session. Exit.

## Dependencies

- **tmux:** session creation and pane capture.
- **tmux-session.sh:** provides `get_base_name`, `create_session`, `send_command`, `is_session_idle`.
- **claude-zaiglm:** used inside the REVIEWER session for `/reviewer-review-impl-gaps`.
