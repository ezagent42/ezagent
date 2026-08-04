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

  alias Ezagent.ActionSet.IdentityAdmin
  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Identity.AgentGitIdentity
  alias Ezagent.Identity.RecipeCapBinding
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

    # Revocation is an immediate security boundary: removing the cap itself
    # must wipe the materialized key, without waiting for another spawn/retire.
    #
    # B2' revoke-ordering fix (2026-08-04): the wipe now runs via
    # `{:dispatch_after_commit, %Ezagent.Cmd{}}` — `Ezagent.Kind.DeferredDispatch`
    # enqueues it to the agent's OWN mailbox (`send(self(), {:ezagent_run_deferred,
    # _}}`) and it runs on a LATER `handle_info` turn, strictly AFTER
    # `EntityCaps.revoke/2`'s underlying `:call` dispatch has already replied to
    # THIS test process. So "revoke returned" no longer implies "wipe already
    # ran" — poll instead of asserting immediately. `Ezagent.LifecycleCase.wait_until/2`
    # (`apps/ezagent_core/lib/ezagent/lifecycle_case.ex`) is the repo's existing
    # cross-app polling helper (deliberately in `lib/`, not `test/support/`, so
    # non-owning apps' test suites can call it — same rationale as
    # `EzagentCore.DataCase`), not a bare `Process.sleep` wait.
    test "撤销 read_ssh_key cap 后（提交后异步）清掉盘上的 key", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      cap = grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      :ok = Ezagent.EntityCaps.revoke(ctx.agent_uri, cap)
      assert [] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)
      Ezagent.LifecycleCase.wait_until(fn -> not File.exists?(key_path) end)
    end

    test "撤销非 read_ssh_key cap 不清理已物化的 key", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      read_cap = grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)
      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)

      public_target =
        Ezagent.URI.with_action(ctx.user_uri, :user_ssh_identity, :read_ssh_public_key)

      public_cap =
        signed_required_cap!(
          public_target,
          :user,
          UserSshIdentity,
          :read_ssh_public_key,
          ctx.agent_uri
        )

      :ok = Ezagent.Identity.absorb_cap(ctx.agent_uri, public_cap)

      :ok =
        Ezagent.Identity.CapAbsorbAwait.await_exact(
          ctx.agent_uri,
          [read_cap, public_cap],
          5_000
        )

      :ok = Ezagent.EntityCaps.revoke(ctx.agent_uri, public_cap)
      assert File.exists?(Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519"))
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

    # B2' revoke-ordering fix（2026-08-04）—— 结构断言：`handle_revoke_cap/2`
    # （`#1693` 的原始路径，`maybe_add_git_identity_wipe/3`）现在产出的是
    # `{:dispatch_after_commit, %Ezagent.Cmd{}}`，不是同步执行的
    # `{:effect, {GitIdentityRuntime, :wipe}, _}`。这正是"不在 handler 内同步
    # 执行，父 slice 提交后才跑"这条顺序保证本身的判据——端到端构造不了
    # `commit_and_notify` 失败（没有可控注入点），所以退到这一层：直接调用
    # handler（跳过真实 dispatch/commit）验证它产出的 EFFECT 形状。跟下面
    # "sync_recipe_binding" describe block 里对 `maybe_add_recipe_binding_
    # git_identity_wipe/4` 的同款结构断言对称——那条覆盖本轮新补的路径，这条
    # 覆盖 `#1693` 的原始 hook。
    test "handle_revoke_cap/2 撤销 read_ssh_key cap 时返回的 effects 是 {:dispatch_after_commit, _}，不是同步 {:effect, _, _}",
         ctx do
      rigged_ctx = %{
        caller: ctx.admin,
        self_uri: ctx.agent_uri,
        read: fn :caps, _default -> MapSet.new([ctx.cap]) end
      }

      assert {:ok, %{caps: _}, effects} =
               IdentityAdmin.handle_revoke_cap(%{cap: ctx.cap}, rigged_ctx)

      refute Enum.any?(
               effects,
               &match?({:effect, {Ezagent.Credential.GitIdentityRuntime, :wipe}, _}, &1)
             )

      assert wipe_effect =
               Enum.find(
                 effects,
                 &match?({:dispatch_after_commit, %Ezagent.Cmd{action: :wipe_git_identity}}, &1)
               )

      assert {:dispatch_after_commit, %Ezagent.Cmd{} = cmd} = wipe_effect
      assert cmd.action == :wipe_git_identity
      assert Ezagent.URI.instance(cmd.target) == Ezagent.URI.instance(ctx.agent_uri)
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

  # §6.2.1 fixture helper —— 任意一条 agent-kind cap 提案，用来撑起一条真实、
  # 会变化的 RecipeCapBinding（镜像 recipe_cap_binding_lifecycle_test.exs 的
  # `proposal/2`；选 Sandbox.read/Sandbox.destroy 没有别的理由，只是这个 app
  # 测试套件里已经这么用过）。
  defp agent_kind_proposal(agent_uri, action) do
    Ezagent.Capability.cap(
      :agent,
      Ezagent.ActionSet.Sandbox,
      action,
      Ezagent.URI.instance(agent_uri),
      Ezagent.Capability.workspace_of(agent_uri)
    )
  end

  # 未签名、不走 verified_set 的裸 cap —— 只用于 read_ssh_key_cap_change?/2 的
  # 纯函数单测（不 dispatch，不落盘），镜像本文件其它两处已有的同款裸 cap 字面量
  # （"instance 为通配 :any 的 cap 不算开启" / user_uri_string/1 两组测试）。
  defp bare_read_ssh_key_cap(user_uri, workspace_source_uri) do
    %Ezagent.Capability{
      kind: :user,
      behavior: UserSshIdentity,
      action: :read_ssh_key,
      instance: Ezagent.URI.instance(user_uri),
      workspace_uri: Ezagent.Capability.workspace_of(workspace_source_uri),
      granted_by: :plugin_declared,
      granted_at: :compile_time
    }
  end

  # §6.2.1 —— #1693 自己的 commit message 点名的第一个未覆盖缺口："recipe-binding
  # reconciliation" 也能在不经过 handle_remove_cap/2 或 handle_revoke_cap/2 的情况下
  # 让 read_ssh_key 消失。`handle_sync_recipe_binding/2` 做的是
  # `set_caps_effect(reconciled.caps)` —— 整集替换，不是单条移除，所以 #1693 那两个
  # 按"被移除的那条 cap"模式匹配的 handler 永远不会在这条路上触发。
  #
  # 判据是"比较替换前后"，不耦合到哪个内部机制丢的 —— 早前一版这里也点名过
  # `Ezagent.Cap.verified_set/2` 是可能的丢失机制，**该说法已撤回**：
  # `Ezagent.Cap.storable_for?/2` 是纯结构判定，从不读 authority generation，
  # 不存在"因签名/generation 变化而丢 cap"这回事（撤回详情见 identity.ex 里
  # `maybe_add_recipe_binding_git_identity_wipe/4` 上方的 HONEST STATUS 注释，
  # 以及 `read_ssh_key_cap_change?/2` 上方的大段行内注释）。今天唯一命中的真实
  # 机制是 `restore_structural_caps/3`，且只在反事实输入下才可达（见下面第二个
  # 测试的注释）。
  describe "sync_recipe_binding 整集替换 —— §6.2.1（#1693 未覆盖的缺口）" do
    # 真实端到端：走真实 RecipeCapBinding.sync_live/1 dispatch。这是绝大多数
    # reconcile 实际发生的样子——甚至在 recipe 内容真的发生变化时（agent-kind
    # cap 从 :read 换成 :destroy，证明 reconcile 真的在干活，不是空操作）
    # read_ssh_key 依然分毫不动，盘上的 key 也原样还在。这是"不变则不擦，
    # 零额外开销"的钉子测试——防止实现退化成"只要 sync_recipe_binding 跑过
    # 就无条件擦"。
    test "recipe binding 真实变化(agent-kind cap 被替换)时 read_ssh_key 不受影响，盘上 key 原样还在",
         ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      # issue_and_upsert 内部经 `Ezagent.Cap.issue({:admin, issuer_uri}, ...)`
      # 需要 admin 是活的（recipe_cap_binding_lifecycle_test.exs 的 setup 同样
      # 显式 spawn+await；本文件顶层 setup 只把 admin 当身份标记用，未起活）。
      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.admin)
      :ok = Ezagent.ReadyGate.await(ctx.admin, 5_000)

      assert {:ok, %{version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 ctx.agent_uri,
                 "reader",
                 ctx.admin,
                 [agent_kind_proposal(ctx.agent_uri, :read)]
               )

      assert :ok = RecipeCapBinding.sync_live(ctx.agent_uri)

      assert Enum.any?(
               Ezagent.Identity.list_caps_for(ctx.agent_uri),
               &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :read)
             )

      # 内容真实改变：version 2，:read → :destroy。
      assert {:ok, %{version: 2}} =
               RecipeCapBinding.issue_and_upsert(
                 ctx.agent_uri,
                 "reader",
                 ctx.admin,
                 [agent_kind_proposal(ctx.agent_uri, :destroy)]
               )

      assert :ok = RecipeCapBinding.sync_live(ctx.agent_uri)

      caps_after = Ezagent.Identity.list_caps_for(ctx.agent_uri)

      # recipe 部分真的变了 —— 不是空操作。
      refute Enum.any?(
               caps_after,
               &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :read)
             )

      assert Enum.any?(
               caps_after,
               &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :destroy)
             )

      # 但 read_ssh_key 分毫未动，盘上的 key 也原样还在。
      assert Enum.any?(
               caps_after,
               &(&1.behavior == UserSshIdentity and &1.action == :read_ssh_key)
             )

      assert File.exists?(key_path)
    end

    # "有 → 无"这个方向，逐一排查过全部会把 cap 写进 agent `:caps` 槽位的生产
    # 入口后（handle_absorb_cap/2、handle_grant_cap/2、
    # Ezagent.EntityCaps.grant/2 → handle_store_cap/2、
    # Ezagent.EntityCaps.persist/2 → handle_persist_caps/2），发现它们全部
    # 门在同一个结构性判据上（Ezagent.Cap.storable_for?/2 /
    # Ezagent.EntityCaps.issued_for?/2：已签名 + instance 具体 + grantee_uri ==
    # receiver），且这个判据不认 authority generation（那个检查 ——
    # Cap.Authority.current_target?/verify_current —— 只发生在真正 dispatch
    # 使用这条 cap 授权某个 action 的那一刻，不在 reconcile 里）。一条已经合法
    # absorb 进 agent 的 read_ssh_key cap，因此在 sync_recipe_binding 的
    # verified_set 重验时永远会再次通过；`restore_structural_caps/3` 的
    # old_binding_keys 也结构性地只可能装 kind: :agent 的 identity_key
    # （RecipeCapBinding.issue_and_upsert/4 在写入和读出两端都拒绝
    # cap.kind != :agent），而 identity_key/1 的第一个轴就是 kind，二者永远
    # 不会碰撞。也就是说：今天没有一条纯靠真实 dispatch 累积出来的路径，能让
    # 一条健康持有的 read_ssh_key 在 sync_recipe_binding 里消失。
    #
    # 因此这条改为直接调用真实、已导出的 handle_sync_recipe_binding/2（就是
    # RecipeCapBinding.sync_live/1 dispatch 到的同一个函数），只在一个输入上
    # 反事实：让 ctx[:read] 报告的 recipe_binding_keys 已经把 read_ssh_key
    # 的 identity_key 算作"旧 recipe binding 拥有"的一部分（真实场景中这个
    # 值只可能来自一次真实的 RecipeCapBinding fetch，结构上不可能包含它）。
    # 其余全部真实：真实 absorb 的 cap、真实落盘的 key、真实存在于 DB 的
    # RecipeCapBinding（version 1，agent-kind cap）、真实执行的
    # restore_structural_caps/3（因为它的 identity_key 确实在
    # old_binding_keys 里，被真实代码删掉）、真实的 wipe-effect 判定。最后
    # 按 runtime 的效果解释器对 `{:dispatch_after_commit, cmd}` 会做的方式
    # （`Router.dispatch/1`）应用返回的效果，钉住"消失 → dispatch 后清盘"这条
    # 因果链的后半段也是真的。
    #
    # B2' revoke-ordering fix（2026-08-04）—— 判据从"是同步 MFA effect"改成
    # "是 post-commit 的 dispatch"：`{:effect, {GitIdentityRuntime, :wipe},
    # _}` 曾经在 handler 内同步执行；现在这两个 helper 产出的是
    # `{:dispatch_after_commit, %Ezagent.Cmd{}}`，`Kind.Server` 只在父 slice
    # 提交后才跑（见 identity.ex 的 `wipe_git_identity_dispatch_after_commit/1`）。
    test "反事实前置态下 read_ssh_key 消失时，返回的 caps 与 effects 都反映延迟清理，dispatch 后盘上 key 真的没了",
         ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      cap = grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      {:ok, _} = Ezagent.SpawnRegistry.spawn(ctx.admin)
      :ok = Ezagent.ReadyGate.await(ctx.admin, 5_000)

      assert {:ok, %{version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 ctx.agent_uri,
                 "reader",
                 ctx.admin,
                 [agent_kind_proposal(ctx.agent_uri, :read)]
               )

      read_ssh_key_identity_key = Ezagent.Capability.identity_key(cap)

      rigged_ctx = %{
        caller: :vm_internal,
        self_uri: ctx.agent_uri,
        read: fn
          :caps, _default -> MapSet.new([cap])
          :recipe_binding_version, _default -> 0
          :recipe_binding_keys, _default -> MapSet.new([read_ssh_key_identity_key])
        end
      }

      assert {:ok, %{caps: after_caps}, effects} =
               IdentityAdmin.handle_sync_recipe_binding(%{}, rigged_ctx)

      # read_ssh_key 真的从返回的 caps 里消失了（restore_structural_caps/3
      # 真实执行的 removal，不是我在测试里手动摘掉的）。
      refute Enum.any?(
               after_caps,
               &(&1.behavior == UserSshIdentity and &1.action == :read_ssh_key)
             )

      # recipe 部分确实真实生效了（version 1 的 agent-kind cap 进来了）——
      # 证明这不是一次"什么都没读到"的空 reconcile。
      assert Enum.any?(
               after_caps,
               &(&1.behavior == Ezagent.ActionSet.Sandbox and &1.action == :read)
             )

      assert wipe_effect =
               Enum.find(
                 effects,
                 &match?({:dispatch_after_commit, %Ezagent.Cmd{action: :wipe_git_identity}}, &1)
               )

      assert {:dispatch_after_commit, %Ezagent.Cmd{} = cmd} = wipe_effect
      assert cmd.action == :wipe_git_identity
      assert Ezagent.URI.instance(cmd.target) == Ezagent.URI.instance(ctx.agent_uri)

      # 手动按 runtime 的效果解释器对 `{:dispatch_after_commit, cmd}` 会做的
      # 方式应用返回的效果——`Ezagent.Kind.DeferredDispatch.run/1` 对每个
      # deferred cmd 就是调 `Router.dispatch/1`（这里跳过它的
      # force-fire-and-forget 包装 + `with_admin_operator` 包装，因为两者
      # 对这个 cmd 的 ctx 形状都是 no-op —— `mode` 已经由 `ctx.reply: :ignore`
      # 派生成 `:cast`，`authenticated_principal` 不是 canonical admin）——
      # 钉住"消失 → dispatch 后盘上 key 真的被清"这半条链路。`:cast` 的
      # dispatch 在目标 Kind 的下一个 turn 才真正跑 handler，所以用
      # `wait_until` 等，不用 `Process.sleep` 硬等。
      assert :ok = Ezagent.Router.dispatch(cmd)
      Ezagent.LifecycleCase.wait_until(fn -> not File.exists?(key_path) end)
    end
  end

  # brief 的 escape hatch："指向 A → 指向 B"这条端到端难构造（recipe 通道结构上
  # 铸不出指向 User 的 cap，见上面 describe block 的大段行内注释），因此直接单测
  # identity.ex 里导出的纯比较 seam `IdentityAdmin.read_ssh_key_cap_change?/2`。
  # 这组测试不 dispatch、不落盘，只钉住比较语义本身——"有→无"/"无→有"/"A→B"都
  # 判定为变了，同一条 cap 原样两边都在则判定为不变，且只看 read_ssh_key 这一个
  # behavior/action 组合、不被其它无关 cap 干扰。
  describe "read_ssh_key_cap_change?/2 —— §6.2.1 纯比较 seam 直接单测" do
    test "两边都不含 read_ssh_key —— 不变" do
      refute IdentityAdmin.read_ssh_key_cap_change?(MapSet.new(), MapSet.new())
    end

    test "有 → 无 —— 变了", ctx do
      cap = bare_read_ssh_key_cap(ctx.user_uri, ctx.user_uri)
      assert IdentityAdmin.read_ssh_key_cap_change?(MapSet.new([cap]), MapSet.new())
    end

    test "无 → 有 —— 变了", ctx do
      cap = bare_read_ssh_key_cap(ctx.user_uri, ctx.user_uri)
      assert IdentityAdmin.read_ssh_key_cap_change?(MapSet.new(), MapSet.new([cap]))
    end

    test "同一条 cap 两边都在 —— 不变（钉住：不能退化成无条件擦）", ctx do
      cap = bare_read_ssh_key_cap(ctx.user_uri, ctx.user_uri)
      refute IdentityAdmin.read_ssh_key_cap_change?(MapSet.new([cap]), MapSet.new([cap]))
    end

    # codex 复审(PR #1695)指出：上面那条测试两侧放的是**同一个 struct**（同一个
    # `cap` 变量），只证明了"x == x"，证明不了任何关于 identity-key 比较语义的
    # 事情——把实现悄悄换成比较过滤后的原始 `%Capability{}`/`MapSet`（而不是
    # `identity_key/1`）也一样全绿。这条补上真正的反例：两侧是**不同的 struct**
    # （signature/key_id 不同，因此原始 struct 不相等），但 identity_key 的五个轴
    # （kind/behavior/action/instance/workspace_uri）完全相同——模拟同一条逻辑 cap
    # 被重新签发（例如 authority 重签名）后的样子。前两个 assert 钉住"这确实是一对
    # 合法反例"（不是同一个 term，但 identity_key 相同），第三个 assert 才是真正
    # 要保的性质：重签名不算变化，不触发 wipe。
    test "同一条逻辑 cap 换了 signature/key_id（重签名）—— 不变（钉住：比较的是 identity_key，不是原始 struct）",
         ctx do
      base = bare_read_ssh_key_cap(ctx.user_uri, ctx.user_uri)
      resigned_a = %{base | signature: "sig-a", key_id: "key-a"}
      resigned_b = %{base | signature: "sig-b", key_id: "key-b"}

      # 前置条件：两侧确实是不同的 struct（否则这条测试退化回上面那条）。
      refute resigned_a == resigned_b

      # 前置条件：但 identity_key 的五个轴相同（signature/key_id 不参与
      # identity_key，见 capability/match.ex 的 identity_key/1 moduledoc）。
      assert Ezagent.Capability.identity_key(resigned_a) ==
               Ezagent.Capability.identity_key(resigned_b)

      refute IdentityAdmin.read_ssh_key_cap_change?(
               MapSet.new([resigned_a]),
               MapSet.new([resigned_b])
             )
    end

    test "指向 User A → 指向 User B —— 变了（brief 的 escape hatch 覆盖这条）", ctx do
      suffix = System.unique_integer([:positive])
      other_user_uri = Ezagent.URI.entity(:gitid, :user, "owner-b-#{suffix}")
      refute Ezagent.URI.instance(other_user_uri) == Ezagent.URI.instance(ctx.user_uri)

      cap_a = bare_read_ssh_key_cap(ctx.user_uri, ctx.user_uri)
      cap_b = bare_read_ssh_key_cap(other_user_uri, ctx.user_uri)

      assert IdentityAdmin.read_ssh_key_cap_change?(MapSet.new([cap_a]), MapSet.new([cap_b]))
    end

    test "不相关的 cap（其它 behavior/action）不参与比较，也不掩盖真正的变化", ctx do
      read_cap = bare_read_ssh_key_cap(ctx.user_uri, ctx.user_uri)

      public_key_cap = %{
        read_cap
        | action: :read_ssh_public_key
      }

      # 无关 cap 两边都在、read_ssh_key 两边都在 —— 不变。
      refute IdentityAdmin.read_ssh_key_cap_change?(
               MapSet.new([read_cap, public_key_cap]),
               MapSet.new([read_cap, public_key_cap])
             )

      # 无关 cap 消失但 read_ssh_key 还在 —— 不该被无关 cap 的变化误报成变了。
      refute IdentityAdmin.read_ssh_key_cap_change?(
               MapSet.new([read_cap, public_key_cap]),
               MapSet.new([read_cap])
             )

      # read_ssh_key 本身消失，即使无关 cap 还在 —— 必须判定为变了。
      assert IdentityAdmin.read_ssh_key_cap_change?(
               MapSet.new([read_cap, public_key_cap]),
               MapSet.new([public_key_cap])
             )
    end
  end
end
