defmodule Ezagent.World.AgentCreateAppearsInListTest do
  @moduledoc """
  Anti-stub regression gate (PR #905 / task-2).

  The test that #904 lacked: a created agent must ACTUALLY appear in
  `IdentityData.list_entities/2` — not just "the form rendered". If
  `create_agent` is stubbed or fails silently this test FAILS because
  the agent URI will be absent from the list.

  Uses the same DataCase + workspace/admin-caps fixtures as
  `create_agent_dispatch_test.exs` in ezagent_domain_workspace.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.World.IdentityData

  setup do
    # Start the session domain so the `entity` SpawnRegistry scheme is
    # registered (same pattern as create_agent_dispatch_test.exs).
    # Hard-assert: if these fail, the test environment is broken — surface loudly.
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
           "entity spawn scheme not registered after starting :ezagent_domain_session — " <>
             "bootstrap is incomplete; fix the test environment rather than silently skipping"

    # Mirror create_agent_dispatch_test.exs setup exactly.
    ws_name = "world-create-list-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "create_agent → list_entities structural gate" do
    @tag :integration
    test "created agent URI appears in list_entities(workspace_uri, 'agents')",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      agent_name = "list-probe-#{System.unique_integer([:positive])}"

      # Create the agent through the SAME facade the world dispatch calls.
      # Using `curl` flavor: direct-spawn, no template class required, no cwd.
      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: agent_name, cwd: "", with_pty: false},
                 admin_ctx
               )

      expected_uri_str = URI.to_string(agent_uri)

      # The created agent must appear in the list — this is the structural gate.
      # list_entities reads from KindRegistry (live processes), not the DB,
      # so an actually-spawned agent is present; a stub that returns {:ok, _}
      # without spawning would NOT appear here, failing this assertion.
      agent_rows = IdentityData.list_entities(workspace_uri, "agents")
      listed_uris = Enum.map(agent_rows, & &1["uri"])

      assert expected_uri_str in listed_uris,
             "created agent #{expected_uri_str} is absent from list_entities — " <>
               "create path is stubbed or the agent was not registered in KindRegistry. " <>
               "Listed URIs: #{inspect(listed_uris)}"

      # Bonus: the returned row shape matches the documented contract.
      row = Enum.find(agent_rows, &(&1["uri"] == expected_uri_str))

      assert row["kind"] == "agent"
      assert row["name"] == agent_name
      assert is_binary(row["flavor"])
      assert is_boolean(row["alive"])

      # Sanity: the workspace filter works — the agent appears under
      # "agents" but NOT under "users".
      listed_user_uris =
        IdentityData.list_entities(workspace_uri, "users")
        |> Enum.map(& &1["uri"])

      refute expected_uri_str in listed_user_uris,
             "agent URI should not appear in the 'users' filter"

      # Cross-workspace isolation: list against a different workspace URI
      # must NOT include the agent created in `workspace_uri`.
      other_ws_uri = URI.new!("workspace://other-ws-#{System.unique_integer([:positive])}")

      other_listed =
        IdentityData.list_entities(other_ws_uri, "agents")
        |> Enum.map(& &1["uri"])

      refute expected_uri_str in other_listed,
             "agent from #{ws_name} should not appear under a different workspace"

      # Confirm workspace scoping — the agent URI contains our workspace name.
      assert String.contains?(expected_uri_str, ws_name),
             "agent URI should contain the workspace name '#{ws_name}'"
    end
  end

  describe "project_cwd default path is real (not blocked by stale UI-only validation)" do
    test "cc flavor with empty cwd creates through the workspace facade",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {:ok, _apps} = Application.ensure_all_started(:ezagent_plugin_cc)

      # A workspace-shared cc credential source with a real `.credentials.json`,
      # so the created agent's config home is LAUNCHABLE. Since chain B / #1096, a
      # credentialled cc flavor FAILS FAST at launch without a credential; this
      # test probes the empty-cwd default path, not credential-absence, so it
      # stands in a "logged-in" state.
      seed_ws_cc_credential_source(ws_name, workspace_uri)

      assert {:ok, %{agent_uri: %URI{} = agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "no-cwd-probe-#{System.unique_integer([:positive])}",
                   cwd: "",
                   with_pty: false
                 },
                 admin_ctx
               )

      assert agent_uri.path =~ "/agent/no-cwd-probe-"
    end
  end

  # Register a workspace-shared cc credential source carrying a real
  # `.credentials.json` so a bare admin cc create materializes a LAUNCHABLE
  # per-agent home (chain B / #1096 fail-fast otherwise).
  defp seed_ws_cc_credential_source(ws_name, workspace_uri) do
    src_dir =
      Path.join(System.tmp_dir!(), "cc-ws-cred-src-#{System.unique_integer([:positive])}")

    File.mkdir_p!(src_dir)

    File.write!(
      Path.join(src_dir, ".credentials.json"),
      ~s({"claudeAiOauth":{"accessToken":"T"}})
    )

    on_exit(fn -> File.rm_rf(src_dir) end)

    source_uri =
      URI.new!(
        "entity://#{ws_name}/agent/cc_ws-cred-source-#{System.unique_integer([:positive])}"
      )

    {:ok, _} =
      Ezagent.SnapshotStore.write(
        URI.to_string(source_uri),
        %{sandbox: %{state: %{config_dir_path: src_dir, flavor: "cc"}}},
        kind_type: :agent
      )

    {:ok, _} =
      %{
        workspace_uri: URI.to_string(workspace_uri),
        flavor: "cc",
        source_uri: URI.to_string(source_uri),
        set_by: URI.to_string(User.admin_uri())
      }
      |> Ezagent.Credential.WorkspaceSharedSource.changeset()
      |> EzagentCore.Repo.insert()

    source_uri
  end
end
