defmodule Ezagent.Socialware.MemberBackfill do
  @moduledoc """
  D1 join 补发 —— **唯一的「入会确认后补发」共享 helper**(caller-side
  confirmed grant,todo.md「#161 A2 deferrals」推荐形态落地)。

  新成员 join 一个已挂看板的会话后,既看不到 view tab、也没有本会话已挂资源的
  钥匙(要人肉刷新/管理员代发)。本模块把三段补发归拢成一个供给点,由**全部
  加人入口**(add-site chokepoints)在 join 确认成功后调用:

    1. **participation tier** —— `Membership.mount_participation_caps/2`
       (既有 caller-side 逐类参与 cap,原样收编);
    2. **member view caps** —— `Membership.grant_member_view_caps/2`
       (session declared views 的 render cap,tag
       granter = session owner,admin/held_by 二分,#1457);
    3. **mount operate keys** —— `Mount.backfill_member_mounts/2`
       (挂载表 `:operate` 行补发 person keys;`:read` 行不扩散)。

  ②③ 只对 **CONFIRMED 用户**发(anon 的 view caps 在出生时铸
  `anon_view_caps/1`;agent 的 caps 在 spawn 时 provision,甲-3)。
  「访客/observer 是否含」的口径边界是 discuss-first 项(D3 handoff §6),
  当前取保守解:仅 confirmed。

  ## 红线(死锁实证)

  **绝不在 `handle_join` 内同步调用本模块** —— join 内 sync grant 会把
  session 创建卡死成 5s `GenServer.call` timeout(`Materializer.
  join_session_members` 实证)。唯一 deadlock-free 的 CONFIRMED grant 是
  caller-side:add-site 在 join dispatch 成功**之后**、自己的进程里调
  `backfill/2`。

  ## I12 paradigm-lock

  本模块**零** grant/mint 调用点:view caps 走 membership 既有 grant funnel,
  mount keys 走 `CompositionCaps.mint_cap` 唯一 mint chokepoint(经
  `Mount.mount/6`)。收编、不新增 grant 真相源(fix-plan X2:「第 N 个
  grant 点 = 第 N 个不同步真相源」)。

  ## 幂等 & best-effort

  三段各自幂等(已持 cap / 已有 operate 行 → skip),重复调用不重复发 ——
  add-site 可在每次导航/重join 时安全重调(自愈:approve_admission 这类
  in-Kind 补员路径无法挂 caller-side 补发,成员下次导航进会话时补齐)。
  整体永不 raise:任何一段失败只降级(无 cap ⇒ 拒读,fail-closed 安全),
  绝不 fail 一次已成功的 join。

  M-10:三段补发之前统一验证当前 tier-1 member-cap。`:members` roster、
  navigation 和旧 cursor 都不是 entitlement；tier-1 已撤销时本模块完全
  no-op，不会补回 participation/view/mount-key tier-2。
  """

  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Socialware.Mount

  require Logger

  @doc """
  入会确认后的三段补发(见 moduledoc)。永远返回 `:ok`。

  只应在 join dispatch 成功后、caller 进程里调用(红线见 moduledoc)。
  """
  @spec backfill(URI.t(), URI.t()) :: :ok
  def backfill(%URI{} = session_uri, %URI{} = member_uri) do
    if Membership.current_member_entitled?(session_uri, member_uri) do
      _ = Membership.mount_participation_caps(session_uri, member_uri)

      if Membership.user_uri?(member_uri) and Ezagent.Users.confirmed?(member_uri) do
        _ = Membership.grant_member_view_caps(session_uri, member_uri)
        _ = report_mount_backfill(session_uri, member_uri)
      end
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "MemberBackfill.backfill/2: backfill crashed for member=" <>
          "#{URI.to_string(member_uri)} on session=#{URI.to_string(session_uri)}: " <>
          "#{inspect(error.__struct__)} — join stands; member degrades to observe."
      )

      :ok
  end

  def backfill(_session_uri, _member_uri), do: :ok

  defp report_mount_backfill(session_uri, member_uri) do
    case Mount.backfill_member_mounts(session_uri, member_uri) do
      {:ok, %{failed: 0}} ->
        :ok

      {:ok, %{failed: failed} = summary} ->
        :telemetry.execute(
          [:ezagent, :socialware, :member_backfill, :mount_failed],
          %{count: failed},
          %{session_uri: session_uri, member_uri: member_uri, summary: summary}
        )

        :ok
    end
  end
end
