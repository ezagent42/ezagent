defmodule EzagentWeb.Socialware.AnonIngressTest do
  use EzagentWeb.ConnCase, async: false

  alias Ezagent.Behavior.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate}
  alias Ezagent.Socialware.{AnonAdmission, AnonBinding, AnonUser, ChatFeedAuth}
  alias EzagentWeb.Socialware.{AnonCookie, AnonIngress}

  @workspace "team-alpha"
  @owner Ezagent.URI.new!("entity://team-alpha/user/anon-ingress-owner")

  defp public_session(flag \\ true) do
    u = System.unique_integer([:positive])

    {:ok, tmpl_uri} =
      SessionTemplate.persist_version_as_system(
        %{name: "anon-ingress-tmpl-#{u}", public_view: flag},
        @workspace
      )

    session_uri = Ezagent.URI.new!("session://#{@workspace}/default/anon-ingress-#{u}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        owner_uri: @owner,
        behaviors: Session.socialware_behaviors()
      })

    :ok =
      Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

    {:ok, _} =
      ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl_uri})

    session_uri
  end

  test "authenticated callers pass through without anon cookie", %{conn: conn} do
    session = public_session()
    caller = Ezagent.URI.new!("entity://team-alpha/user/real-viewer")

    conn = Plug.Test.init_test_session(conn, %{current_entity_uri: URI.to_string(caller)})

    assert {:ok, conn, %{caller: ^caller, source: :authenticated, token: token}} =
             AnonIngress.resolve_caller(conn, session)

    assert {:ok, ^caller} = ChatFeedAuth.verify(token, session)
    refute Map.has_key?(conn.resp_cookies, AnonCookie.cookie_name())
  end

  test "anonymous public-session visitor is minted, cookie-bound, and tokenized", %{conn: conn} do
    session = public_session()
    conn = Plug.Test.init_test_session(conn, %{})

    assert {:ok, conn, %{caller: anon, source: :anonymous_minted, token: token}} =
             AnonIngress.resolve_caller(conn, session)

    assert AnonUser.anon_uri?(anon)
    assert %AnonBinding{} = AnonBinding.get(anon)
    assert {:ok, ^anon} = ChatFeedAuth.verify(token, session)
    assert %{value: cookie} = conn.resp_cookies[AnonCookie.cookie_name()]
    assert {:ok, ^anon} = AnonCookie.verify(cookie, session)
  end

  test "private sessions do not mint anonymous callers", %{conn: conn} do
    session = public_session(false)
    conn = Plug.Test.init_test_session(conn, %{})

    assert {:error, :not_public_view} = AnonIngress.resolve_caller(conn, session)
    refute Map.has_key?(conn.resp_cookies, AnonCookie.cookie_name())
  end

  test "reuse-path spawn failure falls through to mint-fresh", %{conn: conn} do
    session = public_session()
    conn = Plug.Test.init_test_session(conn, %{})
    assert {:ok, %{anon_uri: stale_anon}} = AnonAdmission.admit_anonymous_participant(session)
    assert {:ok, cookie} = AnonCookie.sign(stale_anon, session)

    stale_str = URI.to_string(stale_anon)

    spawn_fun = fn anon ->
      if URI.to_string(anon) == stale_str do
        {:error, :cold_reuse_failed}
      else
        Ezagent.Entity.spawn_principal(anon)
      end
    end

    conn = put_req_cookie(conn, AnonCookie.cookie_name(), cookie)

    assert {:ok, conn, %{caller: fresh_anon, source: :anonymous_minted}} =
             AnonIngress.resolve_caller(conn, session, spawn_principal: spawn_fun)

    assert fresh_anon != stale_anon
    assert AnonUser.anon_uri?(fresh_anon)
    assert %{value: fresh_cookie} = conn.resp_cookies[AnonCookie.cookie_name()]
    assert {:ok, ^fresh_anon} = AnonCookie.verify(fresh_cookie, session)
  end
end
