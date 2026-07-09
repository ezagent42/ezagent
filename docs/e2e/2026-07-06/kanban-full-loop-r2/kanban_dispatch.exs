# kanban CLI 代面(stand-in) —— 本 build 的 `mix ezagent` 子命令树只从全局
# BehaviorRegistry 派生(tree_builder.ex:23),而 kanban 动作是 per-instance recipe
# 行为(K5,application.ex:272-279 注释),不在全局注册表 → `mix ezagent agent
# add_node` 在本 build 报 unrecognized arguments。
# 按协议模块注记(kanban-team-collaboration.md §d 末尾):"the mechanism
# (identity → target URI → Router.dispatch) is the invariant"。本脚本复刻
# EzagentCli.Dispatch.run_action 同一路径(dispatch.ex:83-99 invocation 构造 +
# :307 do_dispatch),身份/caps 来自 Ezagent.Entity.authenticate(调用者自己的
# EZAGENT_USER_TOKEN/EZAGENT_ENTITY_URI)——CapBAC 不绕过。
[action, args_json] = System.argv()
token = System.get_env("EZAGENT_USER_TOKEN") || raise "EZAGENT_USER_TOKEN unset"
euri = System.get_env("EZAGENT_ENTITY_URI") || raise "EZAGENT_ENTITY_URI unset"
board = System.get_env("BOARD_URI") || "entity://system/agent/loop-board-r2"
node = :"ezagent_runtime@127.0.0.1"

code = ~S"""
{:ok, caller} = Ezagent.URI.parse(euri)

case Ezagent.Entity.authenticate(caller, token) do
  {:ok, %{caps: caps}} ->
    args =
      Jason.decode!(args_json)
      |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)

    target = Ezagent.URI.new!(board <> "?action=kanban." <> action)

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}, deadline_ms: 15_000}
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, r} ->
        {:ok, r}

      :ok ->
        receive do
          {:ezagent_reply, r} -> {:ok, r}
        after
          15_000 -> {:ok, :timeout_no_reply}
        end

      err ->
        err
    end

  {:error, e} ->
    {:auth_error, e}
end
"""

binding = [euri: euri, token: token, board: board, action: action, args_json: args_json]

case :erpc.call(node, Code, :eval_string, [code, binding], 30_000) do
  {result, _} -> IO.inspect(result, limit: 20, width: 120, printable_limit: 2000)
  other -> IO.inspect(other, label: "unexpected")
end
