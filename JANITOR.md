# Janitor workflow (cc-janitor-session.sh)

This describes how the janitor works when you run `scripts/cc-janitor-session.sh` every 5 minutes via cron.

## Overview

The **JANITOR** is the final stage of the pipeline. It is triggered only once — when the EXECUTOR forwards `REVIEWER_APPROVED`. Its job is to commit, push, and terminate all workflow sessions, leaving the repo in a clean state.

All state is under `~/.ai-coding-team/`, keyed by the current working directory (repo path) when the script runs.

## Cron setup

Run from the repo (so `pwd` is that repo):

```cron
*/5 * * * * cd /path/to/your/repo && /path/to/workspace/skills/ai-coding-team/scripts/cc-janitor-session.sh
```

## What the script does each run

### 1. No mail → idle exit

If `<session_name>.JANITOR.mail` does not exist, the script exits silently. Nothing to do.

### 2. Mail present but not `REVIEWER_APPROVED` → error exit

If the mail exists but does not contain `REVIEWER_APPROVED`, the script logs the unexpected content, removes the mail, and exits with code 1.

### 3. Mail contains `REVIEWER_APPROVED` → commit, push, clean up

When the EXECUTOR writes `REVIEWER_APPROVED` to the mail box:

1. Creates the JANITOR tmux session.
2. Sends `git-commit-generate` to the JANITOR session and waits for it to complete (polls until idle).
3. Sends `git push` to the JANITOR session and waits for it to complete (polls until idle).
4. Removes the JANITOR mail.
5. Iterates over all four roles — PLANNER, EXECUTOR, REVIEWER, JANITOR — and kills each tmux session that still exists.

After step 5, no workflow tmux sessions remain and the repo has been committed and pushed.

## Data directory and files

- **Directory:** `~/.ai-coding-team/` (script uses `mkdir -p`).
- **Session base name:** from `get_base_name $(pwd)` in `tmux-session.sh`.

| File | Purpose |
|------|---------|
| `<base>-EXECUTOR.JANITOR.mail` | Inbound mail from EXECUTOR. Contains `REVIEWER_APPROVED`. Deleted after processing. |

## End-to-end flow with cron every 5 minutes

1. **Runs before approval:** No mail → exit.
2. **First run after EXECUTOR writes mail:** Mail contains `REVIEWER_APPROVED` → create session, commit, push, kill all sessions. Exit.
3. **Subsequent runs:** No mail (already deleted) → exit.

## Dependencies

- **tmux:** session creation and key sending.
- **tmux-session.sh:** provides `get_base_name`, `create_session`, `send_command`, `is_session_idle`.
- **git-commit-generate:** generates and commits changes; must be available in the tmux session's `PATH`.
- **git:** used directly for `git push`.
