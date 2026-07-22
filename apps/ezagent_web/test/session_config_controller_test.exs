defmodule EzagentWeb.SessionConfigControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint EzagentWeb.Endpoint

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(EzagentCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    {:ok, conn: build_conn()}
  end

  test "GET exposes only exact canonical schemas from the HTTP safe subset", %{conn: conn} do
    conn = get(conn, "/api/session-config")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    names = Enum.map(body["operations"], & &1["name"])

    assert "add_participant" in names
    assert "list_templates" in names
    refute "import_participant_manifest" in names
    refute "migrate_session" in names

    canonical = Ezagent.Session.Config.operation("add_participant")

    assert Enum.find(body["operations"], &(&1["name"] == "add_participant")) ==
             Ezagent.Session.Config.Operation.schema(canonical)
  end

  test "POST authenticates from bearer token only and executes a workspace operation", %{
    conn: conn
  } do
    principal = Ezagent.Entity.User.admin_uri()
    {token, _row} = Ezagent.Entity.Token.mint(principal, label: "session-config-http")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/session-config/list_templates", %{"args" => %{}})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["ok"] == true
  end

  test "POST rejects supplied authority context before authentication", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-ezagent-entity-uri", "entity://system/user/admin")
      |> post("/api/session-config/list_templates", %{
        "args" => %{},
        "principal" => "entity://system/user/admin"
      })

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "identity_input_forbidden"
  end

  test "HTTP add_participant rejects a filesystem path as validation, never manifest import",
       %{conn: conn} do
    principal = Ezagent.Entity.User.admin_uri()
    {token, _row} = Ezagent.Entity.Token.mint(principal, label: "session-config-no-lfi")
    session_uri = spawn_session(principal)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/session-config/add_participant", %{
        "target" => URI.to_string(session_uri),
        "args" => %{"ref" => "/etc/passwd", "role_name" => "intruder"}
      })

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "validation_failed"
    assert body["error"]["detail"] =~ "existing_entity_uri_required"
  end

  test "a non-admin session owner can form a team through the token-only HTTP projection", %{
    conn: conn
  } do
    suffix = System.unique_integer([:positive])
    principal = create_user("http-owner-#{suffix}")
    {token, _row} = Ezagent.Entity.Token.mint(principal, label: "session-config-http-owner")
    session_uri = spawn_session(principal)
    agent_uri = Ezagent.URI.agent("team-alpha", "http-participant-#{suffix}")

    {:ok, _agent_pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri, initial_caps: MapSet.new()})

    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, Ezagent.Capability.workspace_of(agent_uri))
    :ok = grant_manage(principal, agent_uri)

    on_exit(fn ->
      Ezagent.Kind.terminate(session_uri)
      Ezagent.Kind.terminate(principal)
      Ezagent.Kind.terminate(agent_uri)
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/session-config/add_participant", %{
        "target" => URI.to_string(session_uri),
        "args" => %{
          "ref" => URI.to_string(agent_uri),
          "role_name" => "reviewer",
          "in_session_template" => false
        }
      })

    assert conn.status == 200, conn.resp_body
    assert Jason.decode!(conn.resp_body)["ok"] == true
    assert {:ok, slice} = Ezagent.Kind.get_slice(session_uri, :session)
    assert slice.members[agent_uri].role_name == "reviewer"
    assert slice.members[agent_uri].in_session_template == false
  end

  defp spawn_session(owner) do
    workspace_name = owner |> Ezagent.Capability.workspace_of() |> Ezagent.URI.workspace_name!()

    uri =
      Ezagent.URI.session(
        workspace_name,
        "generic",
        "http-session-config-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        owner_uri: owner
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    :ok = Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(uri, owner)
    :ok = Ezagent.ActionSet.Session.Membership.provision_join_authority(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp create_user(name) do
    uri = Ezagent.URI.user("team-alpha", name)
    {:ok, _row} = Ezagent.Users.create(uri, "test-password", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  defp grant_manage(principal, agent_uri) do
    cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        agent_uri,
        Ezagent.Capability.workspace_of(agent_uri),
        principal
      )

    Ezagent.Identity.Grant.grant_cap_via_router(
      principal,
      cap,
      {:admin, Ezagent.Entity.User.admin_uri()},
      :sync
    )
  end
end
