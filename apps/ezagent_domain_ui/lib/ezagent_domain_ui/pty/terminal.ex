defmodule EzagentDomainUi.Pty.Terminal do
  @moduledoc """
  Domain.Pty — the ONE unified PTY terminal UI component.

  Owned at the Domain (Tier-2) layer per the Domain.Pty migration's
  whole point: "any flavor gets terminal-viewing for free". This is the
  single source of terminal rendering — the xterm.js mount, the black
  terminal chrome, the optional header bar, and the empty state. Every
  surface that shows a PTY renders through this component; they differ
  only by container/size, never by reimplementing terminal markup.

  ## Consumers

  - `EzagentPluginLiveview.TerminalLive` — the full-page terminal at
    `/identities/agents/:uri/terminal`.
  - `EzagentPluginLiveview.AgentDetailLive` — the inline collapsible
    PTY panel on the agent detail page.
  - `EzagentDomainUi.Pty.TerminalView` — the `:pty` SessionView tab in
    the /sessions view-switcher.

  Before this consolidation each of those hand-rolled its own header +
  black `<div>` + empty state around the bare `mount/1` div. Now they
  call `panel/1` (the full panel) — or `mount/1` directly if they only
  need the bare xterm anchor.

  ## Two entry points

  - `panel/1` — the full terminal panel: header (optional) + black
    chrome + xterm mount, OR an empty state when no agent is attached.
    This is what surfaces should use.
  - `mount/1` — the bare xterm.js mount-point div (the JS hook anchor).
    `panel/1` delegates to it. Exposed for the rare caller that owns
    its own chrome.

  Same xterm.js hook (`phx-hook="PtyTerminal"`); the host LV owns the
  `pty_input` / `pty_resize` / `pty_chunk` event plumbing. The shared
  `EzagentDomainUi.Pty.TerminalSeam` module gives host LVs the
  subscribe / buffer-replay / fan-out / dispatch helpers so that
  plumbing is also written once.

  The DOM id is derived from the agent URI so switching attached
  agents recreates the xterm instance instead of trying to re-mount
  onto a stale buffer.
  """

  use Phoenix.Component

  @doc """
  The unified terminal panel — header (optional) + black chrome +
  xterm mount, or an empty state when `agent_uri` is `nil`.

  This is the single rendering path for every PTY surface. Callers
  pick a `header` mode and a `class`; everything inside (chrome,
  xterm, empty state) is identical regardless of surface.

  Attrs:

    * `:agent_uri` — agent entity URI (string or `%URI{}`) the terminal
      is attached to, or `nil` to render the empty state.
    * `:header` — `:none` (no header bar) | `:bar` (a thin header bar
      showing the agent URI). Default `:bar`.
    * `:empty_text` — copy shown when `agent_uri` is `nil`. Default a
      generic "attach a PTY-backed agent" message.
    * `:class` — extra classes on the outer panel wrapper. Use this to
      size the panel (`h-full`, `h-[420px]`, `flex-1 min-h-0`, …).
  """
  attr :agent_uri, :any,
    default: nil,
    doc: "Agent entity URI (string or %URI{}); nil renders the empty state"

  attr :header, :atom,
    default: :bar,
    values: [:none, :bar],
    doc: ":bar shows a thin header with the agent URI; :none omits it"

  attr :empty_text, :string,
    default:
      "Attach a PTY-backed agent to view its terminal.",
    doc: "Copy shown when no agent is attached"

  attr :class, :string,
    default: "flex-1 min-h-0",
    doc: "Extra classes on the outer panel wrapper (size the panel here)"

  def panel(assigns) do
    ~H"""
    <div class={["flex flex-col bg-black text-zinc-200 min-h-0 overflow-hidden", @class]}>
      <div
        :if={@header == :bar}
        class="px-3 py-1 text-[11px] text-zinc-400 bg-zinc-900 border-b border-zinc-800 shrink-0"
      >
        Terminal —
        <span class="font-mono">
          {agent_uri_str(@agent_uri) || "no agent attached"}
        </span>
      </div>

      <div
        :if={is_nil(@agent_uri)}
        class="flex-1 flex items-center justify-center text-zinc-500 text-xs p-4 text-center"
      >
        {@empty_text}
      </div>

      <.mount :if={@agent_uri} agent_uri={@agent_uri} class="flex-1 min-h-0" />
    </div>
    """
  end

  @doc """
  The bare xterm.js mount-point div — the JS hook anchor.

  `panel/1` delegates here. Use this directly only when the caller
  already owns its own terminal chrome.
  """
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

  defp agent_uri_str(nil), do: nil
  defp agent_uri_str(%URI{} = uri), do: URI.to_string(uri)
  defp agent_uri_str(str) when is_binary(str), do: str
  defp agent_uri_str(_), do: nil
end
