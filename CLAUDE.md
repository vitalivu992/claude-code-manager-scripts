# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements a **multi-agent AI coding workflow** that orchestrates four specialized roles (PLANNER, EXECUTOR, REVIEWER, JANITOR) through tmux sessions and a shared state file. The workflow is designed to be run via cron or the `claude-code-manager` CLI, enabling autonomous software development with Claude Code.

### Architecture

The workflow consists of four roles coordinated through a central state file in `~/.claude-auto-code/`:

```
┌─────────────┐  planner:done  ┌──────────────┐  executor:done ┌─────────────┐
│   PLANNER   │ ─────────────> │   EXECUTOR   │ ─────────────> │   REVIEWER  │
│             │                │              │ <───────────── │             │
└─────────────┘                └──────────────┘  reviewer:gaps └─────────────┘
                                                                      │
                                ┌─────────────┐                       │
                                │   JANITOR   │ <─────────────────────┘
                                │             │  reviewer:approved
                                └─────────────┘
```

1. **PLANNER** (`scripts/cc-planner-session.sh`): Creates an implementation plan. Extracts plan file path when idle and transitions state to `planner:done`.
2. **EXECUTOR** (`scripts/cc-executor-session.sh`): Implements the plan using `/ralph-loop:ralph-loop`. Transitions to `executor:done` when `READY_FOR_REVIEW` is detected. Handles gap-fix iterations from REVIEWER.
3. **REVIEWER** (`scripts/cc-reviewer-session.sh`): Reviews implementation for gaps using `/reviewer-review-impl-gaps`. Transitions to `reviewer:approved` or `reviewer:gaps`.
4. **JANITOR** (`scripts/cc-janitor-session.sh`): Runs `$AUTOCODE_CMD_JANITOR` for commits, optionally runs `$AUTOCODE_CMD_GIT push` (controlled by `AUTOCODE_GIT_PUSH`), cleans up all state, and terminates all workflow sessions.

### State Machine

All roles share a single state file (`${base}.state`) that drives the workflow:

| State | Active Role | Action |
|-------|-------------|--------|
| _(empty)_ | PLANNER | Start planning |
| `planner:active` | PLANNER | Polling for plan completion |
| `planner:done` | EXECUTOR | Start execution with plan |
| `executor:active` | EXECUTOR | Polling for READY_FOR_REVIEW |
| `executor:done` | REVIEWER | Start review |
| `reviewer:active` | REVIEWER | Polling for review outcome |
| `reviewer:approved` | JANITOR | Start commit + push |
| `reviewer:gaps` | EXECUTOR | Start gap-fix iteration |
| `janitor:commit` | JANITOR | Polling for commit completion; pushes if `AUTOCODE_GIT_PUSH=true` |
| `janitor:push` | JANITOR | Polling for push completion (skipped when `AUTOCODE_GIT_PUSH=false`) |

### Concurrency: Directory-Based Mutex

All role scripts share one lock directory (`${base}.lockdir`). At most one role script runs at a time. Each script calls `acquire_role_lock`, which atomically creates the directory via `mkdir`, writes its PID, acts if it's their turn, and removes the directory on exit via a trap.

### Tmux Session Naming

Sessions are named `{base_name}-{ROLE}` where `base_name` is derived from the repo path: absolute path with `/` replaced by `-`, leading `-` removed. Example: `/home/ltvu/myproject` → `home-ltvu-myproject-PLANNER`.

### State and Metadata Files

All files reside in `~/.claude-auto-code/`:

| File Pattern | Purpose |
|--------------|---------|
| `{base}.lockdir/pid` | Directory-based mutex for all roles (prevents concurrent execution); holds PID of the active role |
| `{base}.state` | Current workflow state (single value from the state machine) |
| `{base}.meta` | Key=value metadata: `plan_path`, `gaps_path`, `requirements`, `review_iteration`, `executor_idle_count`, `executor_restart_count`, `updated_at` |
| `{base}.PLANNER.mail` | User-facing only: requirements for plan creation (written by `claude-code-manager plan`) |
| `{base}.{ROLE}.log` | Temporary current-tick pane snapshot; immediately rotated to `.log.prev` |
| `{base}.{ROLE}.log.prev` | Previous-tick pane snapshot used by `is_session_idle` for change detection; cleaned up by JANITOR |

## Installation

### 1. Check dependencies

```bash
make check
```

This reports which required and optional tools are available and which are missing.

### 2. Configure

```bash
make configure
```

Creates `~/.claude-auto-code/`, copies Claude Code commands to `~/.claude/commands/`, and creates a default config file.

### 3. Install the CLI

```bash
make install # symlinks bin/claude-code-manager to ~/.local/bin/claude-code-manager
```

Ensure `~/.local/bin` is on `$PATH`.

## Running the Workflow

### Using the `claude-code-manager` CLI (recommended)

```bash
cd /path/to/your/repo

# Copy workflow commands into the repo (first time per repo)
claude-code-manager init

# Optionally set a specific requirement
claude-code-manager plan "Add user authentication with OAuth"

# Or skip the PLANNER entirely using an existing plan file
claude-code-manager set-plan /path/to/my-plan.md

# Start the workflow — runs until JANITOR completes and pushes
claude-code-manager run

# Check progress at any time
claude-code-manager status

# Resume after a failure
claude-code-manager retry

# Abort the workflow
claude-code-manager stop
```

`claude-code-manager run` polls all four role scripts every 30 seconds (configurable via `AUTOCODE_INTERVAL`). It exits automatically once JANITOR finishes and clears state.

### Retry after failure

If a role's tmux session dies or the workflow gets stuck, `claude-code-manager retry` reads the current state and metadata, kills any stale sessions, rolls the state back one step, and restarts the workflow loop:

```bash
claude-code-manager retry          # resume and run loop
claude-code-manager retry --once   # resume and run a single tick
```

### Using cron (advanced)

Add an entry to crontab (`crontab -e`):

```cron
0 * * * * cd /path/to/your/repo && claude-code-manager run --once
```

`--once` runs a single tick per cron invocation; the `.lockdir` mutex ensures only one execution runs at a time even if cron fires while a previous tick is still in progress.

When using cron, provide requirements manually:

```bash
echo "Add user authentication with OAuth" > ~/.claude-auto-code/{base_name}.PLANNER.mail
```

### Manual Session Control

Attach to a session: `tmux attach -t {session_name}`
Kill a session: `tmux kill-session -t {session_name}`
List sessions: `tmux ls`

## Testing

```bash
# Run all test suites
make test

# Run individual test suites
bash tests/test_state_meta.sh   # state/metadata unit tests
bash tests/test_role_guards.sh  # role state transition guards
bash tests/test_retry.sh        # retry state rollback and resumption
```

All tests use a temporary `TESTTMP` directory and do not touch the real `~/.claude-auto-code/`.

## Dependencies

- **tmux**: Session management
- **realpath** (from `coreutils`): Resolves absolute repo paths for session naming
- **claude**: Claude Code CLI (used within sessions for `/ralph-loop`, `/planner-*`, `/reviewer-*`)
- **git**: Version control (configurable via `AUTOCODE_CMD_GIT`)

## Development Workflow

When modifying this repository:

1. Run `make check` to verify dependencies
2. Run `make test` after changes to ensure all tests pass
3. Run `make install` to update the symlink in `~/.local/bin/`
4. Role scripts are self-contained state machines — each checks the current state and exits if not their turn
5. The lock directory (`.lockdir`) prevents concurrent execution; stale locks are auto-cleaned if PID is dead

## Role Documentation

All four roles are documented in a single unified reference:
- `WORKFLOW.md` — PLANNER, EXECUTOR, REVIEWER, JANITOR workflow details

## Configuration

### Per-Role Claude Commands

Edit `~/.claude-auto-code/config` (created by `make configure`) to set the command for each role:

```bash
AUTOCODE_CMD_PLANNER=claude
AUTOCODE_CMD_EXECUTOR=claude
AUTOCODE_CMD_REVIEWER=claude
AUTOCODE_CMD_JANITOR=claude
AUTOCODE_CMD_GIT=git
AUTOCODE_GIT_PUSH=true
AUTOCODE_EXECUTOR_IDLE_THRESHOLD=2
AUTOCODE_EXECUTOR_MAX_RESTARTS=3
```

Resolution order (highest priority first):

1. Environment variable (e.g., `AUTOCODE_CMD_PLANNER=claude-opus claude-code-manager run`)
2. `~/.claude-auto-code/config`
3. Built-in default (`claude` for Claude roles, `git` for JANITOR push, `true` for `AUTOCODE_GIT_PUSH`)

Set `AUTOCODE_GIT_PUSH=false` to skip the `git push` step after committing — useful when you want to review changes before pushing or use a CI pipeline instead.

### Polling Interval

Control how often `claude-code-manager run` polls role scripts:

```bash
AUTOCODE_INTERVAL=60 claude-code-manager run   # poll every 60 seconds (default: 30)
```

Run `claude-code-manager status` to see which commands are currently active for each role.

## Script Library

`scripts/tmux-session.sh` provides shared utilities:
- `get_base_name [path]` - Convert repo path to session base name
- `acquire_role_lock ROLE BASE_NAME` - Directory-based mutex via `mkdir` on a `.lockdir`; writes PID; sets `EXIT` trap to remove it
- `create_session ROLE [path]` - Create a tmux session for a role
- `send_command ROLE "cmd" [path]` - Send command to a role's session
- `capture_last_lines ROLE [length] [path]` - Capture and print last N lines
- `is_session_idle ROLE [path]` - Check if session is idle by comparing current pane output (50 lines) against the previous tick's snapshot (`~/.claude-auto-code/{base}.{ROLE}.log.prev`); no blocking sleep
- `interrupt_current_command ROLE [path]` - Send Ctrl+C to interrupt running command
- `load_config` - Load `~/.claude-auto-code/config` and set per-role command variables
- `read_state [path]` / `write_state STATE [path]` / `clear_state [path]` - Workflow state management
- `read_meta KEY [path]` / `write_meta KEY VALUE [path]` / `clear_meta [path]` - Metadata management

## Key Workflow Signals

The scripts detect specific text in session output to drive state transitions:

| Signal | Source | Meaning |
|--------|--------|---------|
| `READY_FOR_REVIEW` | EXECUTOR | Implementation complete, triggers `executor:done` |
| `REVIEWER_APPROVED` | REVIEWER | Implementation approved, triggers `reviewer:approved` |
| `~/.claude/plans/*.md` | PLANNER/REVIEWER | Plan or gaps plan file path, saved to metadata |
