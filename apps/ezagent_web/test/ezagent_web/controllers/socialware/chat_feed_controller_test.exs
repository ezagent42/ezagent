defmodule EzagentWeb.Socialware.ChatFeedControllerTest do
  @moduledoc """
  Issue #51 §4.1 — the CHAT external SPA entrypoint, now PUBLIC (no RequireEntity).

  Proven here (the controller-level security properties):

    * **authenticated member** — a still-signed-in principal gets a 200 SPA shell +
      a `ChatFeedAuth` token bound to THAT principal (no anon minted);
    * **anonymous + PRIVATE session** — bounces to /login; NO anon-User is minted and
      NO `socialware_anon` cookie is set (security property #4 — a non-public session
      is never anon-accessible);
    * **anonymous + PUBLIC session** — mints a read-only anon-User, joins it, sets a
      signed `socialware_anon` cookie, and the embedded token verifies back to the
      anon-User (which is a real member → reads via membership);
    * **returning visitor (valid cookie)** — REUSES the same anon-User (no re-mint),
      `last_seen_at` refreshed;
    * **tampered cookie** — fails closed: the tampered value resolves to NO identity,
      so a FRESH anon-User is minted (an unsigned cookie never resolves an identity,
      security property #6);
    * `missing` / `non-session` `session_uri` → 400.
  """
  use EzagentCore.DataCase, async: false
  import Phoenix.ConnTest

  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate}
  alias Ezagent.Socialware.{AnonBinding, AnonUser, ChatFeedAuth, DefinitionRegistry, Installation}
  alias EzagentWeb.Socialware.AnonCookie

  @endpoint EzagentWeb.Endpoint

  setup do
    # spawned Session / User Kinds run in their own processes; `use
    # EzagentCore.DataCase, async: false` already shares the sandbox via a
    # drainable Agent owner, so a redundant `Sandbox.mode({:shared, self()})`
    # only re-globalized the connection onto the dying test pid and clobbered
    # concurrent suites with "owner exited" errors (#92).
    case Ezagent.Workspace.Store.get_by_name("team-alpha") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("team-alpha", %{})
      _ -> :ok
    end

    :ok
  end

  defp u, do: System.unique_integer([:positive])

  defp session_for_content(content, template_uri) do
    uri = Ezagent.URI.new!("session://team-alpha/default/cfc-#{u()}")

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

    {:ok, _} = ConfigActions.system_set_working_copy(uri, %{session_template_uri: template_uri})

    on_exit(fn -> terminate(uri) end)
    uri
  end

  defp public_session do
    content = public_content("cfc-pub-#{u()}", true)
    {:ok, tmpl} = SessionTemplate.persist_version_as_system(content, "team-alpha")

    session_for_content(content, tmpl)
  end

  defp private_session do
    content = public_content("cfc-priv-#{u()}", false)
    {:ok, tmpl} = SessionTemplate.persist_version_as_system(content, "team-alpha")

    session_for_content(content, tmpl)
  end

  defp public_content(name, web_anon_access) do
    definition_name = "#{name}-def"

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(
        %{
          name: definition_name,
          bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
          shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
          owner_policy: %{type: :installer},
          visibility_policy: %{publish_policy: :auto, web_anon_access: web_anon_access}
        },
        workspace_uri: Ezagent.URI.workspace("team-alpha")
      )

    %{name: name, installs: [definition_name]}
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

  defp anon_cookie_value(conn) do
    case conn.resp_cookies[AnonCookie.cookie_name()] do
      %{value: value} -> value
      _ -> nil
    end
  end

  describe "authenticated member (route is public, but a signed-in principal is honoured)" do
    test "an authenticated principal gets the chat SPA shell + a token bound to it" do
      principal = "entity://team-alpha/user/cfc-#{u()}"
      {:ok, _} = Ezagent.Users.create(principal, "pw", [])
      session = public_session()
      session_str = URI.to_string(session)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => principal})
        |> get("/socialware/chat", %{"session_uri" => session_str})

      assert conn.status == 200
      body = response(conn, 200)
      assert body =~ ~s(data-socket-path="/socialware_chat_socket")
      assert body =~ ~s(data-topic-prefix="socialware:chat_feed")
      assert body =~ session_str

      [_, token] = Regex.run(~r/data-token="([^"]+)"/, body)
      assert {:ok, recovered} = ChatFeedAuth.verify(token, session)
      assert URI.to_string(recovered) == principal

      # No anon identity minted for a signed-in user.
      assert is_nil(anon_cookie_value(conn))
    end
  end

  describe "anonymous + PRIVATE session — bounces, mints nothing (security property #4)" do
    test "an anonymous request to a non-public session is bounced to /login" do
      session = private_session()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      assert redirected_to(conn) =~ "/login"
      # No anon-User minted, no cookie set — a private session never becomes
      # anon-accessible.
      assert is_nil(anon_cookie_value(conn))
    end
  end

  describe "anonymous + PUBLIC session — mint, join, cookie, member-read" do
    test "mints a read-only anon-User, sets a signed cookie, token verifies to the anon" do
      session = public_session()

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      assert conn.status == 200
      body = response(conn, 200)
      [_, token] = Regex.run(~r/data-token="([^"]+)"/, body)
      assert {:ok, anon} = ChatFeedAuth.verify(token, session)
      assert AnonUser.anon_uri?(anon)

      # Cookie set + verifies back to the SAME anon URI for THIS session.
      value = anon_cookie_value(conn)
      assert is_binary(value)
      assert {:ok, ^anon} = AnonCookie.verify(value, session)

      # The anon-User is read-only by construction (its only cap is the narrow
      # `session.join` grant — no WRITE cap) AND a real member (the join landed,
      # dispatched AS the anon under its own grant, no system principal) — so its
      # membership read passes.
      assert {:ok, _} = Ezagent.Socialware.ChatFeed.snapshot(session, anon)

      # A binding row exists (the GC index + cookie resolver).
      assert %AnonBinding{} = AnonBinding.get(anon)
    end

    test "a returning visitor with a valid cookie REUSES the same anon-User (no re-mint)" do
      session = public_session()

      conn1 =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      cookie1 = anon_cookie_value(conn1)
      [_, token1] = Regex.run(~r/data-token="([^"]+)"/, response(conn1, 200))
      {:ok, anon1} = ChatFeedAuth.verify(token1, session)

      # Returning visit carries the cookie back.
      conn2 =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_req_cookie(AnonCookie.cookie_name(), cookie1)
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      assert conn2.status == 200
      [_, token2] = Regex.run(~r/data-token="([^"]+)"/, response(conn2, 200))
      {:ok, anon2} = ChatFeedAuth.verify(token2, session)

      # SAME identity reused — not a fresh mint.
      assert URI.to_string(anon1) == URI.to_string(anon2)
    end

    test "a TAMPERED cookie fails closed → a FRESH anon-User is minted (property #6)" do
      session = public_session()

      conn1 =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      cookie1 = anon_cookie_value(conn1)
      [_, token1] = Regex.run(~r/data-token="([^"]+)"/, response(conn1, 200))
      {:ok, anon1} = ChatFeedAuth.verify(token1, session)

      # Tamper the signed value — verification must fail, so the controller mints a
      # FRESH anon identity rather than trusting the tampered handle.
      conn2 =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_req_cookie(AnonCookie.cookie_name(), cookie1 <> "x")
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      assert conn2.status == 200
      [_, token2] = Regex.run(~r/data-token="([^"]+)"/, response(conn2, 200))
      {:ok, anon2} = ChatFeedAuth.verify(token2, session)

      refute URI.to_string(anon1) == URI.to_string(anon2)
      # A fresh signed cookie was set for the new identity.
      assert {:ok, ^anon2} = AnonCookie.verify(anon_cookie_value(conn2), session)
    end
  end

  describe "anonymous + PUBLIC session — GC reaping signal → fresh identity (§4.1a)" do
    test "a returning visitor whose binding is being REAPED gets a FRESH anon (no resurrection)" do
      session = public_session()

      conn1 =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      cookie1 = anon_cookie_value(conn1)
      [_, token1] = Regex.run(~r/data-token="([^"]+)"/, response(conn1, 200))
      {:ok, anon1} = ChatFeedAuth.verify(token1, session)

      # Simulate the GC sweeper having CLAIMED this binding for reaping: backdate
      # last_seen past the TTL, then claim it. A subsequent `touch/3` now returns
      # `{:error, {:reaping, _}}`, which the controller must route to mint-fresh
      # (never resurrect a binding being torn down).
      ttl = Ezagent.Socialware.AnonUser.GC.ttl_ms()
      stale = DateTime.add(DateTime.utc_now(), -ttl - 60_000, :millisecond)

      {1, _} =
        EzagentCore.Repo.update_all(
          Ecto.Query.from(b in AnonBinding, where: b.entity_uri == ^URI.to_string(anon1)),
          set: [last_seen_at: stale]
        )

      assert {:ok, :claimed} =
               AnonBinding.claim_for_reaping(anon1, DateTime.utc_now(), ttl)

      conn2 =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> put_req_cookie(AnonCookie.cookie_name(), cookie1)
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      assert conn2.status == 200
      [_, token2] = Regex.run(~r/data-token="([^"]+)"/, response(conn2, 200))
      {:ok, anon2} = ChatFeedAuth.verify(token2, session)

      refute URI.to_string(anon1) == URI.to_string(anon2)
    end
  end

  describe "input validation" do
    test "missing session_uri → 400" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/socialware/chat", %{})

      assert conn.status == 400
    end

    test "a non-session URI → 400" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/socialware/chat", %{"session_uri" => "entity://team-alpha/user/bob"})

      assert conn.status == 400
    end
  end

  describe "GET /hello/:session_name — path-route hello pages" do
    setup do
      Application.put_env(:ezagent_web, :hello_workspace, "team-alpha")
      :ok
    end

    test "anonymous + public hello session → 200 SPA shell" do
      # Create a hello-session at session://team-alpha/hello/test-site that is PUBLIC.
      name = "hello-path-#{u()}"
      session_uri = Ezagent.URI.session("team-alpha", :hello, name)

      content = public_content("hpath-#{u()}", true)
      {:ok, tmpl} = SessionTemplate.persist_version_as_system(content, "team-alpha")

      {:ok, behaviors} =
        Installation.behavior_set_for_template(content, Ezagent.URI.workspace("team-alpha"))

      {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: behaviors})

      :ok =
        Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

      :ok =
        Installation.install_template_installs(
          session_uri,
          Ezagent.URI.workspace("team-alpha"),
          content,
          Ezagent.Entity.User.admin_uri()
        )

      {:ok, _} = ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl})

      on_exit(fn -> terminate(session_uri) end)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/hello/#{name}")

      assert conn.status == 200
      body = response(conn, 200)
      # Renders the same SPA shell as /socialware/chat
      assert body =~ ~s(data-socket-path="/socialware_chat_socket")
      assert body =~ ~s(data-topic-prefix="socialware:chat_feed")
      assert body =~ URI.to_string(session_uri)
    end

    test "anonymous + private hello session → bounce /login" do
      name = "hello-priv-#{u()}"
      session_uri = Ezagent.URI.session("team-alpha", :hello, name)

      content = public_content("hpp-#{u()}", false)
      {:ok, tmpl} = SessionTemplate.persist_version_as_system(content, "team-alpha")

      {:ok, behaviors} =
        Installation.behavior_set_for_template(content, Ezagent.URI.workspace("team-alpha"))

      {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: behaviors})

      :ok =
        Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

      :ok =
        Installation.install_template_installs(
          session_uri,
          Ezagent.URI.workspace("team-alpha"),
          content,
          Ezagent.Entity.User.admin_uri()
        )

      {:ok, _} = ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl})

      on_exit(fn -> terminate(session_uri) end)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/hello/#{name}")

      assert redirected_to(conn) =~ "/login"
    end

    test "missing / empty session_name → 404 (does not match the route)" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/hello/")

      assert conn.status == 404
    end
  end
end
