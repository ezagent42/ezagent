defmodule Ezagent.Socialware.Mount do
  @moduledoc """
  通用「把一个数据宿主 agent 挂载进 session」的生命周期 API —— 所有 socialware 复用。

  一个 mount = 现成的两块拼装:
    1. **发钥匙**:`Ezagent.Socialware.CompositionCaps.mint_cap/4`(唯一 mint chokepoint)
       给 grantee 铸一批指向 target(数据宿主)的实例精确 cap,granter 永远 = target 的
       data_owner(板主人授权,#154)。
    2. **落表**:`Ezagent.Socialware.MountRow`(runtime mount 的 SoT)记一行
       `(session, target, grantee, behavior)`——谁对哪个宿主持哪组动作、什么 access。

  **零 kanban 字面**:behavior / role / actions / access 全由调用方参数化。拉板传全动作
  (`access: :operate`)、转发只读传读动作(`access: :read`),同一条 `mount/6` 路。

  这一层(`ezagent_domain_session`)是唯一同时能合法调到「建宿主」(依赖
  `ezagent_domain_workspace` 的 `Ezagent.Workspace.create_agent`)和「发钥匙」(自有
  `CompositionCaps`)的层,故 `provision/6`(建 + 当场挂)落在这里。本模块不静态依赖任何
  plugin —— `behavior` 是参数。
  """

  alias Ezagent.Socialware.{CompositionCaps, MountRow}

  @type mount_result :: %{caps: [Ezagent.Capability.t()], mount: MountRow.t()}
  @type provision_result :: %{
          target: URI.t(),
          caps: [Ezagent.Capability.t()],
          mount: MountRow.t()
        }

  @doc """
  挂载:给 `grantee_uri` 铸指向 `target_uri`(数据宿主)的 `behavior`×`actions` 钥匙,
  并把这次挂载落进 `MountRow`。

    * `actions` 决定发什么钥匙(读动作 → 只读钥匙、增删改 → 操作钥匙),同一条 mint 路。
    * `opts[:access]`(`:read` | `:operate`,默认 `:operate`)只记进挂载表,供 reconcile /
      审计区分「能看」还是「能改」;它 **不** 改变实际发的钥匙(钥匙由 `actions` 决定)。
    * 挂载行的 `granted_by` = target 的 data_owner(取自 mint 出的 cap.granted_by),
      `workspace_uri` = `Ezagent.Capability.workspace_of(target_uri)`。

  mint 失败(如宿主无属主 fail-closed)→ **不落表**,原样返回 `{:error, _}`。
  同自然键再 mount → `MountRow.upsert/1` 在自然键冲突时覆盖,挂载表仍 1 行。
  """
  @spec mount(URI.t(), URI.t(), URI.t(), module(), [atom()], keyword()) ::
          {:ok, mount_result()} | {:error, term()}
  def mount(
        %URI{} = session_uri,
        %URI{} = target_uri,
        %URI{} = grantee_uri,
        behavior,
        actions,
        opts \\ []
      )
      when is_atom(behavior) and is_list(actions) and is_list(opts) do
    access = Keyword.get(opts, :access, :operate)

    with {:ok, caps} <- CompositionCaps.mint_cap(grantee_uri, target_uri, behavior, actions) do
      attrs = %{
        session_uri: session_uri,
        target_uri: target_uri,
        grantee_uri: grantee_uri,
        behavior: behavior,
        actions: actions,
        access: access,
        granted_by: granted_by(caps, behavior, target_uri),
        workspace_uri: Ezagent.Capability.workspace_of(target_uri)
      }

      case MountRow.upsert(attrs) do
        {:ok, %MountRow{} = row} -> {:ok, %{caps: caps, mount: row}}
        {:error, reason} -> {:error, {:mount_row_upsert_failed, reason}}
      end
    end
  end

  @doc """
  卸载:撤销 `grantee_uri` 指向 `target_uri` 的 `behavior` 钥匙(对挂载行记录的**每个
  action** 逐一 `Ezagent.Identity.Grant.revoke_cap`,granter 权 = 挂载行的 `granted_by`),
  再删挂载行。

  钥匙的 `actions` 从挂载行读回(`unmount/4` 不带 actions 参数),故必须先有行才知道撤哪些。
  未挂载的自然键(行不存在)→ 无钥匙可撤,直接返回 `{:ok, :unmounted}`(幂等)。
  """
  @spec unmount(URI.t(), URI.t(), URI.t(), module()) :: {:ok, :unmounted} | {:error, term()}
  def unmount(%URI{} = session_uri, %URI{} = target_uri, %URI{} = grantee_uri, behavior)
      when is_atom(behavior) do
    with :ok <- revoke_recorded_actions(session_uri, target_uri, grantee_uri, behavior) do
      {:ok, _} = MountRow.delete_by_natural_key(session_uri, target_uri, grantee_uri, behavior)
      {:ok, :unmounted}
    end
  end

  @doc """
  建宿主 + 当场挂:`Ezagent.Workspace.create_agent/3` 建出数据宿主 agent(cap-gated,
  记 `AgentLineage` data_owner = `owner_ctx` 的 caller,#154),再对新宿主 `mount/6`
  给 `grantee_uri` 当场发操作钥匙(`access: :operate`)。

  这是 `BoardProvision.create_board/5` 的泛化 —— role / flavor / name / behavior 全从
  `spec` / 参数来,零 kanban 字面。

    * `spec` —— `%{name, flavor, role, ...}`:`:name`(新宿主实例名)、`:flavor`(direct-spawn
      flavor,如 `"native"`)、`:role`(建宿主的 recipe 名,其 behaviors 决定新宿主挂什么
      ActionSet)。可选 `:actions`(默认 `Ezagent.ActionSet.action_names(behavior)`)。
    * `owner_ctx` —— `%{caller, caps}`:建宿主者(= 宿主主人),须持 `create_agent` 权。

  建宿主失败或挂载失败 → 整体 `{:error, _}`(fail-closed)。
  """
  @spec provision(URI.t(), URI.t(), map(), URI.t(), module(), map()) ::
          {:ok, provision_result()} | {:error, term()}
  def provision(
        %URI{} = session_uri,
        %URI{scheme: "workspace"} = workspace_uri,
        spec,
        %URI{} = grantee_uri,
        behavior,
        owner_ctx
      )
      when is_map(spec) and is_atom(behavior) and is_map(owner_ctx) do
    with {:ok, name} <- fetch(spec, :name),
         {:ok, flavor} <- fetch(spec, :flavor),
         {:ok, %{agent_uri: target_uri}} <-
           Ezagent.Workspace.create_agent(
             workspace_uri,
             create_args(spec, name, flavor),
             owner_ctx
           ),
         actions = Map.get(spec, :actions) || Ezagent.ActionSet.action_names(behavior),
         {:ok, %{caps: caps, mount: mount}} <-
           mount(session_uri, target_uri, grantee_uri, behavior, actions, access: :operate) do
      {:ok, %{target: target_uri, caps: caps, mount: mount}}
    end
  end

  # ── internals ───────────────────────────────────────────────────────────

  # granter 权 = 挂载行落的 granted_by(= target 的 data_owner)。mint 出的每个 artifact
  # 都带 `granted_by`(板主人),直接取其字段;万一 actions 为空(无 artifact)或该字段缺失,
  # 回落 `data_owner_of`。
  # 注:头部匹配空 `%Capability{}` 再字段访问,刻意不在结构体模式里写 `granted_by:` ——
  # CapIssueChokepoint gate(#1379/I7)按 `%…Capability{granted_by: …}` AST 计 provenance
  # 构造,解构模式会被误计,故用字段访问避开(本函数是读 mint 结果,非构造 cap)。
  defp granted_by([%Ezagent.Capability{} = cap | _], behavior, target_uri) do
    case cap.granted_by do
      %URI{} = owner -> owner
      _ -> data_owner_fallback(behavior, target_uri)
    end
  end

  defp granted_by(_caps, behavior, target_uri), do: data_owner_fallback(behavior, target_uri)

  defp data_owner_fallback(behavior, target_uri) do
    case Ezagent.CapabilityRegistry.data_owner_of(behavior, Ezagent.URI.instance(target_uri)) do
      %URI{} = owner -> owner
      _ -> nil
    end
  end

  # 读回挂载行的 actions,对每个 action 重建同一把 cap 并撤销(granter 权 = 行的 granted_by)。
  # 行不存在 → 无钥匙可撤,:ok(幂等)。
  defp revoke_recorded_actions(session_uri, target_uri, grantee_uri, behavior) do
    case MountRow.get(session_uri, target_uri, grantee_uri, behavior) do
      nil ->
        :ok

      %MountRow{} = row ->
        granter = Ezagent.URI.new!(row.granted_by)
        workspace_uri = Ezagent.Capability.workspace_of(target_uri)
        target_instance = Ezagent.URI.instance(target_uri)

        row
        |> recorded_actions()
        |> Enum.reduce_while(:ok, fn action, :ok ->
          cap =
            Ezagent.Capability.cap(:agent, behavior, action, target_instance, workspace_uri)

          # 撤销走 `{:rule, …}` 授权(与 composition reconcile 同款):revoke 在
          # `Kind.Runtime` step-5.5 由 rule bypass 授权(identity.ex §3.3),granter
          # (行的 granted_by = 宿主主人)是问责 issuer,不需 granter 自持撤销权。
          case Ezagent.Identity.Grant.revoke_cap(
                 grantee_uri,
                 cap,
                 {:rule, :socialware_mount_unmount, granter}
               ) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:mount_revoke_failed, action, reason}}}
          end
        end)
    end
  end

  defp recorded_actions(%MountRow{actions_json: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> Enum.map(list, &String.to_existing_atom/1)
      _ -> []
    end
  end

  defp recorded_actions(_row), do: []

  defp create_args(spec, name, flavor) do
    %{
      flavor: flavor,
      name: name,
      role: Map.get(spec, :role, ""),
      cwd: Map.get(spec, :cwd, ""),
      with_pty: Map.get(spec, :with_pty, false)
    }
  end

  defp fetch(spec, key) do
    case Map.get(spec, key) do
      nil -> {:error, {:mount_spec_missing, key}}
      "" -> {:error, {:mount_spec_missing, key}}
      value -> {:ok, value}
    end
  end
end
