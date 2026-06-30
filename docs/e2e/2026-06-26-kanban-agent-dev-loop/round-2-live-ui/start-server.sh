#!/usr/bin/env bash
# 起 phx server，detached。无 pkill 自匹配。
cd /home/yaosh/projects/ezagent-biz/.claude/worktrees/kanban-agent-e2e || exit 1
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate bash 2>/dev/null)" 2>/dev/null
export PORT=10042 WORLD_VITE_PORT=5174
exec mise exec -- mix phx.server
