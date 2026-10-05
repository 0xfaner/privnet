SHELL := bash
SCRIPTS := privnet.sh

.PHONY: help lint

help: ## Show available targets
	@awk -F ':.*## ' '/^[a-zA-Z_-]+:.*## / {printf "  %-6s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

lint: ## Run ShellCheck
	shellcheck -x $(SCRIPTS)
