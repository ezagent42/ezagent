defmodule Ezagent.Socialware.MemberBackfill do
  @moduledoc """
  D1 join 补发 —— **唯一的「入会确认后补发」共享 helper**(caller-side
  confirmed grant)。

  新成员 join 一个会话后,需要补发两段权限,由**全部加人入口**
  (add-site chokepoints)在 join 确认成功后调用:

    1. **participation tier** —— `Membership.mount_participation_caps/2`
       (既有 caller-side 逐类参与 cap,原样收编);
    2. **member view caps** —— `Membership.grant_member_view_caps/2`
       (session declared views 的 render cap,tag
       granter = session owner,admin/held_by 二分,#1457)。

  两段只对 **CONFIRMED 用户**发(anon 的 view caps 在出生时铸
  `anon_view_caps/1`)。

  > **注**:入会**不再**补发数据宿主(如看板)的 operate 钥匙 —— 板跟人走,
  > 编辑权只来自 owner 本人或被分享,不来自"是这个会话的成员"。旧 D1
  > mount-operate 补发(session 轴)已随该业务规则一并移除。

  ## 红线(死锁实证)

  **绝不在 `handle_join` 内同步调用本模块** —— join 内 sync grant 会把
  session 创建卡死成 5s `GenServer.call` timeout(`Materializer.
  join_session_members` 实证)。唯一 deadlock-free 的 CONFIRMED grant 是
  caller-side:add-site 在 join dispatch 成功**之后**、自己的进程里调
  `backfill/2`。

  ## 幂等 & best-effort

  两段各自幂等(已持 cap → skip),重复调用不重复发 —— add-site 可在每次
  导航/重 join 时安全重调。整体永不 raise:任何一段失败只降级(无 cap ⇒
  拒读,fail-closed 安全),绝不 fail 一次已成功的 join。

  M-10:两段补发之前统一验证当前 tier-1 member-cap。tier-1 已撤销时本
  模块完全 no-op,不会补回 participation/view tier-2。
  """

  alias Ezagent.ActionSet.Session.Membership

  require Logger

  @doc """
  入会确认后的两段补发(见 moduledoc)。永远返回 `:ok`。

  只应在 join dispatch 成功后、caller 进程里调用(红线见 moduledoc)。
  """
  @spec backfill(URI.t(), URI.t()) :: :ok
  def backfill(%URI{} = session_uri, %URI{} = member_uri) do
    if Membership.current_member_entitled?(session_uri, member_uri) do
      _ = Membership.mount_participation_caps(session_uri, member_uri)

      if Membership.user_uri?(member_uri) and Ezagent.Users.confirmed?(member_uri) do
        _ = Membership.grant_member_view_caps(session_uri, member_uri)
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
end
