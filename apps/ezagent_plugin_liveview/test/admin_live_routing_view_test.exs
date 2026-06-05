defmodule EzagentPluginLiveview.AdminLiveRoutingViewTest do
  @moduledoc """
  V1 Allen #2 (Feishu 2026-05-21) — `/sessions` view-switcher must
  expose Routing as a peer of Chat (Terminal becomes the 3rd tab).

  Verifies:
  - View-switcher renders the Routing tab.
  - Tab order is Chat | Routing | Terminal.
  - Clicking the Routing tab switches `view_module` and renders
    `EzagentDomainUi.Routing.RoutingView`.
  - Submitting the add-session-rule form dispatches via
    `Ezagent.Invocation.dispatch` to the Session Kind's Routing
    Behavior and the new rule appears in the session-scoped list.
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Session-scoped routing rules are validated against the session's
    # workspace. Use the boot-seeded system session so this test focuses
    # on RoutingView behavior, not workspace/session provisioning.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, conn: conn}
  end

  describe "view-switcher" do
    test "renders Routing tab as a peer of Chat", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")

      # Slice the view-switcher block out of the full HTML so other
      # page content matching "Routing" / "Chat" / "Terminal" doesn't
      # leak into the assertions (e.g. /admin/routing link in the
      # setting dropdown).
      [_, switcher_block | _] = String.split(html, ~s(id="view-switcher"))
      [switcher | _] = String.split(switcher_block, "</div>", parts: 2)

      assert switcher =~ "Chat"
      assert switcher =~ "Routing"
      # Terminal tab is registered + applies-to? only fires when the
      # session has a PTY-backed member alive. In the empty admin
      # session it won't appear; that's correct.
    end

    test "tab order is Chat | Routing | Terminal", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")

      [_, switcher_block | _] = String.split(html, ~s(id="view-switcher"))
      [switcher | _] = String.split(switcher_block, "</div>", parts: 2)

      chat_pos = :binary.match(switcher, "Chat") |> elem(0)
      routing_pos = :binary.match(switcher, "Routing") |> elem(0)

      assert chat_pos < routing_pos,
             "Chat tab must appear before Routing tab in view-switcher"

      # Terminal tab is conditional on a PTY-backed member; when
      # present it must come after Routing. Skip the assertion if not
      # rendered (no cc agent in the default test session).
      case :binary.match(switcher, "Terminal") do
        {term_pos, _} ->
          assert routing_pos < term_pos,
                 "Routing tab must appear before Terminal tab in view-switcher"

        :nomatch ->
          :ok
      end
    end

    test "click Routing tab switches view to RoutingView", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      render_hook(lv, "switch_view", %{"view" => "routing"})
      html = render(lv)

      # RoutingView's render output includes this header text + form
      # — distinct from ConversationView's empty-state copy.
      assert html =~ "Session Routing Rules"
      assert html =~ ~s(id="session-routing-add-form")
    end
  end

  describe "session-scoped rule list" do
    test "shows empty state when no session-scoped rules exist", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      render_hook(lv, "switch_view", %{"view" => "routing"})
      html = render(lv)

      assert html =~ ~s(id="session-routing-rules-empty")
    end

    test "submitting add-rule form dispatches and rule appears", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      render_hook(lv, "switch_view", %{"view" => "routing"})

      # V1 UI PR-1 — the RoutingView pickers are scoped to the
      # session's workspace. Use system-scoped URIs because the test
      # session is `session://system/default/main`.
      receiver = "entity://system/agent/echo-receiver-#{System.unique_integer([:positive])}"
      mention_arg = "entity://system/user/admin"

      lv
      |> form("#session-routing-add-form", %{
        "rule" => %{"matcher_type" => "mention"}
      })
      |> render_submit(%{
        "rule" => %{"matcher_arg" => mention_arg, "receivers" => [receiver]}
      })

      html = render(lv)

      # The new rule is rendered in the session-scoped list. The view
      # shows the receivers verbatim + the matcher representation.
      assert html =~ receiver,
             "new session-scoped rule's receiver should appear in the list"

      assert html =~ "in_session",
             "matcher must be wrapped with :in_session for session scope"

      assert html =~ mention_arg,
             "wrapped mention arg should appear in the matcher representation"
    end

    test "submitting form with empty receivers flashes an error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      render_hook(lv, "switch_view", %{"view" => "routing"})

      lv
      |> form("#session-routing-add-form", %{
        "rule" => %{"matcher_type" => "mention"}
      })
      |> render_submit(%{"rule" => %{"matcher_arg" => "entity://system/user/admin"}})

      html = render(lv)
      assert html =~ "receiver"
    end

    # V1 UI PR-1 (SPEC §1.6) — server-side revalidation of the
    # session-scoped RoutingView's uri_picker submissions.
    test "rejects a tampered out-of-workspace receiver", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      render_hook(lv, "switch_view", %{"view" => "routing"})

      lv
      |> form("#session-routing-add-form", %{
        "rule" => %{"matcher_type" => "mention"}
      })
      |> render_submit(%{
        "rule" => %{
          "matcher_arg" => "entity://system/user/admin",
          "receivers" => ["entity://other-tenant/agent/cc_leak"]
        }
      })

      html = render(lv)
      assert html =~ "Rejected URI"
    end

    test "rejects a tampered out-of-workspace matcher arg", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      render_hook(lv, "switch_view", %{"view" => "routing"})

      lv
      |> form("#session-routing-add-form", %{
        "rule" => %{"matcher_type" => "mention"}
      })
      |> render_submit(%{
        "rule" => %{
          "matcher_arg" => "entity://other-tenant/user/admin",
          "receivers" => ["entity://system/agent/echo_default"]
        }
      })

      html = render(lv)
      assert html =~ "Rejected URI"
    end
  end

  # Mention-gated routing (SPEC §3 / §6.7) — the session-scoped
  # RoutingView's receiver picker accepts the broadcast magic token.
  describe "broadcast option (mention-gated routing)" do
    test "session-scoped add-rule accepts the $session_members token", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      render_hook(lv, "switch_view", %{"view" => "routing"})

      lv
      |> form("#session-routing-add-form", %{
        "rule" => %{"matcher_type" => "mention"}
      })
      |> render_submit(%{
        "rule" => %{
          "matcher_arg" => "entity://system/user/admin",
          "receivers" => ["$session_members"]
        }
      })

      html = render(lv)

      refute html =~ "Rejected URI",
             "the $session_members broadcast token must not be rejected as an invalid URI"

      assert html =~ "$session_members",
             "the persisted session-scoped rule's broadcast token should render"
    end

    test "session-scoped add-rule accepts $session_users + $mentions tokens", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      render_hook(lv, "switch_view", %{"view" => "routing"})

      lv
      |> form("#session-routing-add-form", %{
        "rule" => %{"matcher_type" => "mention"}
      })
      |> render_submit(%{
        "rule" => %{
          "matcher_arg" => "entity://system/user/admin",
          "receivers" => ["$session_users", "$mentions"]
        }
      })

      html = render(lv)
      refute html =~ "Rejected URI"
    end
  end
end
