defmodule EzagentWeb.Socialware.ChatFeedControllerTest do
  @moduledoc """
  P4 (codex finding 3) — the CHAT external SPA entrypoint is reachable from a
  browser by an AUTHENTICATED signed-in principal.

  The route is mounted under `RequireEntity`, so:

    * an authenticated principal gets a 200 HTML SPA shell whose mount element
      carries `data-socket-path="/socialware_chat_socket"` +
      `data-topic-prefix="socialware:chat_feed"` and a server-minted
      `ChatFeedAuth` token bound to THAT principal + session;
    * an anonymous request is bounced to /login by RequireEntity (the token is
      never minted for an unauthenticated viewer);
    * the minted token verifies back to the signed-in principal (so the channel
      can recover a TRUSTED caller for the live ChatMembership re-check).

  Membership itself is NOT decided here — the page renders for any authenticated
  principal; the channel's live `ChatMembership` check is the authorization (a
  non-member sees "Unauthorized" in the SPA).
  """
  use EzagentCore.DataCase
  use Phoenix.ConnTest

  alias Ezagent.Socialware.ChatFeedAuth

  @endpoint EzagentWeb.Endpoint

  setup do
    case Ezagent.Workspace.Store.get_by_name("team-alpha") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("team-alpha", %{})
      _ -> :ok
    end

    principal = "entity://team-alpha/user/cfc-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Users.create(principal, "pw", [])

    session =
      Ezagent.URI.session(:team_alpha, :default, "cfc-#{System.unique_integer([:positive])}")

    %{principal: principal, session: session}
  end

  describe "GET /socialware/chat — authenticated member SPA shell" do
    test "authenticated principal gets the chat SPA shell pointed at the chat socket + topic",
         %{principal: principal, session: session} do
      session_str = URI.to_string(session)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => principal})
        |> get("/socialware/chat", %{"session_uri" => session_str})

      assert conn.status == 200
      body = response(conn, 200)

      # The shared SPA, parameterized to the CHAT transport.
      assert body =~ ~s(src="/assets/js/customer_app.js")
      assert body =~ ~s(id="socialware-customer-root")
      assert body =~ ~s(data-socket-path="/socialware_chat_socket")
      assert body =~ ~s(data-topic-prefix="socialware:chat_feed")
      assert body =~ session_str
    end

    test "the embedded token verifies back to the signed-in principal for THIS session",
         %{principal: principal, session: session} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => principal})
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      body = response(conn, 200)
      [_, token] = Regex.run(~r/data-token="([^"]+)"/, body)

      assert {:ok, recovered} = ChatFeedAuth.verify(token, session)
      assert URI.to_string(recovered) == principal
    end

    test "anonymous request is bounced to /login by RequireEntity (token never minted)",
         %{session: session} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> get("/socialware/chat", %{"session_uri" => URI.to_string(session)})

      assert redirected_to(conn) =~ "/login"
    end

    test "missing session_uri → 400", %{principal: principal} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => principal})
        |> get("/socialware/chat", %{})

      assert conn.status == 400
    end

    test "a non-session URI → 400", %{principal: principal} do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => principal})
        |> get("/socialware/chat", %{"session_uri" => "entity://team-alpha/user/bob"})

      assert conn.status == 400
    end
  end
end
