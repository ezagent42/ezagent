defmodule Ezagent.PluginCc.Template.GitIdentityWiringTest do
  @moduledoc """
  SSH 凭据 1b (Task 5 复审 J2/M1) — pins that the two production seams
  (`SpawnPlan.build_claude_cmd/3` for PTY, `CcHeadlessAgent.sdk_sidecar_params/2`
  for headless) actually WIRE `Ezagent.Identity.AgentGitIdentity.materialize/1`
  into the agent's launch env, not just that the pure helper
  `SpawnPlan.merge_git_identity_env/2` behaves correctly in isolation
  (`git_identity_env_test.exs` already covers that).

  复审实测:删掉两条 seam(`spawn_plan.ex:156-158` /
  `cc_headless_agent.ex:421-424`)整段,`git_identity_env_test.exs` 的四条纯函数
  测试全绿,全套 `ezagent_plugin_cc` 测试也全绿(4 red,严格是未改动基线 5 red
  的子集)——没有任何测试因为接线被拆掉而变红。

  关闭态(无 cap)断言在这里**不能**证明这件事:`merge_git_identity_env(env,
  {:ok, :none})` 本来就把 `env`原样传回,删掉整条 seam 之后关闭态的
  `cmd_env`/`params.cmd_env` 跟 seam 还在时逐字节相同——关闭态测试对"整段删掉"
  这个破坏没有区分力。只有开启态(真实 cap + 真实 User key)的断言,在 seam
  被删掉后会从"有 GIT_SSH_COMMAND"变成"没有",因此本文件同时覆盖两态:关闭态
  钉住设计 §8 ⑥ 的逐字节不变验收项(M1 — PTY 侧此前无任何等价断言,headless
  侧靠既有 `cc_custom_backend_test.exs` 的 `map_size`/`== %{}` 断言顺带钉住),
  开启态钉住"seam 真的在跑"这件事本身(J2 的唯一意义)。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Identity.AgentGitIdentity
  alias Ezagent.PluginCc.Template.{CcAgent, CcHeadlessAgent}
  alias Ezagent.Sandbox.GitIdentityDir
  alias Mix.Tasks.Ezagent.Agent.GrantGitIdentity

  setup do
    suffix = System.unique_integer([:positive])
    workspace_name = "gitidcc-#{suffix}"
    user_uri = Ezagent.URI.user(workspace_name, "owner-#{suffix}")
    agent_uri = Ezagent.URI.agent(workspace_name, "worker-#{suffix}")

    {:ok, _} = Ezagent.Users.create(user_uri, nil, [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
    {:ok, _} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})

    # known_hosts — required by `GitIdentityRuntime.write/2` before any key
    # material is allowed to land on disk (design §6.1 point 2).
    kh_dir = Path.join(System.tmp_dir!(), "ezagent-cc-gitid-kh-#{suffix}")
    File.mkdir_p!(kh_dir)
    kh_path = Path.join(kh_dir, "known_hosts")
    File.write!(kh_path, "github.com ssh-ed25519 AAAAFAKE\n")

    prev_kh = Application.get_env(:ezagent_core, :git_known_hosts_path)
    Application.put_env(:ezagent_core, :git_known_hosts_path, kh_path)

    # PTY's `build_claude_cmd/3` unconditionally resolves + probes a `claude`
    # executable before it ever reaches the git-identity seam — irrelevant to
    # the git-identity cap state, but required for BOTH the closed and open
    # state PTY tests to reach the seam at all. Mirrors the proven setup in
    # `cc_custom_backend_test.exs`'s "pty launch env" describe block.
    bin_dir = Path.join(System.tmp_dir!(), "ezagent-cc-gitid-bin-#{suffix}")
    File.mkdir_p!(bin_dir)
    claude = Path.join(bin_dir, "claude")
    File.write!(claude, "#!/usr/bin/env bash\nexit 0\n")
    File.chmod!(claude, 0o755)

    prev_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (prev_path || ""))

    config_dir = Path.join(bin_dir, "config")
    cwd = Path.join(bin_dir, "cwd")
    File.mkdir_p!(config_dir)
    File.mkdir_p!(cwd)

    prev_mcp = Application.get_env(:ezagent_plugin_cc, :mcp_config_dir)
    Application.put_env(:ezagent_plugin_cc, :mcp_config_dir, Path.join(bin_dir, "mcp"))

    prev_ws = System.get_env("EZAGENT_BRIDGE_WS_URL")
    System.put_env("EZAGENT_BRIDGE_WS_URL", "ws://127.0.0.1:65535/agent_bridge/websocket")

    _authority = install_test_authority!(agent_uri, :agent)

    on_exit(fn ->
      if prev_kh,
        do: Application.put_env(:ezagent_core, :git_known_hosts_path, prev_kh),
        else: Application.delete_env(:ezagent_core, :git_known_hosts_path)

      if prev_path, do: System.put_env("PATH", prev_path), else: System.delete_env("PATH")

      if prev_ws,
        do: System.put_env("EZAGENT_BRIDGE_WS_URL", prev_ws),
        else: System.delete_env("EZAGENT_BRIDGE_WS_URL")

      if prev_mcp,
        do: Application.put_env(:ezagent_plugin_cc, :mcp_config_dir, prev_mcp),
        else: Application.delete_env(:ezagent_plugin_cc, :mcp_config_dir)

      File.rm_rf(kh_dir)
      File.rm_rf(bin_dir)
      File.rm_rf(GitIdentityDir.path(agent_uri))
      Ezagent.Kind.terminate(user_uri)
      Ezagent.Kind.terminate(agent_uri)
    end)

    %{
      user_uri: user_uri,
      agent_uri: agent_uri,
      admin: Ezagent.Entity.User.admin_uri(),
      cwd: cwd,
      config_dir: config_dir
    }
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

  defp tmpl(ctx) do
    %{
      "class" => "cc.agent",
      "agent_uri" => URI.to_string(ctx.agent_uri),
      "cwd" => ctx.cwd,
      "agent_config_dir" => ctx.config_dir
    }
  end

  describe "关闭态(无 read_ssh_key cap)—— 设计 §8 ⑥:两条 cmd_env 构建路径逐字节不变" do
    test "PTY: build_claude_cmd/3 不带 GIT_SSH_COMMAND", ctx do
      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(ctx.agent_uri, ctx.cwd, tmpl(ctx))
      refute Map.has_key?(cmd_env, "GIT_SSH_COMMAND")
    end

    test "headless: sdk_sidecar_params/2 不带 GIT_SSH_COMMAND", ctx do
      params = CcHeadlessAgent.sdk_sidecar_params(ctx.agent_uri, %{"cwd" => ctx.cwd})
      refute Map.has_key?(params.cmd_env, "GIT_SSH_COMMAND")
    end
  end

  describe "开启态(持 read_ssh_key cap 且 User 有 key)—— seam 真的在跑" do
    setup ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      assert {:ok, _cap} = GrantGitIdentity.grant(ctx.agent_uri, ctx.user_uri)

      # Confirm the identity domain itself is ready to materialize before
      # blaming the cc plugin's own seam for a miss — isolates "cc plugin
      # doesn't wire it" (this file's concern) from "1a/1b identity domain
      # itself is broken" (covered by `agent_git_identity_test.exs`).
      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      :ok
    end

    test "PTY: build_claude_cmd/3 拿到指向该 agent 自己 git-identity 目录的 GIT_SSH_COMMAND", ctx do
      assert {:ok, {_argv, cmd_env}} = CcAgent.build_claude_cmd(ctx.agent_uri, ctx.cwd, tmpl(ctx))
      assert cmd_env["GIT_SSH_COMMAND"] =~ "ssh -i "
      assert cmd_env["GIT_SSH_COMMAND"] =~ GitIdentityDir.path(ctx.agent_uri)
    end

    test "headless: sdk_sidecar_params/2 拿到指向该 agent 自己 git-identity 目录的 GIT_SSH_COMMAND",
         ctx do
      params = CcHeadlessAgent.sdk_sidecar_params(ctx.agent_uri, %{"cwd" => ctx.cwd})
      assert params.cmd_env["GIT_SSH_COMMAND"] =~ "ssh -i "
      assert params.cmd_env["GIT_SSH_COMMAND"] =~ GitIdentityDir.path(ctx.agent_uri)
    end
  end
end
