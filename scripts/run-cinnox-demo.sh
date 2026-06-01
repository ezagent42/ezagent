#!/usr/bin/env bash
set -euo pipefail

# WSL / erlexec workaround: the merged Windows PATH is too long for PTY-backed
# cc agents. Keep only the Linux-side PATH entries and prepend ~/.local/bin so
# `uv run --script ...` works for the esr-bridge + kb_search MCP servers.
TRIMMED_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '^/mnt/' | paste -sd: -)
export PATH="$HOME/.local/bin:${TRIMMED_PATH}"

# Match the proven fast-enough customer-service runtime:
# - Sonnet instead of Opus
# - extended thinking disabled (avoids 5-30s pre-output churn)
export ANTHROPIC_MODEL="sonnet"
export MAX_THINKING_TOKENS="0"

export PORT="${PORT:-10042}"

exec mix phx.server
