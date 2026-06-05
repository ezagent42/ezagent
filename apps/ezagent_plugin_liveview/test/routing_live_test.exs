defmodule EzagentPluginLiveview.RoutingLiveTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # V1 UI PR-1 — the uri_picker fields are scoped to
    # `current_workspace_uri`. The admin is a `workspace://system`
    # member (cross-workspace authority), so it can operate in the
    # `default` workspace; set the session slot explicitly so the
    # picker + server revalidation both scope to `workspace://team-alpha`.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://team-alpha"
      })

    {:ok, conn: conn}
  end

  test "GET /admin/routing renders MentionRouting form + retirement blurb (no SessionRouting tab)",
       %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/routing")
    # 2026-05-25 — page header changed from "Routing Rules" to
    # "Routing" (tab strip below has "Rules" + "ExternalMirror
    # Bindings" tabs).
    assert html =~ "Routing"
    assert html =~ "MentionRouting"
    assert html =~ "Add rule"
    assert html =~ "Form mode"
    assert html =~ "JSON mode"

    # 2026-05-25 — SessionRouting retired. Selectable tabs / sidebar
    # buttons for it must be gone; the table name itself only appears
    # inside the explanatory "was removed" copy of the blurb.
    refute html =~ "phx-value-table='Elixir.EzagentDomainInstanceMessage.Routing.SessionRouting'"
    refute html =~ ~s(phx-click="switch_table")
    assert html =~ "SessionRouting table was removed"
    assert html =~ "external_mirror_bindings"
  end

  test "matcher arg + receivers render uri_picker components", %{conn: conn} do
    {:ok, lv, html} = live(conn, "/admin/routing")
    # V1 UI PR-1 — raw text inputs replaced with uri_picker.
    assert html =~ ~s(phx-hook="UriPicker")
    assert html =~ ~s(data-mode="single")
    assert html =~ ~s(data-mode="multi")

    # JSON-combinator advanced mode stays a textarea (not a picker).
    json_html = lv |> element("button[phx-value-mode='json']") |> render_click()
    assert json_html =~ "<textarea"
  end

  test "add_rule via form-mode mention persists + appears in list", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/admin/routing")

    # The uri_picker hidden inputs are JS-managed (empty in a
    # dead-render). Set form-real fields (table/matcher_type) via
    # form/3; pass the picker-managed URIs via render_submit/2 extras.
    matcher_arg = "entity://team-alpha/agent/test_lv-test-#{System.unique_integer([:positive])}"
    receiver = "session://team-alpha/default/lv-rcv-#{System.unique_integer([:positive])}"

    lv
    |> form("#add-rule form",
      rule: %{
        table: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
        matcher_type: "mention"
      }
    )
    |> render_submit(%{rule: %{matcher_arg: matcher_arg, receivers: [receiver]}})

    html = render(lv)
    assert html =~ "mention"
    assert html =~ "entity://team-alpha/agent/test_lv-test"
  end

  # 2026-05-25 — `switch_table` regression test removed. With
  # SessionRouting gone (PR-EM-3 #317 moved its bridge responsibility
  # to ExternalMirror's external_mirror_bindings), MentionRouting is
  # the only table. No table switcher renders — neither in the
  # main_window top-tab strip nor in the resource_panel sidebar.

  test "add_rule via JSON mode supports combinators", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/admin/routing")

    lv |> element("button[phx-value-mode='json']") |> render_click()

    combinator_json =
      Jason.encode!(%{
        "type" => "and",
        "items" => [
          %{"type" => "mention", "arg" => "entity://team-alpha/agent/test_lv-combo"},
          %{"type" => "from", "arg" => "entity://system/user/admin"}
        ]
      })

    lv
    |> form("#add-rule form",
      rule: %{
        table: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
        matcher_json: combinator_json
      }
    )
    |> render_submit(%{rule: %{receivers: ["session://team-alpha/default/oncall"]}})

    html = render(lv)
    assert html =~ ":and"
  end

  test "add_rule rejects empty receivers", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/admin/routing")

    lv
    |> form("#add-rule form",
      rule: %{
        table: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
        matcher_type: "mention"
      }
    )
    |> render_submit(%{rule: %{matcher_arg: "entity://team-alpha/agent/test_x"}})

    html = render(lv)
    assert html =~ "receiver"
  end

  # --- V1 UI PR-1 (SPEC §1.6) — server-side revalidation ---------------------

  test "add_rule rejects a tampered out-of-workspace matcher arg", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/admin/routing")

    # The picker is scoped to workspace://team-alpha; a hand-tampered
    # hidden input naming an entity in another workspace must be
    # rejected server-side, NOT dispatched.
    lv
    |> form("#add-rule form",
      rule: %{
        table: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
        matcher_type: "mention"
      }
    )
    |> render_submit(%{
      rule: %{
        matcher_arg: "entity://other-tenant/agent/cc_evil",
        receivers: ["session://team-alpha/default/oncall"]
      }
    })

    html = render(lv)
    assert html =~ "Rejected URI"
  end

  test "add_rule rejects a tampered out-of-workspace receiver", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/admin/routing")

    lv
    |> form("#add-rule form",
      rule: %{
        table: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
        matcher_type: "mention"
      }
    )
    |> render_submit(%{
      rule: %{
        matcher_arg: "entity://team-alpha/agent/test_ok",
        receivers: ["entity://other-tenant/agent/cc_leak"]
      }
    })

    html = render(lv)
    assert html =~ "Rejected URI"
  end

  test "add_rule rejects a malformed receiver URI", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/admin/routing")

    lv
    |> form("#add-rule form",
      rule: %{
        table: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
        matcher_type: "mention"
      }
    )
    |> render_submit(%{
      rule: %{
        matcher_arg: "entity://team-alpha/agent/test_ok",
        receivers: ["not-a-valid-uri"]
      }
    })

    html = render(lv)
    assert html =~ "Rejected URI"
  end

  # --- Mention-gated routing (SPEC §3 / §6.7) — broadcast option -------------

  test "receiver picker offers the 'All session members (broadcast)' option", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/routing")

    # The broadcast option is prepended to the receiver picker's
    # data-options; selecting it submits the $session_members token.
    assert html =~ "All session members (broadcast)"
    assert html =~ "$session_members"
  end

  test "add_rule accepts the $session_members broadcast token as a receiver", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/admin/routing")

    matcher_arg = "entity://team-alpha/agent/test_bcast-#{System.unique_integer([:positive])}"

    lv
    |> form("#add-rule form",
      rule: %{
        table: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
        matcher_type: "mention"
      }
    )
    |> render_submit(%{rule: %{matcher_arg: matcher_arg, receivers: ["$session_members"]}})

    html = render(lv)
    # The magic token must NOT be rejected as an invalid URI; the rule
    # persists and the token renders as a human-friendly hint.
    refute html =~ "Rejected URI"
    assert html =~ "broadcast"
  end

  test "add_rule accepts $session_users + $mentions magic tokens as receivers", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/admin/routing")

    matcher_arg = "entity://team-alpha/agent/test_mg-#{System.unique_integer([:positive])}"

    lv
    |> form("#add-rule form",
      rule: %{
        table: "Elixir.EzagentDomainInstanceMessage.Routing.MentionRouting",
        matcher_type: "mention"
      }
    )
    |> render_submit(%{
      rule: %{matcher_arg: matcher_arg, receivers: ["$session_users", "$mentions"]}
    })

    html = render(lv)
    refute html =~ "Rejected URI"
  end

  # --- V1 UI PR-2b (SPEC §2.5) — CmdK palette on every ide_shell LV ----------

  # Regression guard: PR-2 wired the CommandPaletteComponent into the
  # `:command_palette` slot of `admin_live.ex` ONLY, so on /routing (and
  # the other non-Admin ide_shell LVs) pressing ⌘K did nothing — the
  # `#cmdk` element wasn't in the DOM. The header search bar + ⌘K are
  # global ide_shell chrome, so SPEC §2.5 requires every ide_shell LV to
  # render the palette. /routing is a non-Admin ide_shell LV — if a
  # future LV is added without the `:command_palette` slot, the same
  # class of gap regresses; this test catches it on at least one of them.
  # 2026-05-25 — /routing was relocated to /admin/routing under the
  # admin scope. The page now ships two tabs: Rules (default) +
  # ExternalMirror Bindings.
  test "tab strip renders Rules + ExternalMirror Bindings entries", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/routing")
    assert html =~ ~s(id="tab-rules")
    assert html =~ ~s(id="tab-bindings")
    assert html =~ "ExternalMirror Bindings"
    # Default tab is Rules — the form-mode editor renders.
    assert html =~ ~s(id="rules-tab")
    refute html =~ ~s(id="bindings-tab")
  end

  test "?tab=bindings switches into the bindings tab (read-only)", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/routing?tab=bindings")
    assert html =~ ~s(id="bindings-tab")
    # bindings-empty surfaces when the admin viewer has no bindings
    # visible (test setup uses bootstrap admin, no bindings created).
    assert html =~ ~s(id="bindings-empty") or html =~ ~s(id="bindings-table")
    refute html =~ ~s(id="rules-tab")
  end

  test "CmdK command palette renders on /admin/routing (admin LV)", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/admin/routing")

    # The CommandPaletteComponent root carries `id="cmdk"` and the
    # `data-cmdk-open` JS push that app.js execJS-es on the ⌘K keybind.
    assert html =~ ~s(id="cmdk")
    assert html =~ "data-cmdk-open"
    assert html =~ "cmdk_open"
  end
end
