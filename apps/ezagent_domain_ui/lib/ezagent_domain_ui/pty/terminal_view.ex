defmodule EzagentDomainUi.Pty.TerminalView do
  @moduledoc """
  Domain.Pty PR-C — Session view: xterm.js terminal for any session
  member backed by a live PTY.

  Moved from `EzagentPluginCc.Views.PtyView` (cc plugin, Tier-3) to
  `EzagentDomainUi.Pty.TerminalView` (Tier-2 Domain UI) per SPEC v1
  §3.2 + §5.1 (2026-05-21). Now any PTY-backed agent flavor — current
  cc, echo with `with_pty: true`, curl with PTY support, etc. — gets the
  terminal view for free.

  Renders the `PtyTerminal` JS hook (xterm.js mount). The active agent
  URI is owned by the wrapping admin_live as `@active_pty_agent_uri`
  (set when the operator clicks a Members panel PTY button, or when
  the view-switcher opens with a default PTY-backed member).

  **Cross-flavor detection** (`applies_to?/1`): query the Session
  Kind's members, for each member URI ask `Ezagent.Domain.Pty.alive?/1`;
  if any returns true the Terminal tab is offered. This replaces the
  prior cc-name convention check — that was a structural cc-plugin
  assumption; with PTY promoted to Domain tier the detection is purely
  behavioral.

  Registered by `EzagentDomainUi.Application.start/2`.
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component
  # i18n (Allen 2026-05-22) — Tier-2 shared-component backend. NOT a
  # dependency on `ezagent_web` (see `EzagentDomainUi.Gettext` moduledoc).
  use Gettext, backend: EzagentDomainUi.Gettext

  alias EzagentDomainUi.Pty.Terminal

  @impl true
  def id, do: :pty

  @impl true
  def label, do: gettext("Terminal")

  @impl true
  def icon, do: "terminal"

  @impl true
  def applies_to?(%URI{} = session_uri) do
    # Read the chat slice through the T3-normalized accessor
    # (`Kind.get_slice/2`). Post-lifecycle the on-process slice is
    # two-container (`%{state: …, transients: …}`); the old
    # the old raw Kind state match returned the
    # two-container wrapper, so `slice.members` raised → caught → false,
    # and the Terminal tab never became applicable even with a live
    # PTY-backed member. (post-lifecycle remediation.)
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{members: members}} when is_map(members) ->
        members
        |> Map.keys()
        |> Enum.any?(&pty_backed_member?/1)

      _ ->
        false
    end
  end

  def applies_to?(_), do: false

  # Cross-flavor: any session member whose Domain.Pty server is alive
  # makes the Terminal tab applicable. No hard-coded `cc_` prefix —
  # echo-with-pty, curl-with-pty, future flavors all qualify.
  defp pty_backed_member?(%URI{} = uri), do: Ezagent.Domain.Pty.alive?(uri)
  defp pty_backed_member?(_), do: false

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :active_pty_agent_uri, fn -> nil end)

    # Renders through the ONE unified terminal panel
    # (`EzagentDomainUi.Pty.Terminal.panel/1`) — same component the
    # standalone TerminalLive page and the inline AgentDetailLive panel
    # use. The SessionView only picks the header mode + empty-state copy
    # appropriate for the view-switcher; no terminal markup is
    # reimplemented here.
    ~H"""
    <Terminal.panel
      agent_uri={@active_pty_agent_uri}
      header={:bar}
      empty_text="Click the terminal icon next to a PTY-backed agent in the Members panel to attach."
      class="flex-1"
    />
    """
  end
end
