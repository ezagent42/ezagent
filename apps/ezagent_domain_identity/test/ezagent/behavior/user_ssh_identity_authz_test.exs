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
     "production CapabilityRegistry wiring" 组直接读注册表，补上这条证据。
     **"真实 dispatch 打到生产 Ezagent.Entity.User Kind" 组不是第二层同类
     证据**——`Ezagent.Kind.BehaviorSet.resolve_action/3` 在
     `CapabilityRegistry` 查找 miss 时会回落到按 `Entity.User.behaviors()`
     做 per-instance 匹配（源码注释自称 "RF-1"，见 `kind/runtime.ex`），所以
     删掉那行注册后真实 dispatch 依旧成功（已实测确认，见下方对应测试的
     注释）——它证明的是"生产 User 实例的 effective behavior set 能抵达
     handler"，是一条独立、更弱的性质，不能替代注册表直读那组证据。
  2. **`kind: :user` 轴**：`required_caps/0` 是手写的、整体覆盖式的实现——
     不是按 key 跟 Lifecycle 宏的自动派生合并；手写 `required_caps/0` 存在
     时宏根本不会注入另一份 map（`legacy_callbacks.ex` 的
     `maybe_add_unless_defined`，见该文件）。所以如果以后有人加第五个
     action、忘了把它加进这份手写 map，该 action 会在派发时落回
     **verifier**（`Ezagent.Cap.Verifier.required_cap/4` 的回落分支，*不是*
     Lifecycle 宏）合成的通用形状：`kind: kind_type(kind_module)`——在
     User Kind 上取值恰好也是 `:user`（净效果今天相同），但那是"跟随当前
     注册 Kind 派生"，不再是这份 map 里那种与注册 Kind 无关的显式声明——
     这个仓库没有任何 CI gate 会为 domain 层 Behavior 抓到「漏加声明」本身
     （plugin 编译器有 key-parity 检查，`ezagent_domain_identity` 没装）。
     下面「声明正确性」分组里的第二个测试是唯一会抓到它的东西。

  ## 不测什么（有意识的取舍，抄 brief 原文）

  不在这里重测"无 cap 的 dispatch 被 step-5.5 拒"这条**框架级通用机制**
  本身——CapBAC 的中央测试已经覆盖"cap 门存在且生效"这件事，重复验证机制
  本身是重复劳动。但"这四个 action 各自的 required cap 声明是否真的在为
  它自己把关"是另一件事，中央测试测不到（它不知道 UserSshIdentity 这四个
  action 的存在）——round-3 review 发现最初版本只对 `revoke_ssh_key` 一个
  action 做了这项检查，Task 3 的头号主张「四个 action 都在 cap 门后」因此
  只对四分之一成立。下面 "真实 dispatch 打到生产 Kind" 组现在对四个
  action 逐一做「无该 action 的 cap → 真实 dispatch → 必须被拒」，外加
  spec §8 第二条（公钥读 cap 不能越权到私钥读）——这些都是针对这四个
  具体声明的覆盖，不是重测框架机制本身。
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

    test "每个 action 的 required cap 都显式钉在 kind: :user、behavior 指向本模块，action 与 map key 一致，且互不相同" do
      caps = UserSshIdentity.required_caps()

      for action <- UserSshIdentity.actions() do
        cap =
          case Map.fetch(caps, action) do
            {:ok, cap} ->
              cap

            :error ->
              flunk(
                "#{action} 必须在 required_caps/0 中声明一条 cap —— 缺失时这个 action " <>
                  "会在派发时落回 Ezagent.Cap.Verifier.required_cap/4 的回落分支（不是 " <>
                  "Lifecycle 宏——手写 required_caps/0 存在时宏根本不注入另一份 map），合成 " <>
                  "kind: kind_type(kind_module)：今天净效果仍是 :user，但不再是「归 User、" <>
                  "不归 Agent」这条与注册 Kind 无关的显式声明"
              )
          end

        assert cap.kind == :user,
               "#{action} 的 required cap 必须显式钉在 kind: :user（当前是 " <>
                 "#{inspect(cap.kind)}）—— 见 user_ssh_identity.ex required_caps/0 " <>
                 "上方注释：kind: :any 会在派发时被目标 Kind 的 type_name/0 替换"

        assert cap.behavior == UserSshIdentity,
               "#{action} 的 required cap 必须指向 #{inspect(UserSshIdentity)} 本身（当前是 " <>
                 "#{inspect(cap.behavior)}）—— verifier 会原样保留声明中的 behavior（不像 " <>
                 "kind 有 :any 替换兜底），复制粘贴其它模块的声明时最容易在这里笔误——一旦" <>
                 "笔误，所需的 cap 就不再指向本模块，这是真实的授权漂移"

        assert cap.action == action,
               "#{action} 的 required cap 的 action 字段必须与 map key 一致（当前是 " <>
                 "#{inspect(cap.action)}）"
      end

      # 公钥读与私钥读必须是两条不同的 cap —— 持前者不得能做后者（最小权限）。
      # 注意：单看这一条不足以单独证明 kind/behavior 轴被钉住——两者的 action
      # 字段本来就不同，即使 kind/behavior 都退化成别的值，这条比较也会碰巧
      # 成立；kind 与 behavior 轴由上面的循环逐条单独断言。
      refute caps[:read_ssh_public_key] == caps[:read_ssh_key]
    end

    test "已注册到 User Kind 的 behaviors/0（声明层——不证明 CapabilityRegistry wiring，见下）" do
      assert UserSshIdentity in User.behaviors()
    end
  end

  describe "production CapabilityRegistry wiring" do
    test "四个 action 在真实 CapabilityRegistry 上都把 Ezagent.Entity.User wiring 到 UserSshIdentity" do
      for action <- UserSshIdentity.actions() do
        assert match?(
                 {:ok, %{behavior: UserSshIdentity}},
                 CapabilityRegistry.lookup_subject(User, action)
               ),
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

    test "持正确 cap 的 revoke_ssh_key 真实 dispatch 抵达生产 handler（不是 CapabilityRegistry 注册的第二层证据——见 moduledoc）",
         ctx do
      t = target(ctx.uri, :revoke_ssh_key)
      cap = signed_required_cap!(t, :user, UserSshIdentity, :revoke_ssh_key, ctx.admin)

      # 全新用户没有身份可撤销 —— revoked: false 是幂等成功，证明 dispatch
      # 真的抵达了 UserSshIdentity.handle_revoke_ssh_key/2。注意：这条**不能**
      # 当作 CapabilityRegistry.register/3 wiring 的第二层证据——RF-1 回落
      # （resolve_action/3 在 CapabilityRegistry 查找 miss 时按
      # Entity.User.behaviors() 做 per-instance 匹配）会让这条 dispatch 即使
      # 删掉那行注册也照样成功；真正覆盖注册表 wiring 的只有上面
      # "production CapabilityRegistry wiring" 组的直读测试。
      assert {:ok, %{revoked: false}} = dispatch(t, %{}, [cap], ctx.admin)
    end

    test "无 cap 的 dispatch 对四个 action 都被 step-5.5 拒（spec §8 第一条）", ctx do
      for action <- UserSshIdentity.actions() do
        t = target(ctx.uri, action)

        assert {:error, reason} = dispatch(t, %{}, [], ctx.admin)

        assert reason in @denial_reasons,
               "#{action} 的无 cap dispatch 必须被 step-5.5 cap 门拒绝，得到: " <>
                 inspect(reason) <>
                 " —— 检查 verifier.ex 的 @non_cap_actions 白名单是否把这个 action 加了进去"
      end
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
