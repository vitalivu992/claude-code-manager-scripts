# Executor workflow (cc-executor-session.sh)

This describes how the executor works when you run `scripts/cc-executor-session.sh` via cron or `autocode run`.

## Overview

The script drives an **EXECUTOR** tmux session that implements a plan produced by the PLANNER. It is designed to be run repeatedly so that:

1. If the EXECUTOR session is running (state `executor:active`), the script checks output for `READY_FOR_REVIEW` and transitions to `executor:done`.
2. If the plan is ready (state `planner:done`), the script starts execution.
3. If the REVIEWER found gaps (state `reviewer:gaps`), the script starts a gap-fix iteration.

All state is under `~/.claude-auto-code/`, keyed by the current working directory (repo path).

## State-Based Guards

The EXECUTOR script only runs when:
- State is **`planner:done`** — start initial execution
- State is **`executor:active`** — check for READY_FOR_REVIEW
- State is **`reviewer:gaps`** — start gap-fix iteration

For all other states, the script exits immediately.

## Concurrency

The script uses a shared flock (`${base_name}.lock`) shared by all roles.

## What the script does each run

### 1. State is `executor:active` → check output

- Verifies the EXECUTOR tmux session still exists.
- Checks if the session is idle. If still active, exits.
- If idle, captures the last 50 lines of the EXECUTOR pane.
- If output contains `READY_FOR_REVIEW`:
  - Writes state `executor:done`.
  - Sends `/exit` to the EXECUTOR session and kills it.
- Exits.

### 2. State is `planner:done` → start execution

- Reads `plan_path` from metadata.
- Creates the EXECUTOR session.
- Sends the execution command:
  ```
  claude /ralph-loop:ralph-loop "review existing source code, documents and execute
  the plan <PLAN_FILE>, make sure all requirements are fulfilled,
  all tests pass then output READY_FOR_REVIEW"
  --completion-promise "READY_FOR_REVIEW"
  ```
- Writes `review_iteration` as `0` to metadata.
- Writes state `executor:active`.

### 3. State is `reviewer:gaps` → fix gaps

- Reads `plan_path` and `gaps_path` from metadata.
- Creates the EXECUTOR session.
- Increments `review_iteration` in metadata.
- Sends the gap-fix command:
  ```
  claude /ralph-loop:ralph-loop "review the code changes, existing source code,
  documents and the plan <PLAN_FILE> and the gaps documented and plan in <GAPS_FILE>,
  review if the gaps are valid or not, then fix the necessary gaps,
  make sure all requirements are fulfilled, all tests pass then output READY_FOR_REVIEW"
  --completion-promise "READY_FOR_REVIEW"
  ```
- Writes state `executor:active`.

## Data directory and files

- **Directory:** `~/.claude-auto-code/`
- **Session base name:** from `get_base_name $(pwd)` in `tmux-session.sh`.

| File | Purpose |
|------|---------|
| `<base>.lock` | Shared flock for all roles |
| `<base>.state` | Workflow state (reads `planner:done`/`reviewer:gaps`, writes `executor:active`/`executor:done`) |
| `<base>.meta` | Reads: `plan_path`, `gaps_path`. Writes: `review_iteration`, `updated_at` |

## End-to-end flow

1. **First run after PLANNER writes `planner:done`:** State is `planner:done` → create session, launch `/ralph-loop` with plan, write state `executor:active`. Exit.
2. **Next runs (executor still working):** State is `executor:active`, session active → exit.
3. **Run after executor outputs `READY_FOR_REVIEW`:** State is `executor:active`, session idle, `READY_FOR_REVIEW` found → write state `executor:done`, kill session. Exit.
4. **After REVIEWER sends gaps:** State is `reviewer:gaps` → create session, launch with gap-fix context, write state `executor:active`. Exit.

## Dependencies

- **tmux:** session creation, pane capture, key sending.
- **tmux-session.sh:** provides `get_base_name`, `create_session`, `send_command`, `is_session_idle`, `read_state`, `write_state`, `read_meta`, `write_meta`.
- **claude:** used inside the EXECUTOR session for `/ralph-loop:ralph-loop`.
