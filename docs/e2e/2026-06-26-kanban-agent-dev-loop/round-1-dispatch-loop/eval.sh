#!/usr/bin/env bash
# erpc 把一段 Elixir 代码 eval 进活的 ezagent_runtime 节点。
# 用法: EVAL_CODE='...' /tmp/kanban-e2e/eval.sh   或   /tmp/kanban-e2e/eval.sh <文件.exs>
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd /home/yaosh/projects/ezagent-biz/.claude/worktrees/kanban-agent-e2e
eval "$(mise activate bash 2>/dev/null)" 2>/dev/null
COOKIE=$(cat ~/.ezagent/default/runtime/cookie)
if [ "${1:-}" != "" ] && [ -f "${1:-}" ]; then EVAL_CODE=$(cat "$1"); fi
export EVAL_CODE
mise exec -- elixir --name "driver_$$@127.0.0.1" --cookie "$COOKIE" -e '
  node = :"ezagent_runtime@127.0.0.1"
  case Node.connect(node) do
    true -> :ok
    other -> IO.puts("CONNECT_FAILED: #{inspect(other)}"); System.halt(2)
  end
  code = System.get_env("EVAL_CODE")
  try do
    {res, _} = :erpc.call(node, Code, :eval_string, [code], 60_000)
    IO.puts("=== RESULT ===")
    IO.inspect(res, limit: :infinity, printable_limit: :infinity)
  rescue
    e -> IO.puts("EVAL_ERROR: #{inspect(e)}"); System.halt(3)
  end
'
