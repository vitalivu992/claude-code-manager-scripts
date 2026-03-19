# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository implements a **multi-agent AI coding workflow** that orchestrates four specialized roles (PLANNER, EXECUTOR, REVIEWER, JANITOR) through tmux sessions and mail files. The workflow is designed to be run via cron, enabling autonomous software development with Claude Code.

### Architecture

The workflow consists of four roles that communicate through mail files in `~/.claude-auto-code/`:

```
┌─────────────┐     plan path      ┌─────────────┐     READY_FOR_REVIEW     ┌─────────────┐
│   PLANNER   │ ─────────────────> │  EXECUTOR   │ ──────────────────────>  │  REVIEWER   │
│             │                    │             │ <──────────────────────  │             │
└─────────────┘                    └─────────────┘    plan for gaps         └─────────────┘
               ┌─────────────┐           │
               │  JANITOR    │ <─────────┘
               │             │      REVIEWER_APPROVED
               └─────────────┘
```

1. **PLANNER** (`scripts/cc-planner-session.sh`): Creates an implementation plan. Extracts plan file path when idle and writes to `.EXECUTOR.mail`.
2. **EXECUTOR** (`scripts/cc-executor-session.sh`): Implements the plan using `/ralph-loop:ralph-loop`. Outputs `READY_FOR_REVIEW` when done. Handles gap-fix iterations from REVIEWER.
3. **REVIEWER** (`scripts/cc-reviewer-session.sh`): Reviews implementation for gaps using `/reviewer-review-impl-gaps`. Either outputs a gaps plan path or `REVIEWER_APPROVED`.
4. **JANITOR** (`scripts/cc-janitor-session.sh`): Runs `$AUTOCODE_CMD_JANITOR` (default: `claude`), `$AUTOCODE_CMD_GIT push` (default: `git push`), cleans up state files, and terminates all workflow sessions.

### Tmux Session Naming

Sessions are named `{base_name}-{ROLE}` where `base_name` is derived from the repo path: absolute path with `/` replaced by `-`, leading `-` removed. Example: `/home/ltvu/myproject` → `home-ltvu-myproject-PLANNER`.

### Mail Files

All mail files reside in `~/.claude-auto-code/`:

| File Pattern | Writer | Reader | Content |
|--------------|--------|--------|---------|
| `{base}.PLANNER.mail` | User | PLANNER script | Requirements for plan creation (optional) |
| `{base}-PLANNER.EXECUTOR.mail` | PLANNER script | EXECUTOR script | Plan file path |
| `{base}-EXECUTOR.REVIEWER.mail` | EXECUTOR script | REVIEWER script | Plan file path (when READY_FOR_REVIEW) |
| `{base}-REVIEWER.EXECUTOR.mail` | REVIEWER script | EXECUTOR script | Gaps plan path OR `REVIEWER_APPROVED` |
| `{base}-EXECUTOR.JANITOR.mail` | EXECUTOR script | JANITOR script | `REVIEWER_APPROVED` |
| `{base}.EXECUTOR.plan` | EXECUTOR script | EXECUTOR script | Original plan path (persistent) |

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
make install        # symlinks bin/autocode to ~/.local/bin/autocode
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

# Abort the workflow
autocode stop
```

`autocode run` polls all four role scripts every 30 seconds (configurable via `AUTOCODE_INTERVAL`). It exits automatically once JANITOR finishes.

### Using cron (advanced)

Add entries to crontab (`crontab -e`):

```cron
*/5 * * * * cd /path/to/your/repo && /path/to/autocode-scripts/scripts/cc-planner-session.sh
*/5 * * * * cd /path/to/your/repo && /path/to/autocode-scripts/scripts/cc-executor-session.sh
*/5 * * * * cd /path/to/your/repo && /path/to/autocode-scripts/scripts/cc-reviewer-session.sh
*/5 * * * * cd /path/to/your/repo && /path/to/autocode-scripts/scripts/cc-janitor-session.sh
```

When using cron, provide requirements manually:

```bash
echo "Add user authentication with OAuth" > ~/.claude-auto-code/{base_name}.PLANNER.mail
```

### Manual Session Control

Attach to a session: `tmux attach -t {session_name}`
Kill a session: `tmux kill-session -t {session_name}`
List sessions: `tmux ls`

## Dependencies

- **tmux**: Session management
- **flock** (from `util-linux`): Concurrency protection for cron runs
- **realpath** (from `coreutils`): Resolves absolute repo paths for session naming
- **claude**: Claude Code CLI (used within sessions for `/ralph-loop`, `/planner-*`, `/reviewer-*`)
- **git**: Version control (configurable via `AUTOCODE_CMD_GIT`)
- **node/npm** (optional): For `npx` support and global install via `npm link`

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
- `is_session_idle ROLE [path]` - Check if session is idle (no output change in 2 seconds)
- `interrupt_current_command ROLE [path]` - Send Ctrl+C to interrupt running command
- `load_config` - Load `~/.claude-auto-code/config` and set per-role command variables

## Key Workflow Signals

The scripts detect specific text in session output to drive the workflow:

| Signal | Source | Meaning |
|--------|--------|---------|
| `READY_FOR_REVIEW` | EXECUTOR | Implementation complete, ready for review |
| `REVIEWER_APPROVED` | REVIEWER | Implementation approved, forward to JANITOR |
| `~/.claude/plans/*.md` | PLANNER/REVIEWER | Plan or gaps plan file path |
