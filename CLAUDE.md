# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements a **multi-agent AI coding workflow** that orchestrates four specialized roles (PLANNER, EXECUTOR, REVIEWER, JANITOR) through tmux sessions and a shared state file. The workflow is designed to be run via cron or the `autocode` CLI, enabling autonomous software development with Claude Code.

### Architecture

The workflow consists of four roles coordinated through a central state file in `~/.claude-auto-code/`:

```
┌─────────────┐  planner:done  ┌─────────────┐  executor:done  ┌─────────────┐
│   PLANNER   │ ─────────────> │   EXECUTOR   │ ─────────────> │   REVIEWER   │
│             │                │              │ <───────────── │             │
└─────────────┘                └──────────────┘  reviewer:gaps  └─────────────┘
                                                                      │
                                ┌─────────────┐                       │
                                │   JANITOR   │ <─────────────────────┘
                                │             │  reviewer:approved
                                └─────────────┘
```

1. **PLANNER** (`scripts/cc-planner-session.sh`): Creates an implementation plan. Extracts plan file path when idle and transitions state to `planner:done`.
2. **EXECUTOR** (`scripts/cc-executor-session.sh`): Implements the plan using `/ralph-loop:ralph-loop`. Transitions to `executor:done` when `READY_FOR_REVIEW` is detected. Handles gap-fix iterations from REVIEWER.
3. **REVIEWER** (`scripts/cc-reviewer-session.sh`): Reviews implementation for gaps using `/reviewer-review-impl-gaps`. Transitions to `reviewer:approved` or `reviewer:gaps`.
4. **JANITOR** (`scripts/cc-janitor-session.sh`): Runs `$AUTOCODE_CMD_JANITOR` for commits, `$AUTOCODE_CMD_GIT push`, cleans up all state, and terminates all workflow sessions.

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
| `janitor:commit` | JANITOR | Polling for commit completion |
| `janitor:push` | JANITOR | Polling for push completion |

### Concurrency: Single Flock

All role scripts share one lock file (`${base}.lock`). At most one role script runs at a time. Each script acquires the lock, checks the state, acts if it's their turn, and releases the lock on exit.

### Tmux Session Naming

Sessions are named `{base_name}-{ROLE}` where `base_name` is derived from the repo path: absolute path with `/` replaced by `-`, leading `-` removed. Example: `/home/ltvu/myproject` → `home-ltvu-myproject-PLANNER`.

### State and Metadata Files

All files reside in `~/.claude-auto-code/`:

| File Pattern | Purpose |
|--------------|---------|
| `{base}.lock` | Shared flock for all roles (prevents concurrent execution) |
| `{base}.state` | Current workflow state (single value from the state machine) |
| `{base}.meta` | Key=value metadata: `plan_path`, `gaps_path`, `requirements`, `review_iteration`, `updated_at` |
| `{base}.PLANNER.mail` | User-facing only: requirements for plan creation (written by `autocode plan`) |

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
make install # symlinks bin/autocode to ~/.local/bin/autocode
```

Ensure `~/.local/bin` is on `$PATH`.

## Running the Workflow

### Using the `autocode` CLI (recommended)

```bash
cd /path/to/your/repo

# Optionally set a specific requirement
autocode plan "Add user authentication with OAuth"

# Start the workflow — runs until JANITOR completes and pushes
autocode run

# Check progress at any time
autocode status

# Resume after a failure
autocode retry

# Abort the workflow
autocode stop
```

`autocode run` polls all four role scripts every 30 seconds (configurable via `AUTOCODE_INTERVAL`). It exits automatically once JANITOR finishes and clears state.

### Retry after failure

If a role's tmux session dies or the workflow gets stuck, `autocode retry` reads the current state and metadata, kills any stale sessions, rolls the state back one step, and restarts the workflow loop:

```bash
autocode retry          # resume and run loop
autocode retry --once   # resume and run a single tick
```

### Using cron (advanced)

Add entries to crontab (`crontab -e`):

```cron
*/5 * * * * cd /path/to/your/repo && /path/to/autocode-scripts/scripts/cc-planner-session.sh
*/5 * * * * cd /path/to/your/repo && /path/to/autocode-scripts/scripts/cc-executor-session.sh
*/5 * * * * cd /path/to/your/repo && /path/to/autocode-scripts/scripts/cc-reviewer-session.sh
*/5 * * * * cd /path/to/your/repo && /path/to/autocode-scripts/scripts/cc-janitor-session.sh
```

With the shared flock, only one role script executes per cron cycle. Each script exits immediately if it's not their turn (based on state).

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
make test
```

Runs three test suites:
- **test_state_meta.sh** — unit tests for state/metadata read/write/clear functions
- **test_role_guards.sh** — verifies each role script only runs for its designated states
- **test_retry.sh** — end-to-end tests for `autocode retry` state rollback and resumption

## Dependencies

- **tmux**: Session management
- **flock** (from `util-linux`): Concurrency protection (single lock per repo)
- **realpath** (from `coreutils`): Resolves absolute repo paths for session naming
- **claude**: Claude Code CLI (used within sessions for `/ralph-loop`, `/planner-*`, `/reviewer-*`)
- **git**: Version control (configurable via `AUTOCODE_CMD_GIT`)

## Role Documentation

Each role has detailed documentation in the repository root:
- `PLANNER.md` - Planner workflow details
- `EXECUTOR.md` - Executor workflow details
- `REVIEWER.md` - Reviewer workflow details
- `JANITOR.md` - Janitor workflow details

## Configuration

### Per-Role Claude Commands

Edit `~/.claude-auto-code/config` (created by `make configure`) to set the command for each role:

```bash
AUTOCODE_CMD_PLANNER=claude
AUTOCODE_CMD_EXECUTOR=claude
AUTOCODE_CMD_REVIEWER=claude
AUTOCODE_CMD_JANITOR=claude
AUTOCODE_CMD_GIT=git
```

Resolution order (highest priority first):

1. Environment variable (e.g., `AUTOCODE_CMD_PLANNER=claude-opus autocode run`)
2. `~/.claude-auto-code/config`
3. Built-in default (`claude` for Claude roles, `git` for JANITOR push)

Run `autocode status` to see which commands are currently active for each role.

## Script Library

`scripts/tmux-session.sh` provides shared utilities:
- `get_base_name [path]` - Convert repo path to session base name
- `create_session ROLE [path]` - Create a tmux session for a role
- `send_command ROLE "cmd" [path]` - Send command to a role's session
- `capture_last_lines ROLE [length] [path]` - Capture and print last N lines
- `is_session_idle ROLE [path]` - Check if session is idle (no output change in 5 seconds)
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
