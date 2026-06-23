defmodule Ezagent.PluginCc.Template.CcSoulToClaudeMdE2eTest do
  @moduledoc """
  B4: E2E proof that a cc agent created with `soul:` has the soul text in
  the CLAUDE.md file written to its per-agent config dir on disk.

  The chain under test (B1 → B2 → B3 → here):

    Workspace.create_agent(..., %{soul: "..."})
      ↓ Behavior.Workspace.AgentCreate.do_create_agent/4
      ↓ manifest_cc_tmpl/3 → AgentManifest → :agent_manifest_resolved.instructions
      ↓ spawn_file_flavor_via_cascade/4 → to_cascade_content/1 (passes :agent_manifest_resolved)
      ↓ Entity.Agent.spawn_from_template_content/5
      ↓ AgentTemplate.to_template_data/2 → compile_cc_agent_data → tmpl["claude_md"]
      ↓ CcAgent.instantiate/3 → spawn_for_local_pty/3 → create_agent_config_dir_with_grant/2
      ↓ HomeRuntime.apply_derived_config/2
      ↓ File.write(Path.join(staging, "CLAUDE.md"), soul_text)   ← ASSERTED HERE

  No real `claude` subprocess: SpawnPlan.build_pty_params/4 short-circuits in
  `:test` env — CLAUDE.md is written before PTY launch and is present even
  when the PTY short-circuits.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.PluginCc.Template.CcAgent

  @soul_marker "SOUL_MARKER_B4 — 你是前台导购助手，简短友好地回答顾客问题。"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "soul-e2e-b4-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    cwd = System.tmp_dir!()

    {:ok, workspace_uri: workspace_uri, admin_ctx: admin_ctx, cwd: cwd}
  end

  @tag :integration
  @tag :b4_soul_e2e
  test "cc agent created with soul: has the soul text in CLAUDE.md on disk",
       %{workspace_uri: workspace_uri, admin_ctx: admin_ctx, cwd: cwd} do
    # Guard: skip when entity spawn is not registered (narrowly avoids a
    # confusing test failure on partial-bootstrap CI runs; the standard
    # cc integration tests use the same pattern).
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (bootstrap incomplete)")
      :ok
    else
      name = "soul-b4-#{System.unique_integer([:positive])}"

      result =
        Workspace.create_agent(
          workspace_uri,
          %{flavor: "cc", name: name, cwd: cwd, with_pty: false, soul: @soul_marker},
          admin_ctx
        )

      # Step 1: the create must succeed.
      assert {:ok, %{agent_uri: agent_uri}} = result,
             "create_agent with soul: should return {:ok, %{agent_uri: _}}; got: " <>
               inspect(result)

      on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(agent_uri)) end)

      # Step 2: find the per-agent config dir.
      config_dir = CcAgent.agent_config_dir(agent_uri)

      assert is_binary(config_dir) and config_dir != "",
             "agent_config_dir must be a non-empty path; got: #{inspect(config_dir)}"

      claude_md_path = Path.join(config_dir, "CLAUDE.md")

      assert File.exists?(claude_md_path),
             "CLAUDE.md must exist at #{claude_md_path} after create_agent with soul:; " <>
               "config_dir contents: #{inspect(list_dir(config_dir))}"

      # Step 3: the soul text must be in the file.
      {:ok, content} = File.read(claude_md_path)

      assert String.contains?(content, @soul_marker),
             "CLAUDE.md at #{claude_md_path} must contain the soul marker.\n" <>
               "Expected to find: #{inspect(@soul_marker)}\n" <>
               "CLAUDE.md content (first 500 chars):\n#{String.slice(content, 0, 500)}"
    end
  end

  @tag :integration
  @tag :b4_soul_e2e
  test "cc agent created WITHOUT soul: still creates the config dir (no regression)",
       %{workspace_uri: workspace_uri, admin_ctx: admin_ctx, cwd: cwd} do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (bootstrap incomplete)")
      :ok
    else
      name = "no-soul-b4-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "cc", name: name, cwd: cwd, with_pty: false},
                 admin_ctx
               )

      on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(agent_uri)) end)

      config_dir = CcAgent.agent_config_dir(agent_uri)

      assert File.dir?(config_dir),
             "soul-absent cc create must still produce a config_dir on disk; " <>
               "got: #{inspect(config_dir)}"

      # CLAUDE.md should NOT be written by the soul path (may or may not
      # exist depending on whether a bare reference dir has one — we only
      # assert the soul marker is NOT in it if the file exists).
      claude_md_path = Path.join(config_dir, "CLAUDE.md")

      if File.exists?(claude_md_path) do
        {:ok, content} = File.read(claude_md_path)

        refute String.contains?(content, @soul_marker),
               "soul-absent create must NOT write SOUL_MARKER_B4 into CLAUDE.md"
      end
    end
  end

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      _ -> []
    end
  end
end
