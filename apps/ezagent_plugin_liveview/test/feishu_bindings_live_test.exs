defmodule EzagentPluginLiveview.FeishuBindingsLiveTest do
  @moduledoc """
  /plugins/feishu/bindings LiveView integration tests.

  Covers both binding sections:

  1. User bindings (open_id ↔ user URI) — pre-existing surface.
  2. Session bindings (chat_id ↔ session URI) — V1 fix, Allen Feishu
     2026-05-22. The session-binding section previously had no UI;
     these tests pin the new list + bind form + unbind contract.

  The two ESR-URI fields (`user_uri`, `session_uri`) use the
  `uri_picker` component (fix 2026-05-22); the picker-render +
  server-side revalidation contract is pinned in the `uri_picker`
  describe block.
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias EzagentPluginFeishu.SessionBinding

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # The uri_picker fields are scoped to `current_workspace_uri`. The
    # admin is a `workspace://system` member (cross-workspace authority),
    # so it can operate in the `default` workspace; set the session slot
    # explicitly so the picker + server revalidation both scope to
    # `workspace://default`.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://default"
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
    # The session_uri uri_picker hidden input is JS-managed (only ""
    # is valid in a dead-render). Set the form-real field (chat_id) via
    # form/3; pass the picker-managed session_uri via render_submit/2
    # extras — mirrors routing_live_test's pattern.
    test "valid submit creates a SessionBinding row", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plugins/feishu/bindings")

      assert SessionBinding.list_all() == []

      html =
        lv
        |> form("form[phx-submit=bind_session]", %{
          "session_bind" => %{"chat_id" => "oc_test_chat_42"}
        })
        |> render_submit(%{
          "session_bind" => %{"session_uri" => "session://default/default/main"}
        })

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
          "session_bind" => %{"chat_id" => "bad_chat"}
        })
        |> render_submit(%{
          "session_bind" => %{"session_uri" => "session://default/default/main"}
        })

      assert html =~ "must start with `oc_`"
      assert SessionBinding.list_all() == []
    end

    test "rejects a session_uri that is not a session:// URI", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plugins/feishu/bindings")

      html =
        lv
        |> form("form[phx-submit=bind_session]", %{
          "session_bind" => %{"chat_id" => "oc_test_chat"}
        })
        |> render_submit(%{
          "session_bind" => %{"session_uri" => "entity://user/default/main"}
        })

      # An entity:// URI is the wrong scheme for a [:session] picker —
      # the shared validator rejects it server-side.
      assert html =~ "Rejected"
      assert html =~ "must be a session URI"
      assert SessionBinding.list_all() == []
    end
  end

  # --- uri_picker (fix 2026-05-22) -------------------------------------------

  describe "uri_picker" do
    test "both URI fields render uri_picker :single components", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/plugins/feishu/bindings")

      # The two ESR-URI fields are pickers, not raw text inputs.
      assert html =~ ~s(phx-hook="UriPicker")
      assert html =~ ~s(data-mode="single")
      assert html =~ ~s(data-name="bind[user_uri]")
      assert html =~ ~s(data-name="session_bind[session_uri]")

      # Feishu identifiers stay raw text inputs (not URIs).
      assert html =~ ~s(name="bind[open_id]")
      assert html =~ ~s(name="session_bind[chat_id]")
    end

    test "rejects a tampered out-of-workspace user_uri", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plugins/feishu/bindings")

      # The picker is scoped to workspace://default; a hand-tampered
      # hidden input naming an entity in another workspace must be
      # rejected server-side, NOT bound. The picker hidden input is
      # JS-managed, so the tampered URI rides in render_submit/2 extras.
      html =
        lv
        |> form("form[phx-submit=bind]", %{
          "bind" => %{"open_id" => "ou_tamper_user"}
        })
        |> render_submit(%{
          "bind" => %{"user_uri" => "entity://user/other-tenant/evil"}
        })

      assert html =~ "Rejected"
      assert EzagentPluginFeishu.UserBinding.list_all() == []
    end

    test "rejects a tampered out-of-workspace session_uri", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plugins/feishu/bindings")

      html =
        lv
        |> form("form[phx-submit=bind_session]", %{
          "session_bind" => %{"chat_id" => "oc_tamper_chat"}
        })
        |> render_submit(%{
          "session_bind" => %{"session_uri" => "session://default/other-tenant/leak"}
        })

      assert html =~ "Rejected"
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
