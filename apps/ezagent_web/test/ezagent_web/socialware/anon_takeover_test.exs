defmodule EzagentWeb.Socialware.AnonTakeoverTest do
  use EzagentCore.DataCase, async: false

  import Phoenix.ConnTest

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate}

  alias Ezagent.Socialware.{
    AnonBinding,
    AnonUser,
    ChatFeed,
    ChatFeedAuth,
    DefinitionRegistry,
    Installation
  }

  alias EzagentWeb.SessionPrincipal
  alias EzagentWeb.Socialware.AnonCookie

  @endpoint EzagentWeb.Endpoint

  setup do
    # `use EzagentCore.DataCase, async: false` already shares the sandbox via a
    # drainable Agent owner; a redundant `Sandbox.mode({:shared, self()})` here
    # only re-globalized the connection onto the dying test pid and clobbered
    # concurrent suites with "owner exited" errors (#92).
    case Ezagent.Workspace.Store.get_by_name("team-alpha") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("team-alpha", %{})
      _ -> :ok
    end

    :ok
  end

  defp u, do: System.unique_integer([:positive])

  defp public_session do
    u = u()
    definition_name = "takeover-def-#{u}"

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(
        %{
          name: definition_name,
          bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
          shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
          owner_policy: %{type: :installer},
          visibility_policy: %{publish_policy: :auto, web_anon_access: true}
        },
        workspace_uri: Ezagent.URI.workspace("team-alpha")
      )

    content = %{name: "takeover-pub-#{u}", installs: [definition_name]}
    {:ok, tmpl} = SessionTemplate.persist_version_as_system(content, "team-alpha")

    uri = Ezagent.URI.new!("session://team-alpha/default/takeover-#{u()}")

    {:ok, behaviors} =
      Installation.behavior_set_for_template(content, Ezagent.URI.workspace("team-alpha"))

    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: uri, behaviors: behaviors})

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))

    :ok =
      Installation.install_template_installs(
        uri,
        Ezagent.URI.workspace("team-alpha"),
        content,
        Ezagent.Entity.User.admin_uri()
      )

    {:ok, _} = ConfigActions.system_set_working_copy(uri, %{session_template_uri: tmpl})

    on_exit(fn -> terminate(uri) end)
    uri
  end

  defp terminate(uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

      :error ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp open_as_anon(session) do
    conn =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

    assert conn.status == 200
    [_, token] = Regex.run(~r/data-token="([^"]+)"/, response(conn, 200))
    assert {:ok, anon} = ChatFeedAuth.verify(token, session)
    assert AnonUser.anon_uri?(anon)

    %{value: cookie} = conn.resp_cookies[AnonCookie.cookie_name()]
    {anon, cookie}
  end

  defp create_confirmed_user(name) do
    uri = Ezagent.URI.new!("entity://team-alpha/user/#{name}")
    {:ok, _} = Ezagent.Users.create(uri, "pw", [])
    :ok = Ezagent.Entity.spawn_principal(uri)
    uri
  end

  defp member?(session, member) do
    case Ezagent.Kind.get_slice(session, :session) do
      {:ok, %{state: %{members: members}}} when is_map(members) ->
        Map.has_key?(members, member)

      {:ok, %{members: members}} when is_map(members) ->
        Map.has_key?(members, member)

      _ ->
        false
    end
  end

  describe "post-auth anon takeover hook" do
    test "SessionPrincipal.put claims, merges, relabels, mounts caps, and retires the cookie-bound anon" do
      session = public_session()
      {anon, cookie} = open_as_anon(session)
      confirmed = create_confirmed_user("takeover-confirmed-#{u()}")

      {:ok, msg} =
        Message.new(anon, %{text: "anon footprint", attachments: []}, mentions: [anon])
        |> MessageStore.write(session)

      assert {:ok, :updated} =
               Ezagent.Session.ReadMarker.mark(session, anon, msg.id, :read)

      assert member?(session, anon)
      refute member?(session, confirmed)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_req_cookie(AnonCookie.cookie_name(), cookie)
        |> SessionPrincipal.put(URI.to_string(confirmed))

      assert Plug.Conn.get_session(conn, :current_entity_uri) == URI.to_string(confirmed)
      assert conn.resp_cookies[AnonCookie.cookie_name()].max_age == 0

      refute member?(session, anon)
      assert member?(session, confirmed)
      assert AnonBinding.get(anon) == nil
      assert Ezagent.Users.get_by_uri(anon) == nil

      assert {:ok, relabelled} = MessageStore.by_id(msg.id)
      assert relabelled.sender == confirmed
      assert relabelled.mentions == [confirmed]

      assert Ezagent.Session.ReadMarker.last_read(session, confirmed, :read) == msg.id
      assert Ezagent.Session.ReadMarker.last_read(session, anon, :read) == nil

      assert {:ok, _} = ChatFeed.snapshot(session, confirmed)
      assert {:error, _} = ChatFeed.snapshot(session, anon)
    end

    test "binding existence without signed-cookie possession cannot trigger takeover" do
      session = public_session()
      {anon, _cookie} = open_as_anon(session)
      confirmed = create_confirmed_user("takeover-nonpossessor-#{u()}")

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> SessionPrincipal.put(URI.to_string(confirmed))

      assert Plug.Conn.get_session(conn, :current_entity_uri) == URI.to_string(confirmed)
      assert member?(session, anon)
      refute member?(session, confirmed)
      assert %AnonBinding{} = AnonBinding.get(anon)
      assert Ezagent.Users.get_by_uri(anon) != nil
    end
  end
end
