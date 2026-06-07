defmodule Ezagent.PluginCc.Template.CcUnifiedCreateCascadeTest do
  @moduledoc """
  Regression for the silent-degrade where a file-flavor (cc/codex) agent
  created via the UNIFIED operator create — `Ezagent.Workspace.create_agent/3`
  with NO `--from` — got no isolated per-agent config home and never resolved
  the #17 credential cascade, silently sharing the operator's `~/.claude`.

  Design note: `docs/superpowers/notes/2026-06-07-file-flavor-create-cascade-fix.md`.

  The unified path went `Behavior.Workspace.:create_agent → do_create_agent("cc",…)
  → register_and_invoke_template → Loader.invoke_template → provision_and_instantiate`
  and NEVER through `Agent.spawn_from_template_content/5` (the sole cascade
  chokepoint). The bare-create template omitted the `"config_dir"` reference key
  (added only by `maybe_put_clone_source` on `--from`), so:

    * `provision_and_instantiate` skipped config_dir allocation
      (`template.ex:305-306` gates on the `"config_dir"` key), and
    * `CcAgent.resolve_config_home/2` fell to clause 4 → `nil` →
      `CLAUDE_CONFIG_DIR` unset → claude uses operator `~/.claude`.

  These tests are at the persisted-template + config-home layer (no real
  `claude` subprocess needed): the structural precondition for BOTH isolation
  and cascade is that the persisted file-flavor template carries a non-empty
  `config_dir` reference. That precondition is missing today and is what the fix
  restores — and the boot loader replays the SAME persisted template, so a
  persisted `config_dir` is also what lets cold restart re-resolve.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Workspace.Store
  alias Ezagent.Entity.User
  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.Credential.{GrantRow, WorkspaceSharedSource}
  alias EzagentCore.Repo

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_instance_message)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "cc-unified-create-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }

    cwd = System.tmp_dir!()

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx, cwd: cwd}
  end

  # The persisted file-flavor template for the just-created agent.
  defp persisted_template(ws_name, agent_uri) do
    %{session_templates: tmpls} = Store.get_by_name(ws_name)

    name = name_of(agent_uri)

    tmpls
    |> Enum.find_value(fn {_tmpl_name, tmpl} ->
      if config_agent_uri(tmpl) == URI.to_string(agent_uri) or
           String.contains?(config_agent_uri(tmpl) || "", name),
         do: tmpl
    end)
  end

  defp config_agent_uri(tmpl), do: Map.get(tmpl, "agent_uri")

  defp name_of(%URI{} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, n} -> n
      :error -> URI.to_string(uri)
    end
  end

  describe "bare cc create (no --from) — isolation precondition" do
    test "persisted template carries a non-empty config_dir reference (NOT operator ~/.claude)",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx, cwd: cwd} do
      name = "isolated-#{System.unique_integer([:positive])}"

      {:ok, %{agent_uri: agent_uri}} =
        Workspace.create_agent(
          workspace_uri,
          %{flavor: "cc", name: name, cwd: cwd, with_pty: false},
          admin_ctx
        )

      on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(agent_uri)) end)

      tmpl = persisted_template(ws_name, agent_uri)

      assert is_map(tmpl), "expected a persisted template for #{URI.to_string(agent_uri)}"

      config_ref = Map.get(tmpl, "config_dir")

      assert is_binary(config_ref) and config_ref != "",
             "bare cc create must persist a config_dir reference so the agent gets an " <>
               "isolated CLAUDE_CONFIG_DIR (and the cascade can fire); got: " <>
               inspect(config_ref)
    end

    test "resolved config home for the persisted template is non-nil (isolated dir)",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx, cwd: cwd} do
      name = "home-#{System.unique_integer([:positive])}"

      {:ok, %{agent_uri: agent_uri}} =
        Workspace.create_agent(
          workspace_uri,
          %{flavor: "cc", name: name, cwd: cwd, with_pty: false},
          admin_ctx
        )

      on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(agent_uri)) end)

      tmpl = persisted_template(ws_name, agent_uri)
      assert is_map(tmpl)

      home = CcAgent.resolve_config_home(agent_uri, tmpl)

      refute is_nil(home),
             "a file-flavor agent created via the unified path must resolve a non-nil, " <>
               "isolated config home — nil means it silently shares operator ~/.claude " <>
               "(feedback_let_it_crash_no_workarounds)"

      assert home == CcAgent.agent_config_dir(agent_uri),
             "the resolved home must be the per-agent target derived from the agent URI"
    end
  end

  describe "bare cc create — #17 cascade resolution + grant mint" do
    test "a workspace-shared credential source is resolved + a member grant is minted",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx, cwd: cwd} do
      # A workspace-shared source the creating user does NOT hold a read
      # cap for — the #17 cascade's workspace-shared approval path
      # (`maybe_mint_workspace_shared_grant`) must still mint a member grant.
      flavor = "cc"

      source_uri =
        URI.new!(
          "entity://#{ws_name}/agent/cc_shared-source-#{System.unique_integer([:positive])}"
        )

      admin_uri = User.admin_uri()

      {:ok, _} =
        Ezagent.SnapshotStore.write(
          source_uri,
          %{sandbox: %{state: %{config_dir_path: System.tmp_dir!()}}},
          kind_type: :agent
        )

      {:ok, _row} =
        %{
          workspace_uri: URI.to_string(workspace_uri),
          flavor: flavor,
          source_uri: URI.to_string(source_uri),
          set_by: URI.to_string(admin_uri)
        }
        |> WorkspaceSharedSource.changeset()
        |> Repo.insert()

      name = "cred-#{System.unique_integer([:positive])}"

      {:ok, %{agent_uri: agent_uri}} =
        Workspace.create_agent(
          workspace_uri,
          %{flavor: flavor, name: name, cwd: cwd, with_pty: false},
          admin_ctx
        )

      on_exit(fn -> File.rm_rf(CcAgent.agent_config_dir(agent_uri)) end)

      row = GrantRow.get_for_agent(URI.to_string(agent_uri))

      assert %GrantRow{} = row,
             "the unified create must resolve the #17 cascade and mint a grant " <>
               "for the workspace-shared credential source — got nil (cascade did not fire)"

      assert row.credential_source_uri == URI.to_string(source_uri)
    end
  end

  describe "fail-loud — no silent operator ~/.claude fallback" do
    test "a file-flavor whose persisted template lacks config_dir fails the cascade spawn (no nil home)",
         %{workspace_uri: workspace_uri} do
      # Directly exercise the cascade-spawn seam's no-silent-fallback guard:
      # a file-flavor content map missing config_dir must NOT spawn (which
      # would leave CLAUDE_CONFIG_DIR unset → operator ~/.claude). The unified
      # create makes config_dir unconditional, so this drives the guard via
      # the spawn facade directly with a deliberately-incomplete content map.
      content = %{flavor: "cc", project_cwd: System.tmp_dir!()}

      agent_uri =
        Ezagent.URI.agent(
          Ezagent.URI.workspace_name!(workspace_uri),
          "noconfig-#{System.unique_integer([:positive])}"
        )

      # spawn_from_template_content with a cc flavor but no config_dir and no
      # source_template_uri → default_cascade_configured?(:file,...) is false,
      # so no cascade fires; the agent would get no isolated home. The cc
      # plugin's resolve_config_home returns nil for an absent config_dir →
      # the consume path must not silently share the operator home. We assert
      # the persisted-template builder NEVER produces this shape for a
      # file-flavor (config_dir is always present), and that to_cascade_content
      # rejects a missing config_dir.
      assert {:error, :missing_config_dir} =
               Ezagent.Behavior.Workspace.__cascade_content_for_test__(%{
                 "class" => "cc.agent",
                 "flavor" => "cc",
                 "project_cwd" => System.tmp_dir!()
               })

      # And the builder for a real create ALWAYS includes config_dir:
      tmpl =
        Ezagent.Behavior.Workspace.__file_flavor_template_for_test__(
          "cc",
          "cc.agent",
          agent_uri,
          System.tmp_dir!()
        )

      assert is_binary(Map.get(tmpl, "config_dir")) and Map.get(tmpl, "config_dir") != "",
             "file_flavor_template must always carry a config_dir reference"

      _ = content
    end
  end
end
