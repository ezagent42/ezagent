defmodule EzagentPluginLiveview.FeishuBindingsLiveTest do
  @moduledoc """
  /plugins/feishu/bindings LiveView integration tests.

  Covers both binding sections:

  1. User bindings (open_id ↔ user URI) — pre-existing surface.
  2. Session bindings (chat_id ↔ session URI) — V1 fix, Allen Feishu
     2026-05-22. The session-binding section previously had no UI;
     these tests pin the new list + bind form + unbind contract.
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias EzagentPluginFeishu.SessionBinding

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  describe "session-binding section" do
    test "renders the session-binding section with empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/plugins/feishu/bindings")

      assert html =~ "Session bindings"
      assert html =~ "Bind chat_id ↔ session URI"
      assert html =~ "No session bindings yet"
      # placeholder per spec
      assert html =~ "session://default/default/main"
    end

    test "lists existing session bindings", %{conn: conn} do
      {:ok, _row} = SessionBinding.bind("oc_existing_row", "session://default/default/main")

      {:ok, _lv, html} = live(conn, "/plugins/feishu/bindings")

      assert html =~ "oc_existing_row"
      assert html =~ "session://default/default/main"
      assert html =~ "enabled"
      refute html =~ "No session bindings yet"
    end
  end

  describe "bind_session" do
    test "valid submit creates a SessionBinding row", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plugins/feishu/bindings")

      assert SessionBinding.list_all() == []

      html =
        lv
        |> form("form[phx-submit=bind_session]", %{
          "session_bind" => %{
            "chat_id" => "oc_test_chat_42",
            "session_uri" => "session://default/default/main"
          }
        })
        |> render_submit()

      assert html =~ "Bound oc_test_chat_42"

      assert [%SessionBinding{chat_id: "oc_test_chat_42", session_uri: uri}] =
               SessionBinding.list_all()

      assert uri == "session://default/default/main"
    end

    test "rejects a chat_id that does not start with oc_", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plugins/feishu/bindings")

      html =
        lv
        |> form("form[phx-submit=bind_session]", %{
          "session_bind" => %{
            "chat_id" => "bad_chat",
            "session_uri" => "session://default/default/main"
          }
        })
        |> render_submit()

      assert html =~ "must start with `oc_`"
      assert SessionBinding.list_all() == []
    end

    test "rejects a session_uri that is not a session:// URI", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plugins/feishu/bindings")

      html =
        lv
        |> form("form[phx-submit=bind_session]", %{
          "session_bind" => %{
            "chat_id" => "oc_test_chat",
            "session_uri" => "entity://user/default/main"
          }
        })
        |> render_submit()

      assert html =~ "must be a session:// URI"
      assert SessionBinding.list_all() == []
    end
  end

  describe "unbind_session" do
    test "removes the SessionBinding row", %{conn: conn} do
      {:ok, _row} = SessionBinding.bind("oc_to_remove", "session://default/default/main")

      {:ok, lv, html} = live(conn, "/plugins/feishu/bindings")
      assert html =~ "oc_to_remove"

      html =
        lv
        |> element("button[phx-value-chat-id=oc_to_remove]")
        |> render_click()

      assert html =~ "Unbound oc_to_remove"
      assert SessionBinding.list_all() == []
    end
  end
end
