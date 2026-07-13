defmodule Ezagent.Socialware.BoardProvision do
  @moduledoc """
  运行时"建板"入口 —— 会话内动态建出一块数据宿主 agent(如 kanban board),归属 =
  触发建板的 owner,并当场给**本 session 的 assistant 成员**发一把指向新宿主的操作钥匙。

  这是 T4a 的落地:把两步组合成一个运行时入口(装 socialware ≠ 自动生板;建板→当场发钥匙)。

    1. **建板**(归属 = 触发者):`Ezagent.Workspace.create_agent/3`,`ctx` = `owner_ctx`。
       新 agent 的 `data_owner`(经 `AgentLineage.record(agent, caller)`,#154)= owner_ctx 的
       caller —— 也就是这块板的主人。**建板是 cap-gated 的**(`{:workspace, create_agent}`),
       所以 owner_ctx 的 caller 必须持建 agent 的权(session owner / admin)。assistant 自己
       通常无此权,故由 owner 建、再 mint 给 assistant。
    2. **发钥匙**:`Ezagent.Socialware.CompositionCaps.mint_cap/4` —— granter 永远 = 新板的
       `data_owner`(板主人授权,mint_cap 内部处理)。`actions` 默认为 `behavior` 的全部动作
       (`Ezagent.ActionSet.action_names/1`),给本 session 里 `role_name == assistant_role`
       的成员铸指向该新板的**实例精确**操作 cap。

  纯业务组合、0 行 core:复用现成的 `Workspace.create_agent`(建)+ `CompositionCaps.mint_cap`
  (发钥匙,唯一 mint chokepoint)。`behavior` 由调用方传入(如 `Ezagent.ActionSet.Kanban`),
  本模块不静态依赖任何 plugin —— domain_session 是唯一同时能合法调到"建"(依赖 domain_workspace)
  和"发钥匙"(自有 CompositionCaps)的层。

  ## 参数

    * `workspace_uri` —— 新板所属 workspace。
    * `session_uri` —— 触发建板的 session;assistant 从它的成员边解析。
    * `spec` —— `%{name, board_role, flavor, assistant_role, actions}`:
      `:name`(必填,新板实例名)、`:board_role`(必填,建板 recipe 名,如 `"kanban-manager"`)、
      `:flavor`(必填,如 `"native"`)、`:assistant_role`(必填,收钥匙的成员 role_name,如
      `"kanban-assistant"`)、`:actions`(选填,默认 `action_names(behavior)`)。
    * `behavior` —— 操作 cap 的 ActionSet 模块(如 `Ezagent.ActionSet.Kanban`)。
    * `owner_ctx` —— `%{caller, caps}`:建板者(= 板主人),须持 `create_agent` 权。

  返回 `{:ok, %{board_uri, assistant_uri, minted}}` 或 `{:error, reason}`。建板失败或 assistant
  解析不出(本 session 无该 role 成员)则不发钥匙、整体失败(fail-closed)。
  """

  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Socialware.CompositionCaps

  @type result :: %{
          board_uri: URI.t(),
          assistant_uri: URI.t(),
          minted: [Ezagent.Capability.t()]
        }

  @doc """
  建板(归属 = `owner_ctx` 的 caller)+ 当场给本 session 的 `assistant_role` 成员 mint 指向
  新板的 `behavior` 操作钥匙。见模块文档的参数/返回契约。
  """
  @spec create_board(URI.t(), URI.t(), map(), module(), map()) ::
          {:ok, result()} | {:error, term()}
  def create_board(%URI{} = workspace_uri, %URI{} = session_uri, spec, behavior, owner_ctx)
      when is_map(spec) and is_atom(behavior) and is_map(owner_ctx) do
    with {:ok, name} <- fetch(spec, :name),
         {:ok, board_role} <- fetch(spec, :board_role),
         {:ok, flavor} <- fetch(spec, :flavor),
         {:ok, assistant_role} <- fetch(spec, :assistant_role),
         actions = Map.get(spec, :actions) || Ezagent.ActionSet.action_names(behavior),
         {:ok, %{agent_uri: board_uri}} <-
           Ezagent.Workspace.create_agent(
             workspace_uri,
             %{flavor: flavor, name: name, role: board_role, cwd: "", with_pty: false},
             owner_ctx
           ),
         {:ok, assistant_uri} <- resolve_assistant(session_uri, assistant_role),
         {:ok, minted} <- CompositionCaps.mint_cap(assistant_uri, board_uri, behavior, actions) do
      {:ok, %{board_uri: board_uri, assistant_uri: assistant_uri, minted: minted}}
    end
  end

  # 本 session 的成员边(与 CompositionCaps.read_role_members 同源:`:session` 状态切片的
  # `:members` map),`role_name == assistant_role` 的成员即收钥匙人。
  defp resolve_assistant(session_uri, assistant_role) do
    members =
      case Ezagent.Kind.get_slice(session_uri, :session) do
        {:ok, slice} when is_map(slice) -> Map.get(slice, :members, %{})
        _ -> %{}
      end

    case Members.role_name_to_uri(members, assistant_role) do
      %URI{} = uri -> {:ok, uri}
      _ -> {:error, {:board_assistant_unresolved, session_uri, assistant_role}}
    end
  end

  defp fetch(spec, key) do
    case Map.get(spec, key) do
      nil -> {:error, {:board_spec_missing, key}}
      "" -> {:error, {:board_spec_missing, key}}
      v -> {:ok, v}
    end
  end
end
