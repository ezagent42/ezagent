defmodule EzagentPluginLiveview.AutoDeriveLiveTest do
  @moduledoc """
  Phase 6 PR 10 — auto-derive LV smoke test.

  Validates the page mounts for any registered Kind without
  hand-written per-Kind code.
  """
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ezagent.Credential.GrantRow
  alias Ezagent.Credential.UserDefaultSource
  alias Ezagent.Invocation
  alias Ezagent.Users

  @endpoint EzagentWeb.Endpoint
  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")
  @owner_uri Ezagent.URI.new!("entity://team-alpha/user/admin")

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  test "/plugins/auto/session mounts + renders title", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/plugins/auto/session")

    assert html =~ "Auto-derived: session"
    assert html =~ "live instance(s)"
  end

  test "/plugins/auto/user mounts (admin user is live)", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/plugins/auto/user")

    assert html =~ "Auto-derived: user"
  end

  test "/plugins/auto/<unknown> mounts to empty list", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/plugins/auto/nonexistent_kind")
    assert html =~ "No live instances"
  end

  test "agent detail renders credential cascade management panel", %{conn: conn} do
    %{agent_uri: agent_uri, source_uri: source_uri} = seed_cascade_agent!()

    {:ok, _lv, html} = live(conn, agent_detail_path(agent_uri))

    assert html =~ "Credential cascade"
    assert html =~ "Layer stack"
    assert html =~ URI.to_string(source_uri)
    assert html =~ "Set default source"
    assert html =~ "Revoke grant"

    Ezagent.Kind.terminate(agent_uri)
  end

  test "agent detail sets the user default source through dispatch" do
    owner_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/user/cascade-owner-#{System.unique_integer([:positive])}"
      )

    ensure_owner_user!(owner_uri)

    %{agent_uri: agent_uri, source_uri: source_uri} = seed_cascade_agent!(owner_uri)

    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(owner_uri),
        "current_workspace_uri" => URI.to_string(@workspace_uri)
      })

    {:ok, lv, _html} = live(conn, agent_detail_path(agent_uri))

    lv
    |> form("#set-default-source-form",
      default_source: %{
        "owner_uri" => URI.to_string(owner_uri),
        "workspace_uri" => URI.to_string(@workspace_uri),
        "flavor" => "cc",
        "source_uri" => URI.to_string(source_uri)
      }
    )
    |> render_submit()

    assert UserDefaultSource.resolve(URI.to_string(owner_uri), "team-alpha", "cc") ==
             URI.to_string(source_uri)

    assert render(lv) =~ "Default source updated"

    Ezagent.Kind.terminate(agent_uri)
  end

  test "agent detail revokes the credential grant through dispatch", %{conn: conn} do
    %{agent_uri: agent_uri} = seed_cascade_agent!()

    {:ok, lv, _html} = live(conn, agent_detail_path(agent_uri))

    lv
    |> element("#revoke-credential-grant")
    |> render_click()

    assert %GrantRow{revoked_at: %DateTime{}} = GrantRow.get_for_agent(URI.to_string(agent_uri))
    assert render(lv) =~ "Grant revoked"

    Ezagent.Kind.terminate(agent_uri)
  end

  defp seed_cascade_agent!(owner_uri \\ @owner_uri) do
    agent_uri =
      Ezagent.URI.agent("team-alpha", "cascade-ui-#{System.unique_integer([:positive])}")

    source_uri =
      Ezagent.URI.agent("team-alpha", "cascade-ui-source-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})
    wait_for(fn -> Ezagent.ReadyGate.status(agent_uri) == :ready end)

    {:ok, _} =
      Ezagent.SnapshotStore.write(
        source_uri,
        %{sandbox: %{state: %{config_dir_path: "/tmp/source"}}},
        kind_type: :agent
      )

    :ok = Ezagent.AgentLineage.record(source_uri, owner_uri)
    :ok = Ezagent.AgentFlavorAttributes.put(source_uri, "cc")

    target = Ezagent.URI.with_action(agent_uri, :sandbox, :write_path)

    assert {:ok, _} =
             Invocation.dispatch(%Invocation{
               target: target,
               mode: :call,
               args: %{
                 config_dir_path: "/tmp/agent",
                 template_class: Ezagent.PluginCc.Template.CcAgent,
                 respawn_template_data: %{
                   "flavor" => "cc",
                   "cascade_resolution" => %{
                     "owner_uri" => URI.to_string(owner_uri),
                     "workspace_uri" => URI.to_string(@workspace_uri),
                     "workspace_layer_uri" => "template://team-alpha/agent/workspace-cc",
                     "credential_source_uri" => URI.to_string(source_uri)
                   }
                 }
               },
               ctx: %{caller: :system, caps: :system, reply: :sync}
             })

    assert {:ok, _grant} =
             GrantRow.insert(%{
               agent_uri: URI.to_string(agent_uri),
               credential_source_uri: URI.to_string(source_uri),
               approved_by: URI.to_string(@owner_uri),
               approved_scope: URI.to_string(source_uri),
               version: 1
             })

    %{agent_uri: agent_uri, source_uri: source_uri}
  end

  defp ensure_owner_user!(%URI{} = owner_uri) do
    {:ok, _} =
      Users.create(URI.to_string(owner_uri), "pw-not-secret", [set_default_source_cap(owner_uri)])

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner_uri)
    wait_for(fn -> Ezagent.ReadyGate.status(owner_uri) == :ready end)
  end

  defp set_default_source_cap(%URI{} = owner_uri) do
    %Ezagent.Capability{
      kind: :user,
      behavior: Ezagent.Behavior.UserDefaultCredentialSource,
      action: :set_default_credential_source,
      instance: Ezagent.URI.instance(owner_uri),
      workspace_uri: Ezagent.Capability.workspace_of(owner_uri),
      granted_by: Ezagent.URI.new!("entity://system/user/admin"),
      granted_at: ~U[2026-06-06 00:00:00Z]
    }
  end

  defp agent_detail_path(agent_uri) do
    "/plugins/auto/agent/#{URI.encode_www_form(URI.to_string(agent_uri))}"
  end

  defp wait_for(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("condition was not met before timeout")
      else
        Process.sleep(10)
        do_wait_for(fun, deadline)
      end
    end
  end
end
