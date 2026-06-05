defmodule EzagentDomainUi.Pty.TerminalTest do
  @moduledoc """
  Domain.Pty PR-C — `EzagentDomainUi.Pty.Terminal` Phoenix.Component
  contract. The component is the bare xterm.js mount point reused by
  the SessionView, the standalone TerminalLive (PR-D), and the inline
  agent-detail expander (PR-D).
  """

  use ExUnit.Case, async: true

  alias EzagentDomainUi.Pty.Terminal

  import Phoenix.LiveViewTest, only: [render_component: 2]

  describe "pty_dom_id/1" do
    test "builds a stable, encoded id from a string URI" do
      assert Terminal.pty_dom_id("entity://team-alpha/agent/cc_demo") =~ "pty-terminal-"
    end

    test "accepts a %URI{} struct" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_demo")
      assert Terminal.pty_dom_id(uri) == Terminal.pty_dom_id(URI.to_string(uri))
    end

    test "returns a safe fallback for bad input" do
      assert Terminal.pty_dom_id(nil) == "pty-terminal-none"
      assert Terminal.pty_dom_id(123) == "pty-terminal-none"
    end
  end

  describe "mount/1" do
    test "renders the xterm.js mount point with the PtyTerminal hook" do
      html = render_component(&Terminal.mount/1, agent_uri: "entity://team-alpha/agent/cc_demo")

      assert html =~ ~s(phx-hook="PtyTerminal")
      assert html =~ ~s(phx-update="ignore")
      assert html =~ ~s(id="pty-terminal-)
    end

    test "accepts a custom class via attr" do
      html =
        render_component(&Terminal.mount/1,
          agent_uri: "entity://team-alpha/agent/cc_demo",
          class: "h-64 w-full"
        )

      assert html =~ "h-64 w-full"
    end
  end
end
