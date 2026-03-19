.DEFAULT_GOAL := help

INSTALL_DIR   ?= $(HOME)/.local/bin
COMMANDS_DIR  ?= $(HOME)/.claude/commands
DATADIR       ?= $(HOME)/.claude-auto-code
BIN           := $(CURDIR)/bin/autocode

GREEN  := \033[0;32m
RED    := \033[0;31m
YELLOW := \033[0;33m
RESET  := \033[0m
BOLD   := \033[1m
OK     := $(GREEN)✔$(RESET)
MISS   := $(RED)✘$(RESET)

.PHONY: help check configure install

help: ## Show this help message
	@printf "$(BOLD)autocode-scripts$(RESET) — multi-agent AI coding workflow\n\n"
	@printf "$(BOLD)USAGE$(RESET)\n"
	@printf "  make <target>\n\n"
	@printf "$(BOLD)TARGETS$(RESET)\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*?##/ { printf "  $(BOLD)%-15s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n$(BOLD)QUICKSTART$(RESET)\n"
	@printf "  make check        # verify all dependencies\n"
	@printf "  make configure    # set up directories and install commands\n"
	@printf "  make install      # add autocode to PATH\n"
	@printf "\n$(BOLD)THEN, FROM ANY REPO$(RESET)\n"
	@printf "  autocode plan \"Add feature X\"   # set requirements\n"
	@printf "  autocode run                     # start the workflow\n"
	@printf "  autocode status                  # check progress\n"
	@printf "  autocode stop                    # abort\n"

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
	_check flock         "flock (util-linux)" "apt install util-linux"; \
	_check git           "git"               "apt install git"; \
	_check realpath      "realpath (coreutils)" "apt install coreutils"; \
	_check claude "claude"     "install Claude Code CLI and add alias"; \
	_check git "git" "apt install git"
	@printf "\n$(BOLD)Optional dependencies$(RESET)\n"
	@_checkopt() { \
		cmd="$$1"; label="$$2"; hint="$$3"; \
		if command -v "$$cmd" >/dev/null 2>&1; then \
			printf "  $(OK) %-22s %s\n" "$$label" "$$(command -v $$cmd)"; \
		else \
			printf "  $(YELLOW)~$(RESET) %-22s not found  — $$hint\n" "$$label"; \
		fi; \
	}; \
	_checkopt node "node (for npx)"  "https://nodejs.org"; \
	_checkopt npm  "npm (for npx)"   "https://nodejs.org"

configure: ## Create directories and install Claude Code commands
	@printf "$(BOLD)Configuring autocode-scripts...$(RESET)\n"
	@mkdir -p "$(DATADIR)"
	@printf "  $(OK) Created $(DATADIR)\n"
	@mkdir -p "$(COMMANDS_DIR)"
	@cp -u commands/*.md "$(COMMANDS_DIR)/"
	@printf "  $(OK) Copied commands to $(COMMANDS_DIR)\n"
	@if [ ! -f "$(DATADIR)/config" ]; then \
		printf '# autocode per-role command configuration\n# Set the CLI command to use for each role.\n# Environment variables take precedence over this file.\n\nAUTOCODE_CMD_PLANNER=claude\nAUTOCODE_CMD_EXECUTOR=claude\nAUTOCODE_CMD_REVIEWER=claude\nAUTOCODE_CMD_JANITOR=claude\nAUTOCODE_CMD_GIT=git\n' > "$(DATADIR)/config"; \
		printf "  $(OK) Created $(DATADIR)/config\n"; \
	else \
		printf "  $(YELLOW)~$(RESET) $(DATADIR)/config already exists, skipping\n"; \
	fi
	@printf "\n$(GREEN)Done!$(RESET) Run 'make install' then 'autocode help' to get started.\n"

install: ## Symlink bin/autocode into ~/.local/bin (no npm required)
	@mkdir -p "$(INSTALL_DIR)"
	@ln -sf "$(BIN)" "$(INSTALL_DIR)/autocode"
	@printf "  $(OK) Symlinked $(BIN) -> $(INSTALL_DIR)/autocode\n"
	@if echo "$$PATH" | grep -q "$(INSTALL_DIR)"; then \
		printf "  $(OK) $(INSTALL_DIR) is already in PATH\n"; \
	else \
		printf "  $(YELLOW)!$(RESET)  $(INSTALL_DIR) is not in PATH.\n"; \
		printf "     Add the following to your shell profile:\n"; \
		printf "     $(BOLD)export PATH=\"$(INSTALL_DIR):$$PATH\"$(RESET)\n"; \
	fi
