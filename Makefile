SHELL         := /bin/bash
.DEFAULT_GOAL := help

INSTALL_DIR          ?= $(HOME)/.local/bin
COMMANDS_DIR         ?= $(HOME)/.claude/commands
DATADIR              ?= $(HOME)/.claude-auto-code
BIN           := $(CURDIR)/bin/claude-code-manager

GREEN  := \033[0;32m
RED    := \033[0;31m
YELLOW := \033[0;33m
RESET  := \033[0m
BOLD   := \033[1m
OK     := $(GREEN)✔$(RESET)
MISS   := $(RED)✘$(RESET)

.PHONY: help check configure install test

help: ## Show this help message
	@printf "$(BOLD)claude-code-manager-scripts$(RESET) — multi-agent AI coding workflow\n\n"
	@printf "$(BOLD)USAGE$(RESET)\n"
	@printf "  make <target>\n\n"
	@printf "$(BOLD)TARGETS$(RESET)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  $(BOLD)%-15s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n$(BOLD)QUICKSTART$(RESET)\n"
	@printf "  make check        # verify all dependencies\n"
	@printf "  make configure    # set up data directory and config\n"
	@printf "  make install      # add claude-code-manager to PATH and copy commands to ~/.claude/commands/\n"
	@printf "\n$(BOLD)THEN, FROM ANY REPO$(RESET)\n"
	@printf "  claude-code-manager plan \"Add feature X\"   # set requirements\n"
	@printf "  claude-code-manager run                     # start the workflow\n"
	@printf "  claude-code-manager status                  # check progress\n"
	@printf "  claude-code-manager stop                    # abort\n"

check: ## Check all required and optional dependencies
	@printf "$(BOLD)Required dependencies$(RESET)\n"
	@_check() { \
		cmd="$$1"; label="$$2"; hint="$$3"; \
		if command -v "$$cmd" >/dev/null 2>&1; then \
			printf "  $(OK) %-22s %s\n" "$$label" "$$(command -v $$cmd)"; \
		else \
			printf "  $(MISS) %-22s $(YELLOW)missing$(RESET) — $$hint\n" "$$label"; \
		fi; \
	}; \
	_check tmux          "tmux"              "apt install tmux"; \
	_check git           "git"               "apt install git"; \
	_check realpath      "realpath (coreutils)" "apt install coreutils"; \
	_check claude "claude"     "install Claude Code CLI and add alias";

configure: ## Create data directory and default config file
	@printf "$(BOLD)Configuring claude-code-manager-scripts...$(RESET)\n"
	@mkdir -p "$(DATADIR)"
	@printf "  $(OK) Created $(DATADIR)\n"
	@if [ ! -f "$(DATADIR)/config" ]; then \
		printf '# claude-code-manager per-role command configuration\n# Set the CLI command to use for each role.\n# Environment variables take precedence over this file.\n\nAUTOCODE_CMD_PLANNER=claude\nAUTOCODE_CMD_EXECUTOR=claude\nAUTOCODE_CMD_REVIEWER=claude\nAUTOCODE_CMD_JANITOR=claude\nAUTOCODE_CMD_GIT=git\nAUTOCODE_GIT_PUSH=true\n' > "$(DATADIR)/config"; \
		printf "  $(OK) Created $(DATADIR)/config\n"; \
	else \
		printf "  $(YELLOW)~$(RESET) $(DATADIR)/config already exists, skipping\n"; \
	fi
	@printf "\n$(GREEN)Done!$(RESET) Run 'make install' then 'claude-code-manager help' to get started.\n"

test: ## Run all tests
	@printf "$(BOLD)Running tests...$(RESET)\n"
	@bash tests/test_state_meta.sh
	@bash tests/test_role_guards.sh
	@bash tests/test_retry.sh
	@bash tests/test_idle_detection.sh
	@bash tests/test_executor_idle_restart.sh
	@printf "\n$(GREEN)All test suites passed.$(RESET)\n"

install: ## Symlink bin/claude-code-manager into ~/.local/bin and copy commands to ~/.claude/commands/
	@mkdir -p "$(INSTALL_DIR)"
	@ln -sf "$(BIN)" "$(INSTALL_DIR)/claude-code-manager"
	@printf "  $(OK) Symlinked $(BIN) -> $(INSTALL_DIR)/claude-code-manager\n"
	@mkdir -p "$(COMMANDS_DIR)"
	@cp -u commands/*.md "$(COMMANDS_DIR)/"
	@printf "  $(OK) Copied commands to $(COMMANDS_DIR)\n"
	@if echo "$$PATH" | grep -q "$(INSTALL_DIR)"; then \
		printf "  $(OK) $(INSTALL_DIR) is already in PATH\n"; \
	else \
		printf "  $(YELLOW)!$(RESET)  $(INSTALL_DIR) is not in PATH.\n"; \
		printf "     Add the following to your shell profile:\n"; \
		printf "     $(BOLD)export PATH=\"$(INSTALL_DIR):$$PATH\"$(RESET)\n"; \
	fi
