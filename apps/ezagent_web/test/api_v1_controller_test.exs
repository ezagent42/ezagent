defmodule EzagentWeb.ApiV1ControllerTest do
  @moduledoc """
  Phase 6 PR 9 — canonical JSON API smoke tests.

  Validates:
  - GET /api/v1 returns the route catalog (with at least the
    foundational Chat/Identity/Workspace actions present)
  - POST /api/v1/:kind/:action accepts JSON body + dispatches
  - 404 on unknown kind/action
  - 401 on invalid bearer token (token presented but unknown)
  """
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint EzagentWeb.Endpoint

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(EzagentCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: build_conn()}
  end

  test "GET /api/v1 lists routes", %{conn: conn} do
    conn = get(conn, "/api/v1")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert is_list(body["routes"])
    assert is_integer(body["count"])
    assert body["count"] > 0

    # At least one well-known action must show up — Identity:list_caps
    # is registered on User by ezagent_domain_identity.Application.
    assert Enum.any?(body["routes"], fn r ->
             r["kind"] == "user" and r["action"] == "list_caps"
           end)
  end

  test "POST with unknown kind returns 404", %{conn: conn} do
    conn = post(conn, "/api/v1/nope/say", %{"target" => "entity://team-alpha/agent/test_x"})

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == false
    assert body["error"]["code"] == "unknown_behavior"
  end

  test "POST without target returns 400", %{conn: conn} do
    conn = post(conn, "/api/v1/user/list_caps", %{})

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "missing_target"
  end

  test "POST with invalid bearer token returns 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer esr_pat_garbage_token_value")
      |> post("/api/v1/user/list_caps", %{"target" => "entity://system/user/admin"})

    assert conn.status == 401
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "invalid_token"
  end

  test "POST resolves a valid bearer token without an entity URI header", %{conn: conn} do
    principal = Ezagent.Entity.User.admin_uri()
    {token, _row} = Ezagent.Entity.Token.mint(principal, label: "api-token-only")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/user/list_caps", %{"target" => URI.to_string(principal)})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["ok"] == true
  end

  test "POST rejects authority-context fields in the request body", %{conn: conn} do
    principal = Ezagent.Entity.User.admin_uri()
    {token, _row} = Ezagent.Entity.Token.mint(principal, label: "api-no-context")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/user/list_caps", %{
        "target" => URI.to_string(principal),
        "principal" => URI.to_string(principal)
      })

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "identity_input_forbidden"
  end

  test "POST rejects a caller-supplied identity selector header",
       %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer esr_pat_garbage_token_value")
      |> put_req_header("x-ezagent-entity-uri", "entity://system/user/admin")
      |> post("/api/v1/user/list_caps", %{"target" => "entity://system/user/admin"})

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "identity_input_forbidden"
  end
end
