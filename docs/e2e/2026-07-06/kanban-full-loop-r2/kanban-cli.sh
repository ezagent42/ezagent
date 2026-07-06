#!/usr/bin/env bash
# 用法: kanban-cli.sh <action> '<args-json>'
# 例:   kanban-cli.sh add_node '{"parent_id":"","title":"登录表单"}'
# 身份 = 调用者自己的 EZAGENT_USER_TOKEN / EZAGENT_ENTITY_URI(CapBAC 不绕过)
set -euo pipefail
ACTION="$1"
ARGS_JSON="${2:-}"
[ -z "$ARGS_JSON" ] && ARGS_JSON='{}'
COOKIE=$(cat /home/yaosh/.ezagent/default/runtime/cookie)
exec mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- \
  elixir --name "kanban_cli_$$@127.0.0.1" --cookie "$COOKIE" \
  /tmp/kanban-loop-r2/kanban_dispatch.exs "$ACTION" "$ARGS_JSON"
