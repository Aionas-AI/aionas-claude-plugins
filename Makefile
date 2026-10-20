# aionas-claude-plugins
#   make test       unit tests of every plugin (no network, temp HOME only)
#   make validate   Claude Code's own manifest check and the plugin's mod tests
#                   (plugin validate, plugin test), on the pinned version, in a
#                   temporary config dir (needs npx and the npm registry)
CLAUDE_CODE_VERSION ?= 2.1.299
SHELL := /bin/bash

.PHONY: test validate

test:
	@bash tests/run.sh

validate:
	@cfg=$$(mktemp -d "$${TMPDIR:-/tmp}/aionas-cc.XXXXXX"); \
	CLAUDE_CONFIG_DIR=$$cfg npx -y @anthropic-ai/claude-code@$(CLAUDE_CODE_VERSION) plugin validate . && \
	CLAUDE_CONFIG_DIR=$$cfg npx -y @anthropic-ai/claude-code@$(CLAUDE_CODE_VERSION) plugin validate plugins/aionas-savings && \
	CLAUDE_CONFIG_DIR=$$cfg npx -y @anthropic-ai/claude-code@$(CLAUDE_CODE_VERSION) plugin test plugins/aionas-savings
