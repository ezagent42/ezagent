defmodule EzagentDomainUi.Pty.TerminalViewTest do
  @moduledoc """
  Domain.Pty PR-C — coverage for `EzagentDomainUi.Pty.TerminalView`.

  Verifies the SessionView callbacks, the safe-default behavior of
  `applies_to?/1` (returns false when the session Kind is not alive),
  and the cross-flavor detection contract (the impl must consult
  `Ezagent.Domain.Pty.alive?/1` — not match on the cc-flavored name
  prefix).
  """

  use ExUnit.Case, async: false

  alias EzagentDomainUi.Pty.TerminalView

  describe "SessionView contract" do
    test "id/label/icon are stable" do
      assert TerminalView.id() == :pty
      assert TerminalView.label() == "Terminal"
      assert TerminalView.icon() == "terminal"
    end

    test "implements Ezagent.UI.SessionView" do
      behaviours = TerminalView.module_info(:attributes)[:behaviour] || []
      assert Ezagent.UI.SessionView in behaviours
    end
  end

  describe "applies_to?/1" do
    test "returns false for non-URI input" do
      refute TerminalView.applies_to?(nil)
      refute TerminalView.applies_to?("entity://agent/team-alpha/cc_demo")
      refute TerminalView.applies_to?(:atom)
    end

    test "returns false when the session Kind is not registered" do
      # No real session spawned — KindRegistry.lookup/1 returns :error,
      # which the impl converts to `false` (safe-default failure mode:
      # the Terminal tab simply doesn't show up).
      missing = URI.new!("session://default/team-alpha/missing-#{System.unique_integer([:positive])}")
      refute TerminalView.applies_to?(missing)
    end
  end

  describe "render/1" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "renders empty-state copy when no active agent" do
      html = render_component(&TerminalView.render/1, active_pty_agent_uri: nil)

      # Renders through the unified Terminal.panel/1 — the :bar header
      # is always present; the empty state explains how to attach.
      assert html =~ "Terminal —"
      assert html =~ "PTY-backed agent"
      # No xterm mount when no active agent.
      refute html =~ ~s(phx-hook="PtyTerminal")
    end

    test "renders xterm mount when active_pty_agent_uri is set" do
      uri_str = "entity://agent/team-alpha/cc_demo"
      html = render_component(&TerminalView.render/1, active_pty_agent_uri: uri_str)

      assert html =~ "Terminal —"
      assert html =~ uri_str
      assert html =~ ~s(phx-hook="PtyTerminal")
      assert html =~ ~s(phx-update="ignore")
    end
  end

  describe "cross-flavor detection (contract)" do
    test "applies_to? source delegates to Ezagent.Domain.Pty.alive?/1" do
      # The impl must use the Domain.Pty facade for member detection
      # — NOT a hard-coded `cc_` flavor prefix. We assert this
      # structurally by reading the source and matching the
      # `Ezagent.Domain.Pty.alive?` call.
      src =
        Path.join([
          File.cwd!(),
          "lib",
          "ezagent_domain_ui",
          "pty",
          "terminal_view.ex"
        ])
        |> File.read!()

      assert src =~ "Ezagent.Domain.Pty.alive?",
             "TerminalView.applies_to? must consult Ezagent.Domain.Pty.alive?/1 for cross-flavor detection"

      refute src =~ ~S|String.starts_with?(entity_name, "cc_")|,
             "TerminalView must NOT hard-code the cc_ flavor prefix — that was the old PtyView shape"
    end
  end
end
