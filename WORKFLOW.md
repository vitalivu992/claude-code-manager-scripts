# Workflow Role Reference

This document describes all four role scripts that drive the multi-agent workflow: **PLANNER**, **EXECUTOR**, **REVIEWER**, and **JANITOR**. Each role is a separate script under `scripts/` and is invoked repeatedly by `claude-code-manager run` (or cron). Roles coordinate through a shared state file; only one role executes at a time, protected by a directory-based mutex (`.lockdir`).

---

## Concurrency

All role scripts share a single lock directory (`~/.claude-auto-code/<base>.lockdir`). Before acting, each script calls `acquire_role_lock`, which atomically creates the directory via `mkdir`. If another role holds the lock (directory already exists and PID is alive), the script exits immediately. The lock is released automatically on exit via a trap.

---

## Data Directory and Files

All state lives under `~/.claude-auto-code/`, keyed by a base name derived from the repo path (absolute path with `/` replaced by `-`, leading `-` removed).

| File | Written by | Purpose |
|------|-----------|---------|
| `<base>.lockdir/pid` | All role scripts | Directory-based mutex; holds PID of the active role |
| `<base>.state` | All role scripts | Current workflow state (single value) |
| `<base>.meta` | All role scripts | Key-value metadata: `plan_path`, `gaps_path`, `requirements`, `review_iteration`, `updated_at` |
| `<base>.PLANNER.mail` | `claude-code-manager plan` | User-provided requirements; consumed on first PLANNER run |

---

## State Machine

| State | Active Role | What Happens |
|-------|-------------|--------------|
| _(empty)_ | PLANNER | Starts planning session |
| `planner:active` | PLANNER | Polls for plan completion |
| `planner:done` | EXECUTOR | Starts implementation session |
| `executor:active` | EXECUTOR | Polls for `READY_FOR_REVIEW` |
| `executor:done` | REVIEWER | Starts review session |
| `reviewer:active` | REVIEWER | Polls for approval or gaps |
| `reviewer:approved` | JANITOR | Starts commit session |
| `reviewer:gaps` | EXECUTOR | Starts gap-fix iteration (max 3; stops workflow if exceeded) |
| `janitor:commit` | JANITOR | Polls for commit completion, then pushes (if `AUTOCODE_GIT_PUSH=true`) |
| `janitor:push` | JANITOR | Polls for push completion, then cleans up (skipped when `AUTOCODE_GIT_PUSH=false`) |

---

## PLANNER (`scripts/cc-planner-session.sh`)

### Runs when state is

- **empty** — start planning
- **`planner:active`** — check if planning is done

### What it does each run

**State is empty → create session and start planning**

- Creates a detached tmux session `<base>-PLANNER`.
- If `<base>.PLANNER.mail` exists: reads requirements, saves them to `requirements` in metadata, deletes the mail file, launches `$AUTOCODE_CMD_PLANNER`, then sends `/planner-create-plan <requirements>`.
- Otherwise: launches `$AUTOCODE_CMD_PLANNER /planner-auto-plan`.
- Writes state `planner:active` and `updated_at`.

**State is `planner:active` → poll for completion**

- Verifies the PLANNER session exists.
- Calls `is_session_idle "PLANNER"` (two pane snapshots, 5 s apart).
  - **Still active:** prints status, exits.
  - **Idle:** greps last 200 pane lines for a `~/.claude/plans/` path, saves it as `plan_path` in metadata, writes state `planner:done`, kills the session.

### Key signals

| Signal | Meaning |
|--------|---------|
| `~/.claude/plans/<file>.md` in pane output | Plan file path — saved as `plan_path` |

### Commands used

- `/planner-create-plan` — used when a specific requirement is provided
- `/planner-auto-plan` — used when no requirement is provided

---

## EXECUTOR (`scripts/cc-executor-session.sh`)

### Runs when state is

- **`planner:done`** — start initial execution
- **`executor:active`** — poll for `READY_FOR_REVIEW`
- **`reviewer:gaps`** — start gap-fix iteration

### What it does each run

**State is `executor:active` → poll for completion**

- Verifies the EXECUTOR session exists.
- Calls `is_session_idle "EXECUTOR"`.
  - **Still active:** exits.
  - **Idle:** captures last 50 pane lines.
    - If `READY_FOR_REVIEW` found: sends `/exit`, kills session, writes state `executor:done`.

**State is `planner:done` → start execution**

- Reads `plan_path` from metadata.
- Creates the EXECUTOR session, launches `$AUTOCODE_CMD_EXECUTOR`.
- Sends:
  ```
  /ralph-loop:ralph-loop "review existing source code, documents and execute the plan
  <plan_path>, make sure all requirements are fulfilled, all tests pass then output
  READY_FOR_REVIEW" --completion-promise "READY_FOR_REVIEW"
  ```
- Writes `review_iteration=0` to metadata, writes state `executor:active`.

**State is `reviewer:gaps` → fix gaps**

- Reads `plan_path` and `gaps_path` from metadata, increments `review_iteration`.
- If `review_iteration` would exceed 3: prints a warning, clears all state and metadata, kills all role sessions, and exits. The workflow stops and the user must intervene manually.
- Otherwise creates the EXECUTOR session, launches `$AUTOCODE_CMD_EXECUTOR`.
- Sends (note priority ordering — gaps plan is PRIMARY):
  ```
  /ralph-loop:ralph-loop "Fix implementation gaps. PRIMARY plan to implement: <gaps_path>
  (this is the revised plan — it supersedes the original). Background context — original
  plan: <plan_path>. Review the code changes against the gaps plan, validate which gaps are
  legitimate, then fix them. Make sure all requirements are fulfilled, all tests pass then
  output READY_FOR_REVIEW" --completion-promise "READY_FOR_REVIEW"
  ```
- Writes state `executor:active`.

### Key signals

| Signal | Meaning |
|--------|---------|
| `READY_FOR_REVIEW` in pane output | Implementation complete — triggers `executor:done` |

### Commands used

- `/ralph-loop:ralph-loop` — drives the implementation loop inside the EXECUTOR session

---

## REVIEWER (`scripts/cc-reviewer-session.sh`)

### Runs when state is

- **`executor:done`** — start review
- **`reviewer:active`** — poll for review outcome

### What it does each run

**State is `executor:done` → start review**

- Reads `plan_path` from metadata.
- Creates the REVIEWER session, launches `$AUTOCODE_CMD_REVIEWER`.
- Sends `/reviewer-review-impl-gaps <plan_path>`.
- Writes state `reviewer:active`.

**State is `reviewer:active` → poll for outcome**

- Verifies the REVIEWER session exists.
- Calls `is_session_idle "REVIEWER"`.
  - **Still active:** exits.
  - **Idle:** captures last 50 pane lines and checks (in order):
    1. If a line matches exactly `REVIEWER_APPROVED`: sends `/exit`, kills session, writes state `reviewer:approved`.
    2. If a `~/.claude/plans/` path is found that differs from the original `plan_path`: saves it as `gaps_path`, sends `/exit`, kills session, writes state `reviewer:gaps`.
    3. Otherwise: waits for next poll cycle.

### Key signals

| Signal | Meaning |
|--------|---------|
| `REVIEWER_APPROVED` (exact line) | Implementation approved — triggers `reviewer:approved` |
| `~/.claude/plans/<file>.md` in pane output | Gaps plan file path — triggers `reviewer:gaps` |

### Commands used

- `/reviewer-review-impl-gaps` — performs the gap review inside the REVIEWER session

---

## JANITOR (`scripts/cc-janitor-session.sh`)

### Runs when state is

- **`reviewer:approved`** — start commit
- **`janitor:commit`** — poll for commit completion, then push
- **`janitor:push`** — poll for push completion, then clean up

### What it does each run

**State is `reviewer:approved` → start commit**

- Creates the JANITOR session, launches `$AUTOCODE_CMD_JANITOR`.
- Sends `/git-commit`.
- Writes state `janitor:commit`.

**State is `janitor:commit` → push**

- Verifies the JANITOR session exists and is idle.
- If `AUTOCODE_GIT_PUSH=true` (default): sends `$AUTOCODE_CMD_GIT push` and writes state `janitor:push`.
- If `AUTOCODE_GIT_PUSH=false`: skips push, immediately clears state/metadata, removes `.lockdir`, and kills all sessions.

**State is `janitor:push` → clean up**

- Verifies the JANITOR session exists and is idle.
- Clears the state file and metadata file.
- Removes the `<base>.lockdir`.
- Kills all four role sessions (PLANNER, EXECUTOR, REVIEWER, JANITOR).

After cleanup, no workflow sessions remain, all state files are removed, and the repo has been committed and pushed.

### Commands used

- `/git-commit` — commits all staged changes in the JANITOR session
- `$AUTOCODE_CMD_GIT push` — pushes to remote (default: `git push`); skipped when `AUTOCODE_GIT_PUSH=false`

---

## Dependencies

All role scripts depend on:

- **tmux** — session creation, pane capture, key sending
- **`scripts/tmux-session.sh`** — shared library providing all utility functions
- **`claude`** (or configured alternative via shell alias) — the Claude Code CLI used inside each session

The library functions used across roles:

| Function | Purpose |
|----------|---------|
| `get_base_name [path]` | Convert repo path to session base name |
| `acquire_role_lock ROLE BASE_NAME` | Directory-based mutex via `mkdir` |
| `create_session ROLE [path]` | Create a detached tmux session |
| `send_command ROLE CMD [path]` | Send a command string to a role's pane |
| `is_session_idle ROLE [path]` | Returns 0 if pane output unchanged over 5 s |
| `capture_last_lines ROLE [N] [path]` | Capture last N lines from a role's pane |
| `read_state / write_state / clear_state` | Workflow state I/O |
| `read_meta / write_meta / clear_meta` | Metadata key-value I/O |
| `load_config` | Load `~/.claude-auto-code/config` and set `AUTOCODE_CMD_*` and `AUTOCODE_GIT_PUSH` defaults |
