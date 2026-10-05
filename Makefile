SHELL := bash
SCRIPTS := privnet.sh

.PHONY: help lint

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-6s %s\n", $$1, $$2}'

lint: ## Run shellcheck over all scripts
	shellcheck -x $(SCRIPTS)
	@echo "shellcheck: OK"
