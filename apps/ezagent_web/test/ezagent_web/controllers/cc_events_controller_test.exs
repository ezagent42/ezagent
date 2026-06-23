defmodule EzagentWeb.CcEventsControllerTest do
  @moduledoc """
  Phase 4-plus follow-up — Allen 2026-05-17 directive: CC hooks must
  surface errors to Ezagent via a path that does NOT depend on the agent
  (which may itself be down). This test pins:

  1. valid POST → 200 + PubSub broadcast lands on Ezagent.CCEvents.topic()
  2. invalid body → 422 (operator visibility for malformed hook payloads)
  3. **no auth required** — endpoint must accept reports without a
     session cookie (auth-expired hook can't supply one)
  """
  use ExUnit.Case
  import Phoenix.ConnTest

  @endpoint EzagentWeb.Endpoint

  setup do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.CCEvents.topic())
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "POST /api/cc-events with valid body → 200 + PubSub broadcast", %{conn: conn} do
    body = %{
      "bridge_id" => "ctrl-test-#{System.unique_integer([:positive])}",
      "level" => "error",
      "type" => "auth_expired",
      "text" => "Not logged in · Please run /login"
    }

    conn = post(conn, "/api/cc-events", body)
    assert %{"status" => "ok"} = json_response(conn, 200)

    assert_receive {:cc_event, event}, 500
    assert event.bridge_id == body["bridge_id"]
    assert event.level == "error"
    assert event.type == "auth_expired"
    assert event.text =~ "Please run /login"
    assert %DateTime{} = event.at
  end

  test "POST missing bridge_id → 422", %{conn: conn} do
    conn = post(conn, "/api/cc-events", %{"level" => "error", "type" => "x", "text" => "y"})
    assert %{"error" => err} = json_response(conn, 422)
    assert err =~ "bridge_id"
  end

  test "POST with invalid level → 422", %{conn: conn} do
    body = %{
      "bridge_id" => "x",
      "level" => "catastrophic",
      "type" => "x",
      "text" => "y"
    }

    conn = post(conn, "/api/cc-events", body)
    assert %{"error" => err} = json_response(conn, 422)
    assert err =~ "invalid_level"
  end

  test "endpoint is unauthenticated (invariant: no agent dependency)", %{conn: conn} do
    # No init_test_session — fresh conn, no cookie. Endpoint must still
    # accept the report. If a future change adds an auth gate here, this
    # test catches it.
    body = %{
      "bridge_id" => "unauth-test",
      "level" => "warning",
      "type" => "notification",
      "text" => "no session cookie should not matter"
    }

    conn = post(conn, "/api/cc-events", body)
    assert %{"status" => "ok"} = json_response(conn, 200)
  end
end
