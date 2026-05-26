defmodule EzagentPluginLiveview.FeishuBindingsLiveTest do
  @moduledoc """
  /plugins/feishu/bindings LiveView integration tests.

  PR-EM-6 reshape: the session-bindings section was retired (moved to
  the generic ExternalMirror admin LV at
  `/admin/sessions/:id/external_mirror`). This test file now covers
  ONLY the user-bindings surface (open_id ↔ user_uri) which remains
  the Feishu plugin's responsibility.
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias EzagentPluginFeishu.UserBinding

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
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, conn: conn}
  end

  describe "user-binding section" do
    test "renders the user-binding form with empty state", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/plugins/feishu/bindings")

      assert html =~ "Feishu user bindings"
      assert html =~ "Bind open_id ↔ user URI"
      assert html =~ "No bindings yet"
    end

    test "lists existing user bindings", %{conn: conn} do
      {:ok, _row} =
        UserBinding.bind(
          "ou_existing",
          "entity://user/system/alice",
          "entity://user/system/admin"
        )

      {:ok, _lv, html} = live(conn, "/plugins/feishu/bindings")

      assert html =~ "ou_existing"
      assert html =~ "entity://user/system/alice"
      refute html =~ "No bindings yet"
    end
  end

  describe "session-bindings redirect (PR-EM-6)" do
    test "renders the redirect card pointing operators at the generic surface", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/plugins/feishu/bindings")

      assert html =~ "moved"
      assert html =~ "ezagent.external_mirror.bind"
      assert html =~ "/admin/sessions/"
    end
  end

  describe "uri_picker" do
    test "the user_uri field renders as a uri_picker :single component", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/plugins/feishu/bindings")

      assert html =~ ~s(phx-hook="UriPicker")
      assert html =~ ~s(data-mode="single")
      assert html =~ ~s(data-name="bind[user_uri]")

      # Feishu identifier stays a raw text input (not a URI).
      assert html =~ ~s(name="bind[open_id]")
    end

    test "rejects a tampered out-of-workspace user_uri", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/plugins/feishu/bindings")

      # The picker is scoped to workspace://default; a hand-tampered
      # hidden input naming an entity in another workspace must be
      # rejected server-side, NOT bound.
      html =
        lv
        |> form("form[phx-submit=bind]", %{
          "bind" => %{"open_id" => "ou_tamper_user"}
        })
        |> render_submit(%{
          "bind" => %{"user_uri" => "entity://user/other-tenant/evil"}
        })

      assert html =~ "Rejected"
      assert UserBinding.list_all() == []
    end
  end
end
