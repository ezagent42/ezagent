defmodule Mix.Tasks.Ezagent.Agent.GrantGitIdentityTest do
  # async: false + EzagentCore.DataCase, not plain ExUnit.Case —— confirmed
  # against `agent_git_identity_test.exs`'s own documented finding: this app's
  # `test_helper.exs` sets the `EzagentCore.Repo` sandbox to `:manual`, so any
  # DB-touching setup (`Ezagent.Users.create/3` here) needs an explicit
  # checkout, which plain `ExUnit.Case` does not provide (crashes with
  # `DBConnection.OwnershipError`). `DataCase` also `Sandbox.allow/3`s the
  # connection to Kind processes spawned during the test — required because
  # `grant/2` dispatches into the live User Kind.
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Identity.AgentGitIdentity
  alias Ezagent.Identity.Test.GitIdentityFixtureAgentKind
  alias Mix.Tasks.Ezagent.Agent.GrantGitIdentity

  setup do
    suffix = System.unique_integer([:positive])
    user_uri = Ezagent.URI.entity(:gitid, :user, "owner-g#{suffix}")
    agent_uri = Ezagent.URI.entity(:gitid, :agent, "worker-g#{suffix}")

    {:ok, _} = Ezagent.Users.create(user_uri, nil, [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)

    # A bare `entity://.../agent/...` URI that was never spawned resolves
    # `:no_such_actor` when `absorb_cap/2` tries to deliver to it (confirmed
    # empirically by Task 3 — no live process AND no snapshot row, which is
    # different from "not ready yet"). `ezagent_domain_identity` does not
    # depend on `ezagent_domain_agent`, so it cannot spawn a real
    # `Ezagent.Entity.Agent` — reuse the same test-support fixture Kind Task 3
    # already built for exactly this purpose.
    {:ok, _} =
      Ezagent.Kind.spawn(GitIdentityFixtureAgentKind, %{uri: agent_uri, initial_caps: []})

    on_exit(fn ->
      Ezagent.Kind.terminate(user_uri)
      Ezagent.Kind.terminate(agent_uri)
    end)

    %{user_uri: user_uri, agent_uri: agent_uri}
  end

  describe "参数解析" do
    test "少于两个参数时报错" do
      assert {:error, :usage} = GrantGitIdentity.plan([])
      assert {:error, :usage} = GrantGitIdentity.plan(["entity://ws/agent/a"])
    end

    test "第一个参数必须是 agent URI" do
      assert {:error, {:not_an_agent_uri, _}} =
               GrantGitIdentity.plan(["entity://ws/user/u", "entity://ws/user/u"])
    end

    test "第二个参数必须是 user URI" do
      assert {:error, {:not_a_user_uri, _}} =
               GrantGitIdentity.plan(["entity://ws/agent/a", "entity://ws/agent/b"])
    end

    test "合法参数解析出两个 URI，且各自落进对的 key（不是形状-only）" do
      # M1（Task 5 复审）：原断言只钉形状（`%{agent: %URI{}, user: %URI{}}`），
      # 把 plan/1 的返回改成 `%{agent: user, user: agent}`（key 对调）四条
      # 参数解析测试依旧全绿。直接断言两个具体 URI，钉住"哪个解析结果落进
      # 哪个 key"。
      assert {:ok, %{agent: agent, user: user}} =
               GrantGitIdentity.plan(["entity://ws/agent/a", "entity://ws/user/u"])

      assert agent == Ezagent.URI.new!("entity://ws/agent/a")
      assert user == Ezagent.URI.new!("entity://ws/user/u")
    end
  end

  describe "发放" do
    test "发完后 agent 恰好多出那一条 cap，且 instance 指向该 user", ctx do
      before = Ezagent.Identity.list_caps_for(ctx.agent_uri)

      assert {:ok, cap} = GrantGitIdentity.grant(ctx.agent_uri, ctx.user_uri)

      after_caps = Ezagent.Identity.list_caps_for(ctx.agent_uri)
      added = MapSet.difference(after_caps, before) |> MapSet.to_list()

      assert [^cap] = added
      assert cap.behavior == UserSshIdentity
      assert cap.action == :read_ssh_key
      assert cap.kind == :user
      assert cap.instance == Ezagent.URI.instance(ctx.user_uri)

      # M7（Task 5 复审）：`MapSet.difference` 只查增不查删 —— 一个顺手删掉
      # 别的 cap 的 grant/2 仍会让上面的断言全绿。钉住 held set 的总数恰好
      # +1，不只是"新增的那条形状对"。
      assert MapSet.size(after_caps) == MapSet.size(before) + 1
    end

    test "发放后 AgentGitIdentity 认得这条 cap（与 Task 3 的选择器对齐）", ctx do
      {:ok, cap} = GrantGitIdentity.grant(ctx.agent_uri, ctx.user_uri)

      assert [^cap] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)
    end
  end

  describe "冲突检测（Task 3 复审追加要求）" do
    test "已指向别的 user 时拒绝再发，且不改动已持有的 cap", ctx do
      other_user_uri =
        Ezagent.URI.entity(:gitid, :user, "other-owner-g#{System.unique_integer([:positive])}")

      assert {:ok, first_cap} = GrantGitIdentity.grant(ctx.agent_uri, ctx.user_uri)

      assert {:error, {:conflicting_git_identity, existing}} =
               GrantGitIdentity.grant(ctx.agent_uri, other_user_uri)

      assert existing == [Ezagent.URI.instance(ctx.user_uri)]

      # Refused, not partially applied: the agent still holds exactly the
      # original cap, unchanged, and nothing pointing at the second user.
      assert [^first_cap] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)
    end

    test "重复发放给同一个 user 是幂等的 —— 不算冲突，held set 仍恰好一条", ctx do
      assert {:ok, _cap1} = GrantGitIdentity.grant(ctx.agent_uri, ctx.user_uri)
      assert {:ok, cap2} = GrantGitIdentity.grant(ctx.agent_uri, ctx.user_uri)

      assert [held] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)
      assert held.instance == Ezagent.URI.instance(ctx.user_uri)
      assert held == cap2
    end
  end

  describe "phantom user（Task 5 复审 H3）" do
    test "user_uri 从未 Users.create 时拒绝发放，不静默铸出 phantom User Kind", ctx do
      phantom_user_uri =
        Ezagent.URI.entity(:gitid, :user, "phantom-#{System.unique_integer([:positive])}")

      assert {:error, {:user_not_startable, :not_created}} =
               GrantGitIdentity.grant(ctx.agent_uri, phantom_user_uri)

      # Refused before ever absorbing anything — the agent holds no cap
      # pointing at the phantom URI.
      assert [] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)

      # And no phantom Kind was left alive for the next test/process to trip
      # over.
      refute Ezagent.LocalRuntime.kind_alive?(phantom_user_uri)
    end
  end
end
