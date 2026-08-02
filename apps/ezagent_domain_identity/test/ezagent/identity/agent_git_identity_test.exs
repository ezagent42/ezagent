defmodule Ezagent.Identity.AgentGitIdentityTest do
  # async: false —— 起真实 Kind + 改 Application env
  #
  # brief 原稿写的是 `use ExUnit.Case, async: false` —— 编译能过，但每个
  # test 一跑就 `DBConnection.OwnershipError`：这个 app 的
  # test_helper.exs 把 `EzagentCore.Repo` 的 sandbox mode 设成 :manual
  # (test_helper.exs:9)，任何触库调用（这里是 setup 块里的
  # `Ezagent.Users.create/3`）都必须先显式 checkout 连接。本目录下其它
  # 会起真实 Kind 的测试（如 identity/grant_test.exs）都用
  # `EzagentCore.DataCase`——它不仅 checkout，还调用
  # `allow_live_kinds/1` 把连接借给测试起的 Kind.Server 进程用（本测试
  # spawn 了真实 User Kind）。已实测确认：换回 DataCase 后 13 个测试的
  # DBConnection.OwnershipError 全部消失。
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Identity.AgentGitIdentity
  alias Ezagent.Identity.Test.GitIdentityFixtureAgentKind
  alias Ezagent.Sandbox.GitIdentityDir

  setup do
    suffix = System.unique_integer([:positive])

    user_uri = Ezagent.URI.entity(:gitid, :user, "owner-#{suffix}")
    agent_uri = Ezagent.URI.entity(:gitid, :agent, "worker-#{suffix}")

    {:ok, _} = Ezagent.Users.create(user_uri, nil, [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)

    # brief 原稿从未 spawn agent_uri —— 实测确认这会让下面 grant_read_ssh_key/3
    # 的 absorb_cap 派发直接落到 `:no_such_actor`（该 URI 从未存在过、无
    # live 进程也无 snapshot 行，绝非"未就绪"）。`ezagent_domain_identity`
    # 不依赖 `ezagent_domain_agent`，不能用真实 `Ezagent.Entity.Agent`；用
    # 本 app 专属的 test-support 轻量 `:agent` 型 fixture Kind
    # （`GitIdentityFixtureAgentKind`——见该文件注释：复用本目录已有的
    # `DeleteUserAgentKind` 试过，只挂了 `Identity` 没挂 `IdentityAdmin`，
    # 而 `:absorb_cap` 实际声明在 `IdentityAdmin` 上，会落到
    # `{:unknown_action, :absorb_cap}`，故新开一个）。
    {:ok, _} =
      Ezagent.Kind.spawn(GitIdentityFixtureAgentKind, %{uri: agent_uri, initial_caps: []})

    kh_dir = Path.join(System.tmp_dir!(), "ezagent-kh-#{suffix}")
    File.mkdir_p!(kh_dir)
    kh_path = Path.join(kh_dir, "known_hosts")
    File.write!(kh_path, "github.com ssh-ed25519 AAAAFAKE\n")

    prev = Application.get_env(:ezagent_core, :git_known_hosts_path)
    Application.put_env(:ezagent_core, :git_known_hosts_path, kh_path)

    on_exit(fn ->
      if prev do
        Application.put_env(:ezagent_core, :git_known_hosts_path, prev)
      else
        Application.delete_env(:ezagent_core, :git_known_hosts_path)
      end

      File.rm_rf(kh_dir)
      File.rm_rf(GitIdentityDir.path(agent_uri))
      Ezagent.Kind.terminate(user_uri)
      Ezagent.Kind.terminate(agent_uri)
    end)

    %{
      user_uri: user_uri,
      agent_uri: agent_uri,
      admin: Ezagent.Entity.User.admin_uri()
    }
  end

  # 给 agent 发一条指向 user_uri 的 read_ssh_key cap（Task 4 的 mix task 做的事，
  # 这里直接用底层 API 造，避免测试依赖 mix task）。
  defp grant_read_ssh_key(agent_uri, user_uri, admin) do
    target = Ezagent.URI.with_action(user_uri, :user_ssh_identity, :read_ssh_key)
    cap = signed_required_cap!(target, :user, UserSshIdentity, :read_ssh_key, agent_uri)
    :ok = Ezagent.Identity.absorb_cap(agent_uri, cap)

    :ok =
      Ezagent.Identity.CapAbsorbAwait.await_exact(agent_uri, [cap], 5_000)

    _ = admin
    cap
  end

  defp revoke_key_for(user_uri, admin) do
    target = Ezagent.URI.with_action(user_uri, :user_ssh_identity, :revoke_ssh_key)
    cap = signed_required_cap!(target, :user, UserSshIdentity, :revoke_ssh_key, admin)

    {:ok, _} =
      %Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([cap]),
          reply: {:caller_inbox, self()}
        }
      }
      |> Ezagent.Invocation.dispatch()
  end

  defp generate_key_for(user_uri, admin) do
    target = Ezagent.URI.with_action(user_uri, :user_ssh_identity, :generate_ssh_key)
    cap = signed_required_cap!(target, :user, UserSshIdentity, :generate_ssh_key, admin)

    {:ok, _} =
      %Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([cap]),
          reply: {:caller_inbox, self()}
        }
      }
      |> Ezagent.Invocation.dispatch()
  end

  describe "关闭态 —— 没有那条 cap" do
    test "返回 {:ok, :none}", ctx do
      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
    end

    test "不写任何文件", ctx do
      {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(GitIdentityDir.path(ctx.agent_uri))
    end

    # 设计 §6.1 —— 这条是让 cap 撤销真正生效的那一步。没有它，撤销只是
    # 让环境变量消失，key 还在 agent 的文件系统上且完全可用。
    test "撤销生效：先成功物化一次，撤掉 cap 后再物化 → 盘上的 key 必须被清掉", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      cap = grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      # `Ezagent.EntityCaps.revoke/2`（`entity_caps.ex:272`）—— 与本文件
      # 授予侧用的 `Ezagent.Identity.absorb_cap/2` 对称的直接入口。
      # （`Ezagent.Identity.revoke_cap/2` **不存在**；带授权的 chokepoint 版本
      # 是 `Ezagent.Identity.Grant.revoke_cap/3`，测试里不需要。）
      :ok = Ezagent.EntityCaps.revoke(ctx.agent_uri, cap)
      assert [] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)

      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(key_path)
    end

    test "只持 read_ssh_public_key cap 不算 —— 仍是关闭态", ctx do
      target = Ezagent.URI.with_action(ctx.user_uri, :user_ssh_identity, :read_ssh_public_key)

      cap =
        signed_required_cap!(
          target,
          :user,
          UserSshIdentity,
          :read_ssh_public_key,
          ctx.agent_uri
        )

      :ok = Ezagent.Identity.absorb_cap(ctx.agent_uri, cap)
      :ok = Ezagent.Identity.CapAbsorbAwait.await_exact(ctx.agent_uri, [cap], 5_000)

      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
    end
  end

  describe "开启态" do
    setup ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      cap = grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)
      %{cap: cap}
    end

    test "返回 GIT_SSH_COMMAND 且私钥落盘", ctx do
      assert {:ok, env} = AgentGitIdentity.materialize(ctx.agent_uri)
      assert %{"GIT_SSH_COMMAND" => cmd} = env
      assert String.starts_with?(cmd, "ssh ")

      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)
      assert String.contains?(File.read!(key_path), "PRIVATE KEY")
    end

    test "cap 即指针：dispatch target 的 instance 等于 cap 的 instance", ctx do
      # cap.instance 就是 user_uri 的 instance —— 若实现改用任何推导
      # （例如从 agent 的 workspace 找 owner），这条会红。
      assert ctx.cap.instance == Ezagent.URI.instance(ctx.user_uri)
      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
    end

    test "窄授权：dispatch 只带那一条 cap，不带 agent 的全部 cap", ctx do
      # 再给 agent 一条无关 cap。
      unrelated_target =
        Ezagent.URI.with_action(ctx.user_uri, :user_ssh_identity, :read_ssh_public_key)

      unrelated =
        signed_required_cap!(
          unrelated_target,
          :user,
          UserSshIdentity,
          :read_ssh_public_key,
          ctx.agent_uri
        )

      :ok = Ezagent.Identity.absorb_cap(ctx.agent_uri, unrelated)

      :ok =
        Ezagent.Identity.CapAbsorbAwait.await_exact(
          ctx.agent_uri,
          [ctx.cap, unrelated],
          5_000
        )

      # brief 原稿这里写"若实现把 list_caps_for/1 的全集塞进 ctx.caps，本条
      # 仍会绿——所以真正的证据是下面的 :telemetry 断言"，但给出的测试代码
      # 里从未真的写那条断言。红演示实测证实了这句话的前半句：把
      # read_private_key/2 内的 `caps: MapSet.new([cap])` 改成
      # `caps: Ezagent.Identity.list_caps_for(agent_uri)`（即把 agent 的
      # 全部 cap 塞进 dispatch ctx），下面到 `dispatch_caps/1` 的三条断言
      # 全部仍然绿——unrelated 只是混进去的无关旁观者，ctx.cap 本身就足以
      # 授权这次 dispatch，多余的 cap 不改变授权结果；dispatch_caps/1 是纯
      # 函数、也不读上一次真实 dispatch 到底传了什么。这是一个真实发现，
      # 已如实报告（task-3-report.md）。
      #
      # 这里补上真正的证据：本仓库既有的 :erlang.trace 惯例（同一模式见
      # apps/ezagent_core/test/ezagent/invocation_test.exs）直接钉住
      # read_private_key/2 真正传给 Ezagent.Invocation.dispatch/1 的
      # ctx.caps —— 不需要改动任何生产代码。踩过一个坑：对 `self()`
      # 直接 `:erlang.trace(self(), true, [:call])` 在这个环境里实测收不到
      # trace 消息（单独探针验证过——对一个全新 spawn 的子进程 trace
      # 同一调用能收到，对测试进程自身 trace 收不到，怀疑是 ExUnit/沙箱
      # 已经占用了该进程的 tracer 角色）；改成把 materialize/1 放进一个新
      # Task 里跑，trace 那个 Task 的 pid——这条路径实测有效。
      assert :erlang.trace_pattern({Ezagent.Invocation, :dispatch, 1}, true, [:local]) >= 0

      task =
        Task.async(fn ->
          receive do
            :go -> AgentGitIdentity.materialize(ctx.agent_uri)
          end
        end)

      assert 1 = :erlang.trace(task.pid, true, [:call])
      send(task.pid, :go)

      on_exit(fn ->
        :erlang.trace_pattern({Ezagent.Invocation, :dispatch, 1}, false, [:local])
      end)

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = Task.await(task)

      :erlang.trace_pattern({Ezagent.Invocation, :dispatch, 1}, false, [:local])

      task_pid = task.pid

      assert_receive {:trace, ^task_pid, :call,
                      {Ezagent.Invocation, :dispatch,
                       [%Ezagent.Invocation{ctx: %{caps: dispatched_caps}}]}},
                     1_000

      assert MapSet.to_list(dispatched_caps) == [ctx.cap]

      # 结构证据：实现暴露的 caps-selection 是纯函数，直接断言它。
      assert [selected] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)
      assert selected == ctx.cap
    end
  end

  describe "配错了 —— 要吵，但不能掀翻 spawn" do
    test "有 cap 但 user 从未生成 key → :owner_has_no_key", ctx do
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:error, :owner_has_no_key} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519"))
    end

    # 设计 §6.1 —— read 失败发生在 `GitIdentityRuntime.write/2` **被调用之前**，
    # 所以 write 自己的清理兜不住这一格：必须由 materialize/1 清。
    # 上面那条用的是全新目录，测不到这个状态迁移。
    test "读失败也清盘：先成功物化一次，再让 User 撤销 key，第二次必须把旧 key 清掉", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      revoke_key_for(ctx.user_uri, ctx.admin)

      assert {:error, :owner_has_no_key} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(key_path)
    end

    test "known_hosts 未配置 → :known_hosts_unconfigured", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)
      Application.delete_env(:ezagent_core, :git_known_hosts_path)

      assert {:error, :known_hosts_unconfigured} =
               AgentGitIdentity.materialize(ctx.agent_uri)
    end

    test "没有 key 与 key 损坏是两个不同的错误值（1a 的区分不得被合并）" do
      # 纯值断言，不依赖运行时状态。
      refute :owner_has_no_key == {:owner_key_unavailable, :ssh_identity_unavailable}
    end

    test "所有错误路径都返回元组，不抛异常", ctx do
      # 非 agent URI —— 最容易被漏掉的一条：materialize 若在 GitIdentityDir.path/1
      # 上 raise，就会把 spawn 掀翻。
      #
      # brief 原稿直接对一个"没有任何 cap"的 user_uri 调 materialize/1——
      # 实测（见本文件历史/task-3-report.md）发现那条路径根本走不到
      # GitIdentityDir.path/1：dispatch_caps 在空 cap 集上直接短路进
      # `{:ok, :none}` 分支，GitIdentityRuntime.wipe/1 内部自己就有
      # rescue，会把非 agent URI 的 ArgumentError 吃掉——materialize/1
      # 自己的顶层 rescue 从未被触发，原断言 `{:error, _}` 因此不成立
      # （真实返回是 `{:ok, :none}`，也是一个元组、也没抛异常，只是不是
      # error）。改成真正会走到 write/2（该函数内部没有自己的 rescue）再
      # 向上抛的路径：给 user_uri 生成一把真 key，再发一条"指向它自己"的
      # read_ssh_key cap（cap 的 instance 语义上是"该读谁"，不要求跟持有者
      # 不同）。materialize(user_uri) 因此会成功读到私钥、进
      # GitIdentityRuntime.write(user_uri, ...)；user_uri 不是 agent 类型
      # URI，GitIdentityDir.path/1 在其中 raise，write/2 没有自己的
      # rescue，一路传到 materialize/1 的顶层 rescue，这才是这条测试的
      # 名字实际要钉住的东西。
      generate_key_for(ctx.user_uri, ctx.admin)
      grant_read_ssh_key(ctx.user_uri, ctx.user_uri, ctx.admin)

      assert {:error, {:git_identity_materialize_crashed, _}} =
               AgentGitIdentity.materialize(ctx.user_uri)
    end

    test "instance 为通配 :any 的 cap 不算开启 —— 它没指向任何 User", ctx do
      # 这条 cap 结构上无法进入 agent 的持有集合——absorb 的签名校验会拒绝
      # 一份未签名的 wildcard-instance artifact，所以这里不能端到端构造
      # "agent 真的持有它"的场景（brief 原稿的 `&match?(...)` 写法本身也
      # 不是合法的 capture 语法，编译不过——已改写）。留着这个字面量只是
      # 为了在测试里明确写出被拒绝的 cap 长什么样：kind/behavior/action
      # 全部匹配，只有 instance 是 :any。
      _wildcard = %Ezagent.Capability{
        kind: :user,
        behavior: UserSshIdentity,
        action: :read_ssh_key,
        instance: :any,
        workspace_uri: Ezagent.Capability.workspace_of(ctx.user_uri),
        granted_by: :plugin_declared,
        granted_at: :compile_time
      }

      assert AgentGitIdentity.dispatch_caps(ctx.agent_uri) == []
      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
    end
  end
end
