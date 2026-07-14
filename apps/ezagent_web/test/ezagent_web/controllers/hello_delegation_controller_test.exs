defmodule EzagentWeb.HelloDelegationControllerTest do
  use EzagentWeb.ConnCase, async: false

  setup do
    parent = self()

    Application.put_env(:ezagent_web, :hello_kanban_delegation_start, fn session,
                                                                         instruction,
                                                                         caller ->
      send(parent, {:delegated, session, instruction, caller})
      {:ok, self()}
    end)

    on_exit(fn -> Application.delete_env(:ezagent_web, :hello_kanban_delegation_start) end)
    :ok
  end

  test "anonymous delegation redirects to login and resumes exactly once", %{conn: conn} do
    session = Ezagent.URI.session("demo", :hello, "launch")

    conn =
      post(conn, "/hello/delegate", %{
        "session_uri" => URI.to_string(session),
        "instruction" => "Ship the homepage"
      })

    assert redirected_to(conn) == "/login?return_to=%2Fhello%2Fdelegate%2Fresume"
    refute_receive {:delegated, _, _, _}

    conn =
      conn
      |> recycle()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "hello_delegation_token" => get_session(conn, :hello_delegation_token),
        "hello_delegation_digest" => get_session(conn, :hello_delegation_digest)
      })
      |> get("/hello/delegate/resume")

    assert redirected_to(conn) == "/hello/launch"

    assert_receive {:delegated, ^session, "Ship the homepage", caller}
    assert caller == Ezagent.Entity.User.admin_uri()

    conn = conn |> recycle() |> get("/hello/delegate/resume")
    assert redirected_to(conn) == "/sessions"
    refute_receive {:delegated, _, _, _}
  end

  test "authenticated delegation starts immediately without trusting a caller param", %{
    conn: conn
  } do
    session = Ezagent.URI.session("demo", :hello, "launch")
    admin = Ezagent.Entity.User.admin_uri()

    conn =
      conn
      |> Plug.Test.init_test_session(%{"current_entity_uri" => URI.to_string(admin)})
      |> post("/hello/delegate", %{
        "session_uri" => URI.to_string(session),
        "instruction" => "Task A",
        "caller" => "entity://evil/user/attacker"
      })

    assert redirected_to(conn) == "/hello/launch"
    assert_receive {:delegated, ^session, "Task A", ^admin}
  end
end
