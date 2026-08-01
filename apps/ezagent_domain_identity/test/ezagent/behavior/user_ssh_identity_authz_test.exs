defmodule Ezagent.ActionSet.UserSshIdentityAuthzTest do
  @moduledoc """
  1a 的授权面：四个 action 都必须落在 User Kind 的 cap 门后，每个 action 的
  required cap 都显式钉在 `kind: :user` 上，公钥读与私钥读是两条**不同**的
  cap（最小权限）——且这套授权面必须是**生产 wiring** 在起作用，不是测试
  自己搭的替身在起作用。

  ## 两处比 brief 草稿更严格的地方（round-3 review 补的验收要求）

  1. **production 注册**：`Ezagent.Entity.User.behaviors/0` 只是一份字面量
     模块列表，跟 `EzagentDomainIdentity.Application.register_identity_behaviors/0`
     里实际执行的 `CapabilityRegistry.register(User, action, UserSshIdentity)`
     完全脱钩——删掉那行注册，`behaviors/0` 原样返回，任何只断言
     `UserSshIdentity in User.behaviors()` 的测试都不会变红。既有的 cold-load
     测试（`user_ssh_identity_lifecycle_cold_load_test.exs`）同样不覆盖这条：
     它在自己的 `setup` 里把 `UserSshIdentity` 手工注册到一个自建的合成
     host Kind 上，从未经过 `application.ex` 的真实注册路径。下面
     "production CapabilityRegistry wiring" 与 "真实 dispatch 打到生产
     Ezagent.Entity.User Kind" 两组分别从注册表直读、以及真实 dispatch 两个
     角度补上这条证据。
  2. **`kind: :user` 轴**：`required_caps/0` 是手写的、整体覆盖式的实现——
     不是按 key 跟 Lifecycle 宏的自动派生合并；宏的自动派生把 `kind` 硬编码
     成 `:any`。所以如果以后有人加第五个 action、忘了把它加进这份手写
     map，`kind: :user` 这条结构性钉子会在那个 action 上悄悄消失、回落到
     `:any`——而这个仓库没有任何 CI gate 会为 domain 层 Behavior 抓到这个
     （plugin 编译器有 key-parity 检查，`ezagent_domain_identity` 没装）。
     下面「声明正确性」分组里的第二个测试是唯一会抓到它的东西。

  ## 不测什么（有意识的取舍，抄 brief 原文）

  不在这里重测"无 cap 的 dispatch 被 step-5.5 拒"这条框架级机制本身——
  CapBAC 的中央测试已经覆盖它，对每个 ActionSet 重测一遍是重复劳动。但既然
  "真实 dispatch 打到生产 Kind" 这组测试是为了坐实第 1 点证据而存在的，它
  顺带就把 spec §8 列的两条授权用例（无 cap 被拒 / 公钥读 cap 不能越权到
  私钥读）用真实 dispatch 走了一遍——这是证据链的副产品，不是额外重复
  劳动。
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_invocation!: 2, signed_required_cap!: 5]

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.CapabilityRegistry
  alias Ezagent.Entity.User
  alias Ezagent.Invocation

  @denial_reasons [:missing_cap, :unauthorized]

  describe "声明正确性" do
    test "四个 action 全部声明在 actions/0 上" do
      assert Enum.sort(UserSshIdentity.actions()) == [
               :generate_ssh_key,
               :read_ssh_key,
               :read_ssh_public_key,
               :revoke_ssh_key
             ]
    end

    test "每个 action 的 required cap 都显式钉在 kind: :user 上，且互不相同" do
      caps = UserSshIdentity.required_caps()

      for action <- UserSshIdentity.actions() do
        cap =
          case Map.fetch(caps, action) do
            {:ok, cap} ->
              cap

            :error ->
              flunk(
                "#{action} 必须在 required_caps/0 中声明一条 cap —— 缺失时这个 action " <>
                  "会在派发时落回 Lifecycle 宏的自动派生形状（kind: :any），悄悄丢失 " <>
                  "「归 User、不归 Agent」这条结构性不变式"
              )
          end

        assert cap.kind == :user,
               "#{action} 的 required cap 必须显式钉在 kind: :user（当前是 " <>
                 "#{inspect(cap.kind)}）—— 见 user_ssh_identity.ex required_caps/0 " <>
                 "上方注释：kind: :any 会在派发时被目标 Kind 的 type_name/0 替换"
      end

      # 公钥读与私钥读必须是两条不同的 cap —— 持前者不得能做后者（最小权限）。
      # 注意：单看这一条不足以单独证明 kind 轴被钉住——两者的 action 字段
      # 本来就不同，即使 kind 都退化成 :any，这条比较也会碰巧成立；kind 轴
      # 由上面的循环单独断言。
      refute caps[:read_ssh_public_key] == caps[:read_ssh_key]
    end

    test "已注册到 User Kind 的 behaviors/0（声明层——不证明 CapabilityRegistry wiring，见下）" do
      assert UserSshIdentity in User.behaviors()
    end
  end

  describe "production CapabilityRegistry wiring" do
    test "四个 action 在真实 CapabilityRegistry 上都把 Ezagent.Entity.User wiring 到 UserSshIdentity" do
      for action <- UserSshIdentity.actions() do
        assert {:ok, %{behavior: UserSshIdentity}} =
                 CapabilityRegistry.lookup_subject(User, action),
               "#{inspect(User)} 的 #{action} 未在 CapabilityRegistry 上 wiring 到 " <>
                 "#{inspect(UserSshIdentity)} —— 检查 " <>
                 "EzagentDomainIdentity.Application.register_identity_behaviors/0 是否还在 " <>
                 "为 UserSshIdentity.actions() 循环调用 " <>
                 "CapabilityRegistry.register(User, action, UserSshIdentity)"
      end
    end
  end

  describe "真实 dispatch 打到生产 Ezagent.Entity.User Kind（不是合成 host）" do
    setup do
      suffix = System.unique_integer([:positive])
      uri = Ezagent.URI.entity(:ssh_authz, :user, "u-#{suffix}")

      {:ok, _user} = Ezagent.Users.create(uri, nil, [])
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

      on_exit(fn -> Ezagent.Kind.terminate(uri) end)

      %{uri: uri, admin: User.admin_uri()}
    end

    defp target(uri, action), do: Ezagent.URI.with_action(uri, :user_ssh_identity, action)

    defp dispatch(target, args, caps, caller) do
      %Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: args,
        ctx: %{caller: caller, caps: MapSet.new(caps), reply: {:caller_inbox, self()}}
      }
      |> signed_invocation!(:user)
      |> Invocation.dispatch()
    end

    test "持正确 cap 的 revoke_ssh_key 真实 dispatch 抵达生产 handler（wiring 证据第二层）", ctx do
      t = target(ctx.uri, :revoke_ssh_key)
      cap = signed_required_cap!(t, :user, UserSshIdentity, :revoke_ssh_key, ctx.admin)

      # 全新用户没有身份可撤销 —— revoked: false 是幂等成功，证明 dispatch
      # 真的抵达了 UserSshIdentity.handle_revoke_ssh_key/2（框架层若没 wiring
      # 到这个 action，根本到不了这一步）。
      assert {:ok, %{revoked: false}} = dispatch(t, %{}, [cap], ctx.admin)
    end

    test "无 cap 的 dispatch 被 step-5.5 拒（spec §8 第一条）", ctx do
      t = target(ctx.uri, :revoke_ssh_key)

      assert {:error, reason} = dispatch(t, %{}, [], ctx.admin)

      assert reason in @denial_reasons,
             "无 cap 的 revoke_ssh_key dispatch 必须被 step-5.5 cap 门拒绝，得到: " <>
               inspect(reason)
    end

    test "持 read_ssh_public_key cap 不能 dispatch read_ssh_key（spec §8 第二条，最小权限）", ctx do
      pub_target = target(ctx.uri, :read_ssh_public_key)
      priv_target = target(ctx.uri, :read_ssh_key)

      pub_cap =
        signed_required_cap!(pub_target, :user, UserSshIdentity, :read_ssh_public_key, ctx.admin)

      assert {:error, reason} = dispatch(priv_target, %{}, [pub_cap], ctx.admin)

      assert reason in @denial_reasons,
             "持 read_ssh_public_key cap 的 read_ssh_key dispatch 必须被拒绝，得到: " <>
               inspect(reason)
    end
  end
end
