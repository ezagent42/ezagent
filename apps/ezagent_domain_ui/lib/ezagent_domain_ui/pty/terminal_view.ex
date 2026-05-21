defmodule EzagentDomainUi.Pty.TerminalView do
  @moduledoc """
  Domain.Pty PR-C — Session view: xterm.js terminal for any session
  member backed by a live PTY.

  Moved from `EzagentPluginCc.Views.PtyView` (cc plugin, Tier-3) to
  `EzagentDomainUi.Pty.TerminalView` (Tier-2 Domain UI) per SPEC v1
  §3.2 + §5.1 (2026-05-21). Now any PTY-backed agent flavor — current
  `cc_*`, future `echo_*` with `with_pty: true`, future
  `curl_*-with-pty`, etc. — gets the terminal view for free.

  Renders the `PtyTerminal` JS hook (xterm.js mount). The active agent
  URI is owned by the wrapping admin_live as `@active_pty_agent_uri`
  (set when the operator clicks a Members panel PTY button, or when
  the view-switcher opens with a default PTY-backed member).

  **Cross-flavor detection** (`applies_to?/1`): query the Session
  Kind's members, for each member URI ask `Ezagent.Domain.Pty.alive?/1`;
  if any returns true the Terminal tab is offered. This replaces the
  prior cc-flavor name-prefix check (`String.starts_with?(name, "cc_")`)
  — that was a structural cc-plugin assumption; with PTY promoted to
  Domain tier the detection is purely behavioral.

  Registered by `EzagentDomainUi.Application.start/2`.
  """

  @behaviour Ezagent.UI.SessionView
  use Phoenix.Component

  alias EzagentDomainUi.Pty.Terminal

  @impl true
  def id, do: :pty

  @impl true
  def label, do: "Terminal"

  @impl true
  def icon, do: "terminal"

  @impl true
  def applies_to?(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        try do
          %{state: %{chat: slice}} = :sys.get_state(pid, 200)

          slice.members
          |> Map.keys()
          |> Enum.any?(&pty_backed_member?/1)
        catch
          _, _ -> false
        end

      :error ->
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

    ~H"""
    <div class="flex-1 flex flex-col bg-black text-zinc-200 min-h-0">
      <div class="px-3 py-1 text-[11px] text-zinc-400 bg-zinc-900 border-b border-zinc-800 shrink-0">
        Terminal —
        <span class="font-mono">{@active_pty_agent_uri || "select a PTY-backed agent from Members panel"}</span>
      </div>

      <div :if={is_nil(@active_pty_agent_uri)} class="flex-1 flex items-center justify-center text-zinc-500 text-xs">
        Click the terminal icon next to a PTY-backed agent in the Members panel to attach.
      </div>

      <Terminal.mount :if={@active_pty_agent_uri} agent_uri={@active_pty_agent_uri} />
    </div>
    """
  end
end
