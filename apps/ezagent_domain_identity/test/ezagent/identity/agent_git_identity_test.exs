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
  import ExUnit.CaptureLog

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

  # C2/M6 —— a SECOND, independent User. Spawned + torn down by the caller
  # (via `on_exit`), same shape as the `user_uri` the top-level `setup`
  # already builds. Used to prove two things the single-user fixture
  # structurally cannot: (C2) that TWO `read_ssh_key` caps pointing at
  # DIFFERENT Users is a real, constructible state, and (M6) that
  # `materialize/1` dispatches to the User the cap actually names, not to
  # some other User that happens to be reachable.
  defp create_second_user(suffix) do
    user_uri = Ezagent.URI.entity(:gitid, :user, "owner2-#{suffix}")
    {:ok, _} = Ezagent.Users.create(user_uri, nil, [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)
    user_uri
  end

  # C3/M6 —— run `materialize/1` in a throwaway process and trace the actual
  # `Ezagent.Invocation.dispatch/1` calls it makes, rather than trusting
  # `materialize/1`'s return value or `dispatch_caps/1`'s (pure, separately
  # tested) answer to speak for what a real call site does. Mirrors the
  # established pattern in the "窄授权" test below (same file) — including
  # the same worked-around pitfall noted there: tracing `self()` directly
  # does not deliver trace messages in this environment, so the traced call
  # runs inside a fresh `Task` instead.
  #
  # Returns `{materialize_result, invocations}` where `invocations` is the
  # list of `%Ezagent.Invocation{}` structs actually passed to
  # `Ezagent.Invocation.dispatch/1` (`[]` when it was never called).
  defp materialize_and_trace_dispatch(agent_uri) do
    assert 1 = :erlang.trace_pattern({Ezagent.Invocation, :dispatch, 1}, true, [:local])

    task =
      Task.async(fn ->
        receive do
          :go -> AgentGitIdentity.materialize(agent_uri)
        end
      end)

    assert 1 = :erlang.trace(task.pid, true, [:call])
    send(task.pid, :go)

    result = Task.await(task, 6_000)
    :erlang.trace_pattern({Ezagent.Invocation, :dispatch, 1}, false, [:local])

    task_pid = task.pid
    {result, drain_dispatch_trace(task_pid)}
  end

  defp drain_dispatch_trace(task_pid) do
    receive do
      {:trace, ^task_pid, :call, {Ezagent.Invocation, :dispatch, [inv]}} ->
        [inv | drain_dispatch_trace(task_pid)]
    after
      300 -> []
    end
  end

  describe "关闭态 —— 没有那条 cap" do
    test "返回 {:ok, :none}", ctx do
      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
    end

    test "不写任何文件", ctx do
      {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(GitIdentityDir.path(ctx.agent_uri))
    end

    # C3 —— 设计 §8 ③ 第 1 条明确要求"没有发生任何 dispatch"，不只是
    # "返回值恰好是 {:ok, :none}"。一个把 :unauthorized/:missing_cap 映射
    # 成 {:ok, :none} 的实现（先 dispatch 一次探测再决定）会让上面两条测试
    # 照样全绿，却让每个不持有这条 cap 的 agent（部署里的绝大多数）每次
    # spawn 都对某个 User Kind 发一次授权探测。用 :erlang.trace 钉住"零
    # dispatch"，用 capture_log 顺手钉住 M4 的"关闭态不打日志"。
    test "无 cap 时不发生任何 dispatch，也不打日志", ctx do
      log =
        capture_log(fn ->
          {result, invocations} = materialize_and_trace_dispatch(ctx.agent_uri)
          assert {:ok, :none} = result
          assert invocations == []
        end)

      assert log == ""
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

    test "cap 即指针：dispatch target 的 instance 等于 cap 的 instance，不是任何其它 User", ctx do
      # cap.instance 就是 user_uri 的 instance —— 若实现改用任何推导
      # （例如从 agent 的 workspace 找 owner），这条会红。
      assert ctx.cap.instance == Ezagent.URI.instance(ctx.user_uri)

      # M6 —— 上面这句只断言了"测试自己造的 fixture"的属性：本 describe
      # block 里只有一个 User，所以哪怕实现独立推导出同一个 User（而不是
      # 读 cap），这句话照样成立、测试照样绿。放进第二个独立 User（不发
      # 任何 cap 指向它），并直接 trace 真正传给 Invocation.dispatch/1 的
      # target，逼"读 cap"与"任何形式的推导"在结果上必然分叉。
      suffix = System.unique_integer([:positive])
      decoy_user_uri = create_second_user(suffix)
      generate_key_for(decoy_user_uri, ctx.admin)

      refute Ezagent.URI.instance(decoy_user_uri) == ctx.cap.instance

      {result, invocations} = materialize_and_trace_dispatch(ctx.agent_uri)
      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = result
      assert [%Ezagent.Invocation{target: target}] = invocations

      dispatched_instance = Ezagent.URI.instance(target)
      assert dispatched_instance == ctx.cap.instance
      refute dispatched_instance == Ezagent.URI.instance(decoy_user_uri)
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
      #
      # M3 (2026-08-02 review 修正): 原断言是 `>= 0`——`:erlang.trace_pattern/3`
      # 对一个具体 MFA 的返回值是"匹配到的函数数"，类型上永远非负，`>= 0`
      # 因此永远为真，不是断言。改成 `assert 1 = ...`：期望恰好匹配到
      # `Ezagent.Invocation.dispatch/1` 这一个函数——MFA 打错字/改名时这里
      # 会变成 0，让断言真的红，而不是默默 trace 不到任何调用。
      assert 1 = :erlang.trace_pattern({Ezagent.Invocation, :dispatch, 1}, true, [:local])

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

      log =
        capture_log(fn ->
          assert {:error, :owner_has_no_key} = AgentGitIdentity.materialize(ctx.agent_uri)
        end)

      refute File.exists?(Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519"))

      # M1 —— 设计 §3.1 把这格标成 Logger.warning（另两格才是 error）：
      # 运维还没生成 key 是软配错，不该跟"节点没配 known_hosts"/"身份损坏"
      # 那种硬故障用同一告警级别，否则按 level 告警的部署会把它当 error 页出来。
      assert log =~ "[warning]"
      refute log =~ "[error]"

      # C5/M4 —— 吵，且带具体指引：至少要点名"哪个 User"、"该做什么"。
      assert log =~ URI.to_string(ctx.user_uri)
      assert log =~ ":generate_ssh_key"
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

      log =
        capture_log(fn ->
          assert {:error, :known_hosts_unconfigured} =
                   AgentGitIdentity.materialize(ctx.agent_uri)
        end)

      # M1 —— 节点配置问题是硬故障，Logger.error（不是 :owner_has_no_key
      # 那一格的 warning）。
      assert log =~ "[error]"

      # C5 —— 设计 §3.1 明确要求这格带具体修复命令。
      assert log =~ "mix ezagent.git.known_hosts"
    end

    # C4 —— 上面这条曾经是 `refute :owner_has_no_key == {:owner_key_unavailable,
    # :ssh_identity_unavailable}`：一个原子跟一个元组的恒真比较，不调用被测
    # 模块任何函数，测试名声称钉住了 1a 的区分，实际什么都没钉住（删掉
    # `interpret_read_result/1` 的任一映射 clause，这条断言原样成立）。替换
    # （不是并排放）成一组直接喂 `interpret_read_result/1` 的测试——见文件
    # 末尾 `describe "interpret_read_result/1..."`（ExUnit 不允许嵌套
    # describe，这组测试的自然位置是这个 describe block 内部，但只能放在
    # 模块顶层）。

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

  # C4 —— 1b 自己的 seam：`read_private_key/2` 抽出来的整个 case（成功支/
  # 两条 1a 区分支/兜底错误支/畸形输入支全部一起抽，不只抽错误支——只抽
  # 错误支会让被测函数的分支集与真实调用点分叉，成功支和兜底支照样没人
  # 守）。不钉住"1a 还在发 :ssh_identity_unavailable"——那是 1a 自己的
  # 契约，由 user_ssh_identity_test.exs:309/319/332/374/381/395 独立守着；
  # 这里钉住的只是 1b 把 1a 的返回值映射成什么。删掉任一映射 clause，本组
  # 测试必须有断言变红。
  describe "interpret_read_result/1 —— C4：1b 自己的 seam，不是 1a 的重复断言" do
    test "成功：{:ok, %{private_key: pem}} → {:ok, pem}" do
      assert {:ok, "pem-bytes"} =
               AgentGitIdentity.interpret_read_result({:ok, %{private_key: "pem-bytes"}})
    end

    test "1a :ssh_identity_absent → :owner_has_no_key" do
      assert {:error, :owner_has_no_key} =
               AgentGitIdentity.interpret_read_result({:error, :ssh_identity_absent})
    end

    test "1a :ssh_identity_unavailable → {:owner_key_unavailable, :ssh_identity_unavailable}" do
      assert {:error, {:owner_key_unavailable, :ssh_identity_unavailable}} =
               AgentGitIdentity.interpret_read_result({:error, :ssh_identity_unavailable})
    end

    test "没有 key 与 key 损坏映射到两个不同的返回值（1a 的区分不得被合并）" do
      absent = AgentGitIdentity.interpret_read_result({:error, :ssh_identity_absent})
      unavailable = AgentGitIdentity.interpret_read_result({:error, :ssh_identity_unavailable})

      refute absent == unavailable
      assert {:error, :owner_has_no_key} = absent
      assert {:error, {:owner_key_unavailable, _}} = unavailable
    end

    test "其它已知 error reason 原样包一层，不丢失原始 reason" do
      assert {:error, {:ssh_key_read_failed, :some_other_reason}} =
               AgentGitIdentity.interpret_read_result({:error, :some_other_reason})
    end

    test "畸形/意外输入不抛异常，且不回显原始值（M5：只描述形状）" do
      assert {:error, {:ssh_key_read_unexpected, :malformed_result}} =
               AgentGitIdentity.interpret_read_result(:totally_unexpected)

      # 私钥非 binary 的畸形成功结果——今天在 1a 的守卫下不可达（见该函数
      # @doc false 的说明），但 interpret_read_result/1 自己必须仍然拒绝
      # 它，而不是把非法值当合法私钥透传。
      result = AgentGitIdentity.interpret_read_result({:ok, %{private_key: 12_345}})
      assert {:error, {:ssh_key_read_unexpected, :malformed_result}} = result
      refute inspect(result) =~ "12345"
    end
  end

  # M2 —— `report/3` 曾经调用 `user_uri_of/1` 两次；一份畸形 `cap.instance`
  # 会让第二次调用在 `report/3` 内部抛异常，被 `materialize/1` 顶层 rescue
  # 吞成 `:git_identity_materialize_crashed`，`report/3` 存在的意义（把真实
  # reason 交给运维）反而丢失。改成只算一次、算不出来时退化成
  # `inspect(cap.instance)`。没有合法 cap 能在生产端到端携带畸形
  # instance 走到这里（签名校验会挡；见 M2 的实现注释），所以这里直接单测
  # `user_uri_string/1` 本身。
  describe "user_uri_string/1 —— M2：畸形 instance 不丢失真实 reason" do
    test "合法 URI instance → URI 字符串", ctx do
      cap = %Ezagent.Capability{
        kind: :user,
        behavior: UserSshIdentity,
        action: :read_ssh_key,
        instance: Ezagent.URI.instance(ctx.user_uri),
        workspace_uri: Ezagent.Capability.workspace_of(ctx.user_uri),
        granted_by: :plugin_declared,
        granted_at: :compile_time
      }

      assert AgentGitIdentity.user_uri_string(cap) == URI.to_string(ctx.user_uri)
    end

    test "畸形 binary instance 不抛异常，退化成 inspect(cap.instance)", ctx do
      malformed_cap = %Ezagent.Capability{
        kind: :user,
        behavior: UserSshIdentity,
        action: :read_ssh_key,
        # 缺 scheme —— `Ezagent.URI.new!/1` 对这个输入会 raise
        # `ArgumentError: "URI missing scheme"`。
        instance: "not-a-uri-at-all",
        workspace_uri: Ezagent.Capability.workspace_of(ctx.user_uri),
        granted_by: :plugin_declared,
        granted_at: :compile_time
      }

      assert AgentGitIdentity.user_uri_string(malformed_cap) == inspect("not-a-uri-at-all")
    end
  end

  # C5 —— `remediation/2` 的 `{:owner_key_unavailable, _}` 分支没有任何
  # 端到端可达路径（C4 已证明：1a 只公开"全设"与"全清"两种 action，没有
  # 公开路径能构造半身份态），所以要单独钉住这条分支的文字内容，只能直接
  # 调用它——`:owner_has_no_key` 与 `:known_hosts_unconfigured` 两条已经在
  # 上面"配错了"describe block 里通过真实 materialize/1 + capture_log 钉住。
  describe "remediation/2 —— C5：给可执行指引，不是抽象动作名" do
    test ":owner_key_unavailable 指向具体动作序列（先 revoke 再 generate）" do
      text =
        AgentGitIdentity.remediation(
          {:owner_key_unavailable, :ssh_identity_unavailable},
          "entity://ws/user/u1"
        )

      assert text =~ "entity://ws/user/u1"
      assert text =~ ":revoke_ssh_key"
      assert text =~ ":generate_ssh_key"
    end

    test "ambiguous_git_identity 点名全部冲突的 User，并给出撤销路径" do
      text =
        AgentGitIdentity.remediation(
          {:ambiguous_git_identity, ["entity://ws/user/a", "entity://ws/user/b"]},
          nil
        )

      assert text =~ "entity://ws/user/a"
      assert text =~ "entity://ws/user/b"
      assert text =~ "Ezagent.EntityCaps.revoke/2"
    end

    test "未覆盖的 reason 退化成空字符串（不是抛异常/占位符垃圾）" do
      assert AgentGitIdentity.remediation(:some_unmapped_reason, "x") == ""
    end
  end

  # C2 —— 持多条指向不同 User 的 read_ssh_key cap 是结构上可能的状态（每条
  # cap 的 identity_key 含 instance，指向 A 与指向 B 是两条不同的 cap，授权
  # 层不会把它们当重复拒绝）：运维想把 agent 的 git 身份从 A 换成 B、忘了先
  # 撤 A，就会落进这个状态。旧实现 `[cap | _]` 会静默取 MapSet 内部序决定的
  # 任意一条——agent 以错误身份 push，且全程静默。
  describe "C2 —— 持多条 read_ssh_key cap 指向不同 User" do
    test "两条 cap 指向不同 User → {:error, {:ambiguous_git_identity, _}}，盘上无 key，且吵", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      suffix = System.unique_integer([:positive])
      other_user_uri = create_second_user(suffix)
      generate_key_for(other_user_uri, ctx.admin)
      grant_read_ssh_key(ctx.agent_uri, other_user_uri, ctx.admin)

      assert length(AgentGitIdentity.dispatch_caps(ctx.agent_uri)) == 2

      log =
        capture_log(fn ->
          assert {:error, {:ambiguous_git_identity, user_strs}} =
                   AgentGitIdentity.materialize(ctx.agent_uri)

          assert length(user_strs) == 2
          assert URI.to_string(ctx.user_uri) in user_strs
          assert URI.to_string(other_user_uri) in user_strs
        end)

      refute File.exists?(Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519"))
      assert log =~ "[error]"
      assert log =~ "MULTIPLE"
    end
  end

  # C1 —— `materialize/1`'s `rescue` only catches raised Elixir exceptions.
  # `Ezagent.Invocation.dispatch/1`'s `:call` mode deliberately RE-RAISES an
  # EXIT (a `GenServer.call` timeout, or the target handler crashing) rather
  # than mapping it to `{:error, _}` — `call_live_target/3` only turns a
  # DEAD/closing target into a tuple. A live-but-busy target (e.g. mid
  # keygen) was, before this fix, enough to take the CALLING process down
  # with `materialize/1`, silently escalating a recoverable git-identity
  # misconfiguration into an agent that can't start (design §3.2).
  describe "C1 —— dispatch 的 exit 不能掀翻调用进程" do
    test "目标 User Kind 挂起（活着但不响应）时，materialize/1 返回错误元组而不是让调用进程一起死",
         ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      # 先走一次正常路径，证明这条 cap/key 本身没问题——之后的失败只能来自
      # "目标不响应"，不是别的什么配置错误。
      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      {:ok, user_pid} = Ezagent.KindRegistry.lookup(ctx.user_uri)
      :ok = :sys.suspend(user_pid)

      on_exit(fn ->
        if Process.alive?(user_pid), do: :sys.resume(user_pid)
      end)

      # 不用 Task.async/Task.await（它们互相 link——被挂起目标真正造成的
      # EXIT 会先把这个专用探测进程带走，`spawn_monitor` 完全隔离测试进程，
      # 只用 :DOWN 消息把结果带回来，不管子进程是正常返回还是被 exit 带走）。
      test_pid = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(test_pid, {:materialize_result, AgentGitIdentity.materialize(ctx.agent_uri)})
        end)

      outcome =
        receive do
          {:materialize_result, result} ->
            Process.demonitor(ref, [:flush])
            {:completed, result}

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:exited, reason}
        after
          # invocation.ex:458 的默认 GenServer.call deadline 是 5000ms（本
          # 模块的 dispatch ctx 未设 deadline_ms，落到这个默认值）；给点余量。
          6_000 ->
            flunk("materialize/1 在 6s 内既没返回也没 exit —— 目标真的被挂起了吗？")
        end

      :sys.resume(user_pid)

      assert {:completed, {:error, {:git_identity_materialize_exited, _}}} = outcome

      # C1 附带：exit 分支也必须清盘（§6.1 第三格——除 {:ok, env} 外每种
      # 结局都清）。
      refute File.exists?(key_path)
    end
  end
end
