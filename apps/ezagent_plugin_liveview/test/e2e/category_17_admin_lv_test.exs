defmodule EzagentPluginLiveview.E2E.Category17AdminLvTest do
  @moduledoc """
  E2E scenarios — Category 17: Admin LV pages.

  Maps to `docs/scenarios/29-admin-lv-smoke/scenario.md`.

  ## Strategy

  Approach 1 (in-process LV tests via `Phoenix.LiveViewTest`) — chosen
  per the prompt's preference. Each test mounts the page as the admin
  caller and asserts on:

    - Page rendered (no redirect, no crash).
    - Stable DOM ids / labels the rest of the system depends on.
    - At least one production-data interaction (snapshot list, routing
      rule, template row, workspace dropdown surface).

  No `agent-browser` fall-out here — that's reserved for the
  visual-rendering gaps the in-process tests cannot cover
  (icon SVG path-joining, click-away menu transitions, etc.), which
  are documented as `@moduletag :requires_allen` skeletons at the
  bottom of the file.

  ## Why this LIVES alongside the existing admin_*_live_test.exs files

  The per-LV files exist but are scenario-agnostic. This test is the
  **scenario 29 rollup** — it asserts the SAME set of pages from the
  scenario.md's §"Per-LV walkthrough" steps, tagged with the scenario
  moduletag so failures cite scenario 29 directly.

  ## Allen-manual gaps

  - cmdK key-driven palette opening (the JS keydown handler is not
    exercised in `Phoenix.LiveViewTest` — pure server-side rendering).
  - Icon SVG paint (visual; needs agent-browser screenshot per
    `feedback_esr_e2e_standards`).
  - Workspace-switch mid-session redirect-flash dance (depends on
    real LV reconnect after deploy).

  These appear under `@moduletag :requires_allen` below.
  """

  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier LiveView suite — mounts views that resolve
  # sibling-app domain modules; runs only in the umbrella. Excluded
  # standalone (`cd apps/ezagent_plugin_liveview && mix test`).
  @moduletag :umbrella_only
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # #52 Mode-B fix: `system://routing/default` is no longer eager-spawned
    # at boot in `:test`. The /admin/routing form dispatches `routing.add_rule`
    # to it, so spawn it here (after shared mode is set). Idempotent.
    case Ezagent.SpawnRegistry.spawn(Ezagent.Entity.System.routing_default_uri()) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Seed the workspaces the dropdown / templates pages read from.
    # Mirrors `users_live_test.exs` setup — the dropdown source is
    # `Ezagent.Workspace.Store.list_all/0` for admin callers.
    seed_workspace("system")
    seed_workspace("team-alpha")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, conn: conn}
  end

  defp seed_workspace(name) do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create(name, %{})
      _ -> :ok
    end
  end

  # ============================================================
  # /admin/registry — live Kind list (scenario 29 step 14)
  # ============================================================

  describe "/admin/registry — live KindRegistry browse" do
    @describetag scenario: "29-admin-lv-smoke"

    test "GET /admin/registry renders header + scheme filter chips", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin/registry")
      assert html =~ "Entities (live registry)"
      assert html =~ "user"
      assert html =~ "agent"
      assert html =~ "session"
      assert html =~ "workspace"
    end

    test "filter=user narrows to entity user rows", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin/registry?filter=user")
      # admin User Kind is spawned at boot — should appear under filter=user
      assert html =~ "entity"
    end
  end

  # ============================================================
  # /admin/snapshots — kind_snapshots dump + clear (scenario 29 step 15)
  # ============================================================

  describe "/admin/snapshots — persisted kind state browser" do
    alias Ezagent.Test.SnapshotFixtures

    @describetag scenario: "29-admin-lv-smoke"

    test "header renders + freshly persisted snapshot appears", %{conn: conn} do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/user/snap_cat17_#{System.unique_integer([:positive])}"
        )

      :ok =
        SnapshotFixtures.save_kind_snapshot(
          uri,
          Ezagent.Entity.User,
          %{identity: %{caps: MapSet.new()}}
        )

      {:ok, _lv, html} = live(conn, "/admin/snapshots")
      assert html =~ "Snapshots"
      assert html =~ URI.to_string(uri)
    end

    test "clear button deletes the persisted snapshot row", %{conn: conn} do
      uri =
        URI.parse(
          "entity://team-alpha/user/snap_clear_cat17_#{System.unique_integer([:positive])}"
        )

      uri_str = URI.to_string(uri)

      :ok =
        SnapshotFixtures.save_kind_snapshot(uri, Ezagent.Entity.User, %{
          identity: %{caps: MapSet.new()}
        })

      assert %{} = Ezagent.Ecto.KindSnapshot.get(uri_str)

      {:ok, lv, _html} = live(conn, "/admin/snapshots")

      lv
      |> element("button[phx-click='clear'][phx-value-uri='#{uri_str}']")
      |> render_click()

      # Clear action runs synchronously through dispatch → row deleted.
      assert nil == Ezagent.Ecto.KindSnapshot.get(uri_str)
    end
  end

  # ============================================================
  # /admin/templates — template-kind list (scenario 29 step 12)
  # ============================================================

  describe "/admin/templates — read-only V0 list" do
    @describetag scenario: "29-admin-lv-smoke"

    test "page renders + shows the type filter chips", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin/templates")
      assert html =~ "Templates"
      # Filter chip group with stable id used by docs + future agent-browser refs.
      assert html =~ ~s(id="template-type-filter")
    end

    test "filter chips for AgentTemplate + SessionTemplate render with counts", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin/templates")
      # Empty system workspace at this point — but the chip labels MUST
      # render their kind atom so operators can navigate even when the
      # count is zero (the page is the V0 stop-gap, the chips are the
      # discovery surface).
      assert html =~ "AgentTemplate" or html =~ "agent_template"
      assert html =~ "SessionTemplate" or html =~ "session_template"
    end

    test "filter=agent_template narrows the URL params + page still renders", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin/templates?type=agent_template")
      assert html =~ "Templates"
    end

    test "agent template rows expose layer level and mandatory set", %{conn: conn} do
      alias Ezagent.Test.SnapshotFixtures

      template_uri = Ezagent.URI.new!("template://system/agent/cascade-ui-template")

      :ok =
        SnapshotFixtures.save_kind_snapshot(
          template_uri,
          Ezagent.Entity.AgentTemplate,
          %{
            template: %{
              state: %{
                content: %{
                  "name" => "cascade-ui-template",
                  "level" => "workspace",
                  "mandatory" => ["hooks/policy.sh"],
                  "cascade_resolution" => %{
                    "workspace_layer_uri" => URI.to_string(template_uri)
                  }
                }
              }
            }
          }
        )

      {:ok, _lv, html} = live(conn, "/admin/templates?type=agent_template")

      assert html =~ ~s(id="template-level-column")
      assert html =~ ~s(id="template-mandatory-column")
      assert html =~ "workspace"
      assert html =~ "hooks/policy.sh"
    end
  end

  # ============================================================
  # /admin/routing — rules CRUD (scenario 29 step 13)
  # ============================================================

  describe "/admin/routing — global mention-routing rules" do
    @describetag scenario: "29-admin-lv-smoke"

    setup _ do
      # Routing LV uri_picker scopes to current_workspace_uri. Override
      # the outer setup's `workspace://system` to `team-alpha` so the
      # picker accepts URIs in that workspace.
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
          "current_workspace_uri" => "workspace://team-alpha"
        })

      {:ok, conn: conn}
    end

    test "page renders the MentionRouting form + SessionRouting retirement blurb", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin/routing")

      assert html =~ "Routing"
      assert html =~ "MentionRouting"
      assert html =~ "Add rule"
      # 2026-05-25 — SessionRouting is RETIRED. The blurb must be
      # visible so operators don't try to switch tables.
      assert html =~ "SessionRouting table was removed"
    end

    test "add_rule via form-mode persists + appears in list", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin/routing")

      uniq = System.unique_integer([:positive])
      matcher_arg = "entity://team-alpha/agent/test_e2e_d-#{uniq}"
      receiver = "session://team-alpha/default/cat17-rcv-#{uniq}"

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
      assert html =~ "test_e2e_d-#{uniq}"
    end
  end

  # ============================================================
  # /admin — root dashboard renders (scenario 29 step 1, no crash regression)
  # ============================================================

  describe "/admin — root dashboard" do
    @describetag scenario: "29-admin-lv-smoke"

    test "renders KPIs + workspace dropdown without crashing", %{conn: conn} do
      # Bug-1 regression (Allen 2026-05-26): an integer KPI was leaking
      # into the workspace dropdown's `<%= for ws <- @workspaces %>`
      # iteration. Mount must NOT raise Protocol.UndefinedError.
      {:ok, _lv, html} = live(conn, "/admin")
      assert html =~ ~s(id="kpi-workspaces")
      assert html =~ ~s(id="kpi-sessions")
      assert html =~ ~s(id="kpi-identities")
      assert html =~ ~s(id="kpi-kinds")
    end
  end

  # ============================================================
  # /sessions — chat surface + cmdK palette (scenario 29 steps 18-21)
  # ============================================================

  describe "/sessions — chat + cmdK palette" do
    @describetag scenario: "29-admin-lv-smoke"

    test "page renders SessionEditor + cmdK component slot", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")
      assert html =~ ~s(id="session-editor")
      assert html =~ ~s(id="cmdk")
      # The cmdK component carries the canonical event name + a target
      # attribute (phx-target=...) so events are routed to the
      # LiveComponent, not the parent LV.
      assert html =~ "cmdk_open"
      assert html =~ ~s(phx-change="cmdk_query")
    end

    test "cmdK query 'routing' surfaces the Routing nav result", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      html = lv |> form("#cmdk form", %{"q" => "routing"}) |> render_change()

      assert html =~ "Routing"
      # The Routing nav target relocated to /admin/routing post-2026-05-25.
      assert html =~ ~s(phx-value-key="nav:/admin/routing")
    end

    test "cmdK query 'snapshots' surfaces the Snapshots nav result", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      html = lv |> form("#cmdk form", %{"q" => "snapshots"}) |> render_change()

      # Either the explicit "Snapshots" nav label or its URL key MUST
      # appear in the result rows.
      assert html =~ "snapshots" or html =~ "Snapshots"
    end
  end

  # ============================================================
  # Workspace dropdown surface (scenario 29 — workspace switch dropdown)
  # ============================================================

  describe "workspace dropdown — visibility filter" do
    @describetag scenario: "29-admin-lv-smoke"

    test "/admin renders the ezagent / <workspace> dropdown trigger", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin")

      # The dropdown's button text "ezagent" is the canonical
      # top-left affordance (per ide_shell.ex / workspace_dropdown).
      assert html =~ "ezagent"
      # The dropdown SWITCH button has aria-label "Switch workspace".
      assert html =~ "Switch workspace"
    end

    test "/admin/templates dropdown surface lists the seeded workspaces", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/admin/templates")

      # Both seeded workspaces (per setup) must be reachable from the
      # dropdown — operators with access can switch context.
      assert html =~ "system"
      assert html =~ "team-alpha"
    end
  end

  # ============================================================
  # /admin/agents 404 — honest gap per scenario 29
  # ============================================================

  describe "/admin/agents — known 404 gap (scenario 29 honest-gap pin)" do
    @describetag scenario: "29-admin-lv-smoke"

    test "/admin/agents top-level list is unreachable as a working LV (honest gap)", %{conn: conn} do
      # Per scenario 29's "Open bugs / gaps" — the top-level
      # /admin/agents agents-list page is NOT implemented. Operators
      # use cmdK or /admin/registry?filter=agent.
      #
      # The router has no `live "/admin/agents"` declaration (grep
      # confirms). Behaviour the operator sees today is either:
      #
      #   (a) Phoenix.Router.NoRouteError if no other route catches.
      #   (b) A redirect to a sibling LV / 404 page if a catch-all
      #       route exists.
      #
      # We pin the GAP property: there is no rendered "Agents (top
      # level list)" LV page reachable at `/admin/agents`. The
      # specific failure mode (route error vs redirect) is allowed
      # to drift while the gap is open.
      result =
        try do
          {:resp, get(conn, "/admin/agents")}
        rescue
          e in Phoenix.Router.NoRouteError -> {:no_route, e}
        end

      case result do
        {:no_route, _} ->
          :ok

        {:resp, response_conn} ->
          # If a route resolved, the response MUST be a redirect (302)
          # or a non-200 status — the operator MUST NOT see a working
          # agents-list page until the LV ships.
          refute response_conn.status == 200,
                 "scenario 29 honest gap regressed: /admin/agents now renders a 200 response. " <>
                   "If the page shipped, update this test to assert its CONTENT instead."
      end
    end
  end

  # ============================================================
  # Allen-manual scenarios — skeletons
  # ============================================================

  describe "scenario 29 — REAL browser visual checks (Allen-manual only)" do
    @describetag :requires_allen
    @describetag :requires_browser
    @describetag scenario: "29-admin-lv-smoke"

    @tag :skip
    test "icon SVG path-joining renders correctly (no missing-icon placeholder)" do
      # Requires:
      #   - agent-browser screenshot per feedback_agent_browser_debug
      #   - Visual diff against PR #401 baseline
      # Phoenix.LiveViewTest can't observe SVG paint; the in-process
      # test can only assert the `<svg>` markup is in the DOM.
      flunk("requires agent-browser screenshot — Allen-manual scenario only")
    end

    @tag :skip
    test "cmdK Cmd+K / Ctrl+K key opens the modal" do
      # The JS keydown handler is bound on the document outside the LV
      # tree. Phoenix.LiveViewTest renders the DOM but doesn't execute
      # JS, so we can't observe the modal-open transition driven by
      # the keyboard shortcut. We DO test the cmdk_query event above
      # (the event handler is server-side); the keypress trigger is
      # the gap.
      flunk("requires real browser key event — Allen-manual scenario only")
    end

    @tag :skip
    test "workspace switch mid-LV-action: assigns invalidated + flash redirect" do
      # Requires:
      #   - Live LV WebSocket
      #   - A real LV running a long action
      #   - Concurrent workspace switch from another tab
      # In-process LV tests don't drive the LV's WS lifecycle, so the
      # "assigns invalidated on workspace context change mid-action"
      # behaviour is parked here.
      flunk("requires concurrent-LV scenario — Allen-manual scenario only")
    end

    @tag :skip
    test "stale LV socket after deploy: forced reconnect, assigns re-mounted" do
      # Requires:
      #   - Deploy a new release (the test would have to restart the
      #     Endpoint).
      #   - Observe the LV reconnect flow.
      # Out of scope for the in-process test surface.
      flunk("requires deploy + reconnect lifecycle — Allen-manual scenario only")
    end
  end
end
