defmodule EzagentPluginLiveview.AgentDetailLiveTest do
  @moduledoc """
  Domain.Pty PR-D — coverage for the inline-terminal change to
  `AgentDetailLive`.

  Per SPEC §5.3:

    * Agent WITH live PTY → inline `<details>` "Terminal" panel
      appears, contains the xterm mount + an "Open in full page" link
      to `/identities/agents/:uri/terminal`.
    * Agent WITHOUT PTY → terminal section absent entirely
      (`feedback_ui_no_misleading_buttons`: don't show "Terminal"
      headings when there's no PTY behind it).
    * The pre-PR-D "Open terminal (in Sessions)" button is gone.

  Tests use the standard sandbox setup; cc agents are spawned via the
  same SpawnRegistry + Domain.Pty.start path used in production.
  """
  use ExUnit.Case

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

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  describe "inline terminal panel (SPEC §5.3)" do
    test "PTY-alive cc agent renders the inline Terminal details panel + full-page link",
         %{conn: conn} do
      agent_uri =
        Ezagent.URI.new!("entity://team-alpha/agent/cc_inline-#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent_with_flavor(agent_uri, "cc")

      {:ok, _pty_pid} = Ezagent.Domain.Pty.start(agent_uri, %{cwd: "/tmp", test_mode: true})

      try do
        encoded = URI.encode_www_form(URI.to_string(agent_uri))
        {:ok, _lv, html} = live(conn, "/identities/agents/#{encoded}")

        # The collapsed `<details>` is present with the "Terminal" summary.
        assert html =~ "id=\"agent-inline-terminal\""
        assert html =~ "Terminal</summary>" or html =~ "Terminal\n"

        # Full-page link points to the standalone TerminalLive route.
        assert html =~ "/identities/agents/#{encoded}/terminal"

        # The xterm.js mount point is in the DOM (collapsed but
        # rendered — the hook attaches on expand).
        assert html =~ ~s(phx-hook="PtyTerminal")

        # Per `feedback_ui_no_misleading_buttons` — the pre-PR-D
        # "Open terminal (in Sessions)" button must be GONE.
        refute html =~ "Open terminal (in Sessions)"
      after
        :ok = Ezagent.Domain.Pty.stop(agent_uri)
      end
    end

    test "PTY-alive non-cc agent renders the inline Terminal details panel", %{conn: conn} do
      agent_uri =
        Ezagent.URI.new!("entity://team-alpha/agent/codex_inline-#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent_with_flavor(agent_uri, "codex")

      {:ok, _pty_pid} = Ezagent.Domain.Pty.start(agent_uri, %{cwd: "/tmp", test_mode: true})

      try do
        encoded = URI.encode_www_form(URI.to_string(agent_uri))
        {:ok, _lv, html} = live(conn, "/identities/agents/#{encoded}")

        assert html =~ "id=\"agent-inline-terminal\""
        assert html =~ "Running (codex)"
        assert html =~ ~s(phx-hook="PtyTerminal")
      after
        :ok = Ezagent.Domain.Pty.stop(agent_uri)
      end
    end

    test "agent WITHOUT PTY has no Terminal panel at all", %{conn: conn} do
      # Echo agent — no PTY behind it. Per SPEC §5.3 + feedback_ui_no_misleading_buttons,
      # we don't surface a terminal UI when there's nothing to render.
      agent_uri =
        Ezagent.URI.new!("entity://team-alpha/agent/echo_d-#{System.unique_integer([:positive])}")

      {:ok, _pid} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(agent_uri, "echo")

      encoded = URI.encode_www_form(URI.to_string(agent_uri))
      {:ok, _lv, html} = live(conn, "/identities/agents/#{encoded}")

      # No inline terminal card.
      refute html =~ "id=\"agent-inline-terminal\""
      # No xterm mount point.
      refute html =~ ~s(phx-hook="PtyTerminal")
      # No "Open terminal in Sessions" jump button either.
      refute html =~ "Open terminal (in Sessions)"
    end
  end

  describe "PTY event seam (SPEC §5.3 wiring)" do
    test "pty_resize event is handled (no-op) without crashing the LV", %{conn: conn} do
      agent_uri =
        Ezagent.URI.new!("entity://team-alpha/agent/cc_resize-#{System.unique_integer([:positive])}")

      {:ok, _pid} =
        Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent_with_flavor(agent_uri, "cc")

      {:ok, _pty_pid} = Ezagent.Domain.Pty.start(agent_uri, %{cwd: "/tmp", test_mode: true})

      try do
        encoded = URI.encode_www_form(URI.to_string(agent_uri))
        {:ok, lv, _html} = live(conn, "/identities/agents/#{encoded}")

        render_hook(lv, "pty_resize", %{"cols" => 80, "rows" => 24})

        assert Process.alive?(lv.pid)
      after
        :ok = Ezagent.Domain.Pty.stop(agent_uri)
      end
    end
  end
end
