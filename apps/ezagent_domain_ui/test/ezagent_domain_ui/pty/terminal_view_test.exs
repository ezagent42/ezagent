defmodule EzagentDomainUi.Pty.TerminalViewTest do
  @moduledoc """
  Domain.Pty PR-C — coverage for `EzagentDomainUi.Pty.TerminalView`.

  Verifies the SessionView callbacks, the safe-default behavior of
  `applies_to?/1` (returns false when the session Kind is not alive),
  and the cross-flavor detection contract (the impl must consult
  `Ezagent.Domain.Pty.alive?/1` — not match on the cc-flavored name
  prefix).
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [ensure_workspace_kind!: 1]

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.Session
  alias EzagentDomainUi.Pty.TerminalView

  @workspace_uri URI.new!("workspace://system")
  @owner_uri URI.new!("entity://system/user/admin")

  setup do
    ensure_workspace_kind!(@workspace_uri)
    :ok
  end

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
      refute TerminalView.applies_to?("entity://team-alpha/agent/cc_demo")
      refute TerminalView.applies_to?(:atom)
    end

    test "returns false when the session Kind is not registered" do
      # No real session spawned — KindRegistry.lookup/1 returns :error,
      # which the impl converts to `false` (safe-default failure mode:
      # the Terminal tab simply doesn't show up).
      missing =
        URI.new!("session://team-alpha/default/missing-#{System.unique_integer([:positive])}")

      refute TerminalView.applies_to?(missing)
    end

    test "accepts a materializing admission with a live PTY" do
      session_uri = live_session!()
      candidate = entity_uri("materializing")
      start_live_pty!(candidate)

      put_admissions!(session_uri, [admission("materializing", :materializing, candidate)])

      assert TerminalView.applies_to?(session_uri)
    end

    test "rejects inactive, malformed, non-entity, and non-live admission candidates" do
      session_uri = live_session!()
      inactive_candidate = entity_uri("inactive")
      non_entity_candidate = URI.new!("resource://system/pty/non-entity-#{unique_suffix()}")
      non_live_candidate = entity_uri("non-live")
      start_live_pty!(inactive_candidate)
      start_live_pty!(non_entity_candidate)

      put_admissions!(session_uri, [
        admission("inactive", :joined, inactive_candidate),
        admission("non-entity", :materializing, non_entity_candidate),
        admission("non-live", :materializing, non_live_candidate),
        %{role_name: "malformed", status: :materializing},
        %{role_name: "bad-uri", status: :materializing, provisional_agent_uri: "not a URI"}
      ])

      refute TerminalView.applies_to?(session_uri)
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
      uri_str = "entity://team-alpha/agent/cc_demo"
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

      refute src =~ "starts_with?",
             "TerminalView must NOT hard-code flavor-name prefix checks — that was the old PtyView shape"
    end
  end

  defp live_session! do
    session_uri =
      URI.new!("session://system/generic/terminal-view-#{unique_suffix()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors(),
        owner_uri: @owner_uri
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> terminate_session(session_uri) end)
    session_uri
  end

  defp start_live_pty!(uri) do
    {:ok, pid} = Ezagent.Domain.Pty.start(uri, %{cwd: File.cwd!(), test_mode: true})
    on_exit(fn -> if Process.alive?(pid), do: Ezagent.Domain.Pty.stop(uri) end)
    assert Ezagent.Domain.Pty.alive?(uri)
  end

  defp put_admissions!(session_uri, admissions) do
    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(:agent_admissions, Map.new(admissions, &{&1.role_name, &1}))

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)
  end

  defp admission(role_name, status, provisional_agent_uri) do
    %{
      role_name: role_name,
      status: status,
      provisional_agent_uri: URI.to_string(provisional_agent_uri)
    }
  end

  defp entity_uri(label),
    do: URI.new!("entity://system/agent/#{label}-#{unique_suffix()}")

  defp unique_suffix, do: System.unique_integer([:positive])

  defp terminate_session(uri) do
    if Ezagent.Kind.alive?(uri), do: Ezagent.Kind.terminate(uri)
  end
end
