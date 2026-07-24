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

  ## person-scope(㊵ 人本位前置,自有过渡 infra)

  除会话挂载外,支持「人持钥匙」行:`mount_for_person/5` 不带 session 参数,落
  `scope=person` 的挂载行(自然键 `(target, grantee, behavior)`,session 轴为 NULL),
  钥匙机制与会话挂载完全同款(mint_cap 唯一 chokepoint,grantee 本就支持任意 URI ——
  零 cap 机制改动)。**reconcile 归属**:`reconcile_session_mounts/1` 只扫 session 行
  (person 行不挂在任何 session 的 activate 上);person 行由 `reconcile_person_mounts/1`
  按 grantee 重发,供人侧 identity slice 重建/修复路调用。将来 mount 折
  CompositionBinding 时 scope 维度随行平移。
  """

  alias Ezagent.Socialware.{CompositionCaps, MountRow}

  require Logger

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
  人本位挂载:同 `mount/6` 的 mint+落表,但**无 session 轴** —— 给 `grantee_uri`
  (通常是人)铸指向 `target_uri` 的钥匙,落 `scope=person` 的挂载行。

  钥匙由 `actions` 决定、`opts[:access]` 只记表(同 `mount/6`);`granted_by` 恒 =
  target 的 data_owner(#154)。mint 失败 → 不落表。同 person 自然键再 mount →
  覆盖,仍 1 行。
  """
  @spec mount_for_person(URI.t(), URI.t(), module(), [atom()], keyword()) ::
          {:ok, mount_result()} | {:error, term()}
  def mount_for_person(%URI{} = target_uri, %URI{} = grantee_uri, behavior, actions, opts \\ [])
      when is_atom(behavior) and is_list(actions) and is_list(opts) do
    access = Keyword.get(opts, :access, :operate)

    with {:ok, caps} <- CompositionCaps.mint_cap(grantee_uri, target_uri, behavior, actions) do
      attrs = %{
        scope: :person,
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
  人本位卸载:撤销 person 行记录的每把 action 钥匙(granter 权 = 行的 `granted_by`),
  再删行。行不存在 → `{:ok, :unmounted}`(幂等)。删宿主(如删板)撤钥匙路必须连
  person 行一起扫 —— person cap 不许悬空(⑲ SoT 约束)。
  """
  @spec unmount_for_person(URI.t(), URI.t(), module()) :: {:ok, :unmounted} | {:error, term()}
  def unmount_for_person(%URI{} = target_uri, %URI{} = grantee_uri, behavior)
      when is_atom(behavior) do
    case MountRow.get_person(target_uri, grantee_uri, behavior) do
      nil ->
        {:ok, :unmounted}

      %MountRow{} = row ->
        with :ok <- revoke_row_actions(row, target_uri, grantee_uri, behavior) do
          {:ok, _} = MountRow.delete_person_by_natural_key(target_uri, grantee_uri, behavior)
          {:ok, :unmounted}
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
             # 冷建 agent(spawn + recipe 物化 + CapMint + snapshot)实测可 >5s;默认
             # GenServer call 5s 会在建到一半时超时崩掉整条 with 链 → 孤儿宿主(agent
             # 建成、零钥匙零挂载行)。显式给足 deadline(Provisioning.create_agent
             # 透传进 dispatch ctx)。
             Map.put(owner_ctx, :deadline_ms, 30_000)
           ),
         actions = Map.get(spec, :actions) || Ezagent.ActionSet.action_names(behavior),
         {:ok, %{caps: caps, mount: mount}} <-
           mount(session_uri, target_uri, grantee_uri, behavior, actions, access: :operate) do
      {:ok, %{target: target_uri, caps: caps, mount: mount}}
    end
  end

  @doc """
  重发 `session_uri` 名下所有挂载的钥匙 —— session 重启后的存活底座。

  一个 mount 的钥匙落在 grantee 的 self-store cap slice;session 重启时该 slice 重建、
  钥匙不会自动重发,但挂载表(`MountRow`,durable SoT)仍在。本函数读回
  `MountRow.list_for_session/1` 的每条挂载行,对每条重跑 `mount/6`(= mint_cap 复用现成
  issue+absorb chokepoint + upsert),使钥匙重现。

  **幂等**:mint 走 composition 现成 issue+absorb chokepoint(重跑覆盖),`upsert` 在自然键
  冲突时原地覆盖 —— 连跑两次挂载表仍 N 行、钥匙仍在。

  **best-effort per row**:单条重发失败(如宿主已被删/无属主)只记 `:warning`、计入 `failed`,
  不牵连其余行(与 `Session.Reconcile.reconcile_after_load/2` 的 fail-safe 姿态一致)。整体
  永不 raise —— 挂在 `activate/2` 上时不能崩 Kind 重启。返回
  `{:ok, %{reconciled: n, failed: m}}`。
  """
  @spec reconcile_session_mounts(URI.t()) ::
          {:ok, %{reconciled: non_neg_integer(), failed: non_neg_integer()}}
  def reconcile_session_mounts(%URI{} = session_uri) do
    session_uri
    |> MountRow.list_for_session()
    |> Enum.reduce(%{reconciled: 0, failed: 0}, fn %MountRow{} = row, acc ->
      case remint_row(session_uri, row) do
        {:ok, _} ->
          %{acc | reconciled: acc.reconciled + 1}

        {:error, reason} ->
          Logger.warning(
            "Mount.reconcile_session_mounts/1: re-mint FAILED for target=" <>
              "#{row.target_uri} grantee=#{row.grantee_uri} behavior=#{row.behavior}: " <>
              "#{inspect(reason)} — skipping (other mounts unaffected)."
          )

          %{acc | failed: acc.failed + 1}
      end
    end)
    |> then(&{:ok, &1})
  rescue
    error ->
      Logger.warning(
        "Mount.reconcile_session_mounts/1: mount scan failed for " <>
          "#{URI.to_string(session_uri)}: #{inspect(error.__struct__)} — treated as no-op."
      )

      {:ok, %{reconciled: 0, failed: 0}}
  end

  @doc """
  重发 `grantee_uri`(人)名下所有 person-scope 挂载的钥匙 —— person 行的 reconcile 路。

  person 行不属于任何 session,不挂在 session activate 上;本函数按 grantee 扫
  `MountRow.list_person_mounts_for_grantee/1` 逐行重跑 `mount_for_person/5`(幂等,
  同 `reconcile_session_mounts/1` 的 best-effort per row 姿态,永不 raise)。
  """
  @spec reconcile_person_mounts(URI.t()) ::
          {:ok, %{reconciled: non_neg_integer(), failed: non_neg_integer()}}
  def reconcile_person_mounts(%URI{} = grantee_uri) do
    grantee_uri
    |> MountRow.list_person_mounts_for_grantee()
    |> Enum.reduce(%{reconciled: 0, failed: 0}, fn %MountRow{} = row, acc ->
      case remint_person_row(grantee_uri, row) do
        {:ok, _} ->
          %{acc | reconciled: acc.reconciled + 1}

        {:error, reason} ->
          Logger.warning(
            "Mount.reconcile_person_mounts/1: re-mint FAILED for target=" <>
              "#{row.target_uri} grantee=#{row.grantee_uri} behavior=#{row.behavior}: " <>
              "#{inspect(reason)} — skipping (other mounts unaffected)."
          )

          %{acc | failed: acc.failed + 1}
      end
    end)
    |> then(&{:ok, &1})
  rescue
    error ->
      Logger.warning(
        "Mount.reconcile_person_mounts/1: mount scan failed for " <>
          "#{URI.to_string(grantee_uri)}: #{inspect(error.__struct__)} — treated as no-op."
      )

      {:ok, %{reconciled: 0, failed: 0}}
  end

  @doc """
  D1 join 补发(mount 半边):把 `session_uri` 挂载表里已有的 **`:operate`** 行
  的钥匙,补发给新成员 `member_uri`(为其新建同 target×behavior 的 operate
  挂载行 + person keys)。

  数据源 = `MountRow.list_for_session/1`;铸钥仍走 `mount/6`(= `mint_cap`
  唯一 mint chokepoint + `upsert` 落表)—— 本函数只是驱动点,不是新铸造口。

    * **`:read` 行不扩散**:只读挂载(如链接分享的只读钥匙)不因入会升格,
      过滤后根本不进补发集。
    * **幂等**:member 已持有某 target×behavior 的 operate 行 → skip(重复调用
      不重复发);member 既有 read 行会被升格为 operate(协作模型:编辑权来自
      会话成员身份)。
    * **best-effort per row**:单行失败(如宿主已删/无属主 → mint fail-closed
      不落表,天然无需补偿)只记 warning 计入 `failed`,不牵连其余行。

  返回 `{:ok, %{backfilled: n, skipped: k, failed: m}}`,永不 raise。
  """
  @spec backfill_member_mounts(URI.t(), URI.t()) ::
          {:ok,
           %{backfilled: non_neg_integer(), skipped: non_neg_integer(), failed: non_neg_integer()}}
  def backfill_member_mounts(%URI{} = session_uri, %URI{} = member_uri) do
    member_key = grantee_key(member_uri)
    rows = MountRow.list_for_session(session_uri)

    held_operate =
      rows
      |> Enum.filter(fn %MountRow{} = row ->
        row_grantee_key(row) == member_key and decode_access(row.access) == :operate
      end)
      |> MapSet.new(fn row -> {row.target_uri, row.behavior} end)

    rows
    |> Enum.filter(fn %MountRow{} = row ->
      decode_access(row.access) == :operate and row_grantee_key(row) != member_key
    end)
    |> Enum.group_by(fn row -> {row.target_uri, row.behavior} end)
    |> Enum.reduce(%{backfilled: 0, skipped: 0, failed: 0}, fn {{target_s, behavior_s}, group},
                                                               acc ->
      if MapSet.member?(held_operate, {target_s, behavior_s}) do
        %{acc | skipped: acc.skipped + 1}
      else
        actions = group |> Enum.flat_map(&recorded_actions/1) |> Enum.uniq()

        case mount(
               session_uri,
               Ezagent.URI.new!(target_s),
               member_uri,
               decode_behavior(behavior_s),
               actions,
               access: :operate
             ) do
          {:ok, _} ->
            %{acc | backfilled: acc.backfilled + 1}

          {:error, reason} ->
            Logger.warning(
              "Mount.backfill_member_mounts/2: backfill FAILED for target=" <>
                "#{target_s} member=#{URI.to_string(member_uri)} behavior=" <>
                "#{behavior_s}: #{inspect(reason)} — skipping (other mounts unaffected)."
            )

            %{acc | failed: acc.failed + 1}
        end
      end
    end)
    |> then(&{:ok, &1})
  rescue
    error ->
      Logger.warning(
        "Mount.backfill_member_mounts/2: mount scan failed for " <>
          "#{URI.to_string(session_uri)}: #{inspect(error.__struct__)} — treated as no-op."
      )

      {:ok, %{backfilled: 0, skipped: 0, failed: 0}}
  end

  # 挂载行 grantee 的稳定比较键(行存字符串 URI,统一转 instance stable_key)。
  defp row_grantee_key(%MountRow{grantee_uri: grantee}) when is_binary(grantee),
    do: grantee_key(Ezagent.URI.new!(grantee))

  defp grantee_key(%URI{} = uri), do: Ezagent.URI.stable_key(Ezagent.URI.instance(uri))

  # 从挂载行还原参数并重跑 mount/6。行里存的是字符串(URI/behavior/actions_json/access),
  # 逐一反序列化回 mount/6 需要的类型。
  defp remint_row(session_uri, %MountRow{} = row) do
    target = Ezagent.URI.new!(row.target_uri)
    grantee = Ezagent.URI.new!(row.grantee_uri)
    behavior = decode_behavior(row.behavior)
    actions = recorded_actions(row)
    access = decode_access(row.access)

    mount(session_uri, target, grantee, behavior, actions, access: access)
  end

  # person 行版 remint:无 session 轴,重跑 mount_for_person/5。
  defp remint_person_row(grantee_uri, %MountRow{} = row) do
    target = Ezagent.URI.new!(row.target_uri)
    behavior = decode_behavior(row.behavior)
    actions = recorded_actions(row)
    access = decode_access(row.access)

    mount_for_person(target, grantee_uri, behavior, actions, access: access)
  end

  # behavior 存的是 `inspect(module)` —— 无 `Elixir.` 前缀(如
  # `"Ezagent.ActionSet.Kanban"`)。`Module.concat/1` 是其自然逆运算,自动补回前缀。
  # (`String.to_existing_atom/1` 不加前缀会 raise,故不用;实测确认 `Module.concat`
  # 转得回 module atom。)
  defp decode_behavior(behavior) when is_binary(behavior), do: Module.concat([behavior])

  # access 存的是字符串("read" / "operate")—— 两者对应 atom 均已存在。
  defp decode_access(access) when is_binary(access), do: String.to_existing_atom(access)
  defp decode_access(_), do: :operate

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
      nil -> :ok
      %MountRow{} = row -> revoke_row_actions(row, target_uri, grantee_uri, behavior)
    end
  end

  # 撤销一条挂载行(session / person 同款)记录的每把 action 钥匙。
  defp revoke_row_actions(%MountRow{} = row, target_uri, grantee_uri, behavior) do
    granter = Ezagent.URI.new!(row.granted_by)
    workspace_uri = Ezagent.Capability.workspace_of(target_uri)
    target_instance = Ezagent.URI.instance(target_uri)

    row
    |> recorded_actions()
    |> Enum.reduce_while(:ok, fn action, :ok ->
      cap =
        Ezagent.Capability.cap(:agent, behavior, action, target_instance, workspace_uri)

      # 撤销走 `{:held_by, granter}` 授权(#1457 后 rule 元组已删;与 composition
      # reconcile 同款):granter(行的 granted_by = 宿主主人)是问责 issuer,
      # revoke 不重跑 grant 授权、保留已签 artifact 原样撤储。
      case Ezagent.Identity.Grant.revoke_cap(
             grantee_uri,
             cap,
             {:held_by, granter}
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mount_revoke_failed, action, reason}}}
      end
    end)
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
