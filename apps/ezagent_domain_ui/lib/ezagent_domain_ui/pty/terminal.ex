defmodule EzagentDomainUi.Pty.Terminal do
  @moduledoc """
  Domain.Pty PR-C — Phoenix.Component wrapping the xterm.js mount
  point for a single agent's PTY.

  This is the bare component (mount point div + JS hook attachment).
  It's consumed by:

  - `EzagentDomainUi.Pty.TerminalView` — the Session-view SessionView
    impl (wraps it with a header + empty state for the
    view-switcher's `:pty` tab).
  - PR-D's `TerminalLive` (standalone `/identities/agents/:uri/terminal`
    page) — wraps it inside `IdeShell` for a full-window terminal.
  - PR-D's `AgentDetailLive` inline expander — drops it into the
    agent detail page in collapsible form.

  Same xterm.js hook (`phx-hook="PtyTerminal"`); the host LV owns
  `pty_input` / `pty_resize` / `pty_chunk` event plumbing. This
  component just gives the JS hook a DOM anchor.

  The DOM id is derived from the agent URI so switching attached
  agents recreates the xterm instance instead of trying to re-mount
  onto a stale buffer.
  """

  use Phoenix.Component

  attr :agent_uri, :any,
    required: true,
    doc: "Agent entity URI (string or %URI{}); used to derive the DOM id"

  attr :class, :string, default: "flex-1 min-h-0"

  def mount(assigns) do
    ~H"""
    <div
      id={pty_dom_id(@agent_uri)}
      phx-hook="PtyTerminal"
      phx-update="ignore"
      class={@class}
    ></div>
    """
  end

  @doc """
  Build a stable, unique DOM id for the xterm container of a given
  agent URI. Exposed so callers (e.g. host LV) can target it for
  push-events.
  """
  def pty_dom_id(uri_str) when is_binary(uri_str),
    do: "pty-terminal-" <> Base.url_encode64(uri_str, padding: false)

  def pty_dom_id(%URI{} = uri), do: pty_dom_id(URI.to_string(uri))
  def pty_dom_id(_), do: "pty-terminal-none"
end
