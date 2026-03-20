# claude-code-manager-scripts

A multi-agent AI coding workflow that autonomously plans, implements, reviews, and commits code using Claude Code. Four specialized agents — **PLANNER**, **EXECUTOR**, **REVIEWER**, and **JANITOR** — coordinate through tmux sessions and a shared state machine.

## How It Works

```
PLANNER ──planner:done──> EXECUTOR ──executor:done──> REVIEWER
                              ^                            │
                              │        reviewer:gaps       │
                              └────────────────────────────┤
                                                           │ reviewer:approved
                                                       JANITOR
                                                   (commit + push)
```

| Role | Responsibility |
|------|---------------|
| **PLANNER** | Reads requirements and produces an implementation plan |
| **EXECUTOR** | Implements the plan; loops back if the REVIEWER finds gaps |
| **REVIEWER** | Audits the implementation; either approves or documents gaps |
| **JANITOR** | Commits, pushes, and tears down all workflow sessions |

Each role runs in its own tmux session. A directory-based mutex (`.lockdir`) ensures only one role executes at a time. All coordination state lives in `~/.claude-auto-code/`.

## Prerequisites

- **tmux** — session management (`apt install tmux`)
- **git** — version control (`apt install git`)
- **realpath** — path resolution (`apt install coreutils`)
- **claude** — [Claude Code CLI](https://claude.ai/code)

Verify everything is in place:

```bash
make check
```

## Installation

```bash
# 1. Clone the repo
git clone https://github.com/vitalivu992/claude-code-manager-scripts.git ~/claude-code-manager-scripts
cd ~/claude-code-manager-scripts

# 2. Check dependencies
make check

# 3. Create data directory and default config
make configure

# 4. Install the CLI (symlinks to ~/.local/bin)
make install
```

Make sure `~/.local/bin` is on your `$PATH`. If not, add this to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Quick Start

```bash
cd /path/to/your/repo

# Optional: set a specific goal
claude-code-manager plan "Add user authentication with OAuth"

# Run the full autonomous workflow
claude-code-manager run
```

The workflow runs until the JANITOR commits and pushes, then exits cleanly.

## CLI Reference

```
claude-code-manager <command> [args]
```

| Command | Description |
|---------|-------------|
| `plan "<requirement>"` | Set requirements for the next PLANNER run |
| `run [--once]` | Run the workflow loop; `--once` executes a single tick |
| `retry [--once]` | Resume from current state after a failure |
| `status` | Show current state, metadata, and active sessions |
| `stop` | Kill all sessions and clear state |
| `help` | Show help |

### Examples

```bash
# Start with a specific feature request
claude-code-manager plan "Refactor database layer to use repository pattern"
claude-code-manager run

# Check what's happening
claude-code-manager status

# Something went wrong — resume
claude-code-manager retry

# Emergency stop
claude-code-manager stop
```

## Configuration

`make configure` creates `~/.claude-auto-code/config` with per-role command overrides:

```bash
AUTOCODE_CMD_PLANNER=claude
AUTOCODE_CMD_EXECUTOR=claude
AUTOCODE_CMD_REVIEWER=claude
AUTOCODE_CMD_JANITOR=claude
AUTOCODE_CMD_GIT=git
```

You can also override via environment variables (takes highest priority):

```bash
AUTOCODE_CMD_EXECUTOR=claude-opus claude-code-manager run
```

Control the polling interval:

```bash
AUTOCODE_INTERVAL=60 claude-code-manager run   # poll every 60 seconds (default: 30)
```

## Monitoring Sessions

Attach to any running role session at any time:

```bash
tmux attach -t <base-name>-PLANNER
tmux attach -t <base-name>-EXECUTOR
tmux attach -t <base-name>-REVIEWER
tmux attach -t <base-name>-JANITOR
```

The `<base-name>` is derived from your repo path: e.g. `/home/you/myproject` → `home-you-myproject`.

List all active sessions:

```bash
tmux ls
```

## Recovering from Failures

If a session crashes or the workflow gets stuck, use `retry` to resume:

```bash
claude-code-manager retry        # rolls back one state, restarts loop
claude-code-manager retry --once # single tick, useful for debugging
```

`retry` kills any stale sessions and backs the state machine up one step before re-running.

## Using with Cron (Advanced)

For unattended operation, add a single entry to crontab:

```cron
*/5 * * * * cd /path/to/your/repo && claude-code-manager run --once
```

`--once` runs a single workflow tick per cron invocation. The `.lockdir` mutex ensures only one execution runs at a time even if cron fires while a previous tick is still active.


## State Machine Reference

| State | Active Role | What Happens |
|-------|-------------|--------------|
| _(empty)_ | PLANNER | Starts planning |
| `planner:active` | PLANNER | Waits for plan completion |
| `planner:done` | EXECUTOR | Starts implementation |
| `executor:active` | EXECUTOR | Waits for `READY_FOR_REVIEW` |
| `executor:done` | REVIEWER | Starts review |
| `reviewer:active` | REVIEWER | Waits for approval or gaps |
| `reviewer:approved` | JANITOR | Starts commit |
| `reviewer:gaps` | EXECUTOR | Starts gap-fix iteration |
| `janitor:commit` | JANITOR | Waits for commit, then pushes |
| `janitor:push` | JANITOR | Waits for push, then cleans up |

## Testing

```bash
make test
```

Runs three suites: state/metadata unit tests, role guard tests, and end-to-end retry tests.

State and metadata files at runtime (`~/.claude-auto-code/`):

| File | Purpose |
|------|---------|
| `<base>.lockdir/pid` | Directory-based mutex — prevents concurrent role execution |
| `<base>.state` | Current workflow state |
| `<base>.meta` | Key-value metadata (`plan_path`, `gaps_path`, `review_iteration`, …) |
| `<base>.PLANNER.mail` | Requirement text consumed on first PLANNER run |
