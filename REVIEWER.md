# Reviewer workflow (cc-reviewer-session.sh)

This describes how the reviewer works when you run `scripts/cc-reviewer-session.sh` via cron or `autocode run`.

## Overview

The script drives a **REVIEWER** tmux session that checks the EXECUTOR's implementation for gaps. It is designed to be run repeatedly so that:

1. If the REVIEWER session is running (state `reviewer:active`), the script polls output for either a gaps plan file path or the literal text `REVIEWER_APPROVED`.
2. If the executor is done (state `executor:done`), the script starts a review.

All state is under `~/.claude-auto-code/`, keyed by the current working directory (repo path).

## State-Based Guards

The REVIEWER script only runs when:
- State is **`executor:done`** — start review
- State is **`reviewer:active`** — check review output

For all other states, the script exits immediately.

## Concurrency

The script uses a shared flock (`${base_name}.lock`) shared by all roles.

## What the script does each run

### 1. State is `reviewer:active` → check output

- Verifies the REVIEWER tmux session still exists.
- Checks if the session is idle. If still active, exits.
- If idle, captures the last 30 lines of the REVIEWER pane.
- Checks output (in order):
  - **`REVIEWER_APPROVED` found**: writes state `reviewer:approved`. Sends `/exit` and kills the session.
  - **Gaps plan found** (`~/.claude/plans/` path detected, different from the original plan): writes `gaps_path` to metadata, writes state `reviewer:gaps`. Sends `/exit` and kills the session.
- Exits.

### 2. State is `executor:done` → start review

- Reads `plan_path` from metadata.
- Creates the REVIEWER tmux session.
- Sends the review command:
  ```
  claude /reviewer-review-impl-gaps <PLAN_FILE_PATH>
  ```
- Writes state `reviewer:active`.
- Exits. The reviewer runs in tmux; subsequent runs will see the session and poll its output.

## What the REVIEWER outputs

The `/reviewer-review-impl-gaps` command will produce one of two outcomes, detectable in the pane output:

| Output | Meaning | State Transition |
|--------|---------|-----------------|
| A `~/.claude/plans/` file path | Gaps were found; a new plan describes what to fix | `reviewer:gaps` |
| `REVIEWER_APPROVED` | Implementation is complete and correct | `reviewer:approved` |

## Data directory and files

- **Directory:** `~/.claude-auto-code/`
- **Session base name:** from `get_base_name $(pwd)` in `tmux-session.sh`.

| File | Purpose |
|------|---------|
| `<base>.lock` | Shared flock for all roles |
| `<base>.state` | Workflow state (reads `executor:done`, writes `reviewer:active`/`reviewer:approved`/`reviewer:gaps`) |
| `<base>.meta` | Reads: `plan_path`. Writes: `gaps_path`, `updated_at` |

## End-to-end flow

1. **First run after EXECUTOR writes `executor:done`:** State is `executor:done` → create session, launch `/reviewer-review-impl-gaps`, write state `reviewer:active`. Exit.
2. **Next runs (reviewer still working):** State is `reviewer:active`, session active → exit.
3. **Run after reviewer outputs gaps plan:** State is `reviewer:active`, session idle, `~/.claude/plans/` path found → write `gaps_path` to metadata, write state `reviewer:gaps`, kill session. Exit.
4. **Run after reviewer outputs `REVIEWER_APPROVED`:** State is `reviewer:active`, session idle, `REVIEWER_APPROVED` found → write state `reviewer:approved`, kill session. Exit.

## Dependencies

- **tmux:** session creation and pane capture.
- **tmux-session.sh:** provides `get_base_name`, `create_session`, `send_command`, `is_session_idle`, `capture_last_lines`, `read_state`, `write_state`, `read_meta`, `write_meta`.
- **claude:** used inside the REVIEWER session for `/reviewer-review-impl-gaps`.
