# kanban CLI 代面(stand-in) —— 本 build 的 `mix ezagent` 子命令树只从全局
# BehaviorRegistry 派生(tree_builder.ex:23),而 kanban 动作是 per-instance recipe
# 行为(K5,application.ex:272-279 注释),不在全局注册表 → `mix ezagent agent
# add_node` 在本 build 报 unrecognized arguments。
# 按协议模块注记(kanban-team-collaboration.md §d 末尾):"the mechanism
# (identity → target URI → Router.dispatch) is the invariant"。本脚本复刻
# EzagentCli.Dispatch.run_action 同一路径(dispatch.ex:83-99 invocation 构造 +
# :307 do_dispatch),身份从 EZAGENT_USER_TOKEN 自解析,caps 单独读取——CapBAC 不绕过。
#
# board 解析:优先 BOARD_URI env;未设时**从调用者(助手)自持的 kanban board cap
# 动态解析**——即「我这 session 挂的板」。助手挂板时收到 instance-scoped
# `kanban.<action>` cap(kind=:agent、behavior=Ezagent.ActionSet.Kanban、
# instance=板 URI),取那些 cap 的 instance 即板 URI,无需外部塞 BOARD_URI。
# 多个不同板 → 报错让 env 显式指定(避免误操作到别的板)。
[action, args_json] = System.argv()
token = System.get_env("EZAGENT_USER_TOKEN") || raise "EZAGENT_USER_TOKEN unset"
board_env = System.get_env("BOARD_URI")
node = :"ezagent_runtime@127.0.0.1"

code = ~S"""
case Ezagent.Authentication.authenticate(token) do
  {:ok, caller} ->
    caps = caller |> Ezagent.IdentityCaps.load() |> MapSet.new()

    # board 解析:BOARD_URI env 优先;未设 → 从 caller 自持的 kanban board cap 解。
    board_result =
      case board_env do
        b when is_binary(b) and b != "" ->
          {:ok, b}

        _ ->
          instances =
            caps
            |> Enum.filter(fn c ->
              c.kind == :agent and c.behavior == Ezagent.ActionSet.Kanban and
                match?(%URI{}, c.instance)
            end)
            |> Enum.map(fn c -> URI.to_string(Ezagent.URI.instance(c.instance)) end)
            |> Enum.uniq()

          case instances do
            [only] -> {:ok, only}
            [] -> {:error, :no_kanban_board_cap}
            many -> {:error, {:multiple_boards, many}}
          end
      end

    case board_result do
      {:ok, board} ->
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

      {:error, _} = err ->
        err
    end

  {:error, e} ->
    {:auth_error, e}
end
"""

binding = [token: token, board_env: board_env, action: action, args_json: args_json]

case :erpc.call(node, Code, :eval_string, [code, binding], 30_000) do
  {result, _} -> IO.inspect(result, limit: 20, width: 120, printable_limit: 2000)
  other -> IO.inspect(other, label: "unexpected")
end
