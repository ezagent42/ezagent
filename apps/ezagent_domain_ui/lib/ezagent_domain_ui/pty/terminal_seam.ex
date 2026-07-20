defmodule EzagentDomainUi.Pty.TerminalSeam do
  @moduledoc """
  Domain.Pty — the ONE shared PTY terminal event seam for host LVs.

  The xterm.js terminal is rendered by `EzagentDomainUi.Pty.Terminal`
  (a stateless `Phoenix.Component`). But a terminal also needs a
  *runtime* seam: subscribe to the agent's PTY output stream, replay
  the existing screen buffer on connect, fan PubSub chunks out to
  xterm, and dispatch keystrokes back through `?action=pty.write`.

  Per the 3-tier UI architecture a stateless component can't own
  `handle_event` / `handle_info` / `mount` — those belong to the host
  LV. Before this module each PTY host LV (`TerminalLive`,
  `AgentDetailLive`, `AdminLive`) hand-rolled the same ~60 lines of
  seam logic. This module is that seam written ONCE; the host LVs call
  these helpers instead of copy-pasting.

  ## What stays in the host LV

  Dispatch still happens *through* the host LV (this module's
  `dispatch_input/3` is a plain function the LV calls from its
  `handle_event("pty_input", …)`), keeping CapBAC + audit in the
  caller's context. This module owns no process state — it's a
  function library, consistent with the rest of `ezagent_domain_ui`
  (a Tier-2 library of stateless helpers).

  ## Reading a PTY is capability-gated (Allen, 2026-07-14)

  A terminal's OUTPUT carries `claude /login` codes, secrets echoed by
  commands, and the agent's whole conversation — it is at least as
  sensitive as its input. `subscribe/2` and `push_initial_buffer/3`
  therefore TAKE the caller's caps and refuse unless
  `Ezagent.Domain.Pty.Access.may_read?/2` passes (the agent's Manage
  cap — which its creator already holds; admin's genesis also matches).

  They are gated BY CONSTRUCTION rather than by convention: a host LV
  cannot subscribe without passing caps, so a future host cannot
  reintroduce the ungated-read hole by forgetting a check. Every other
  PTY read exit calls the same predicate.

  ## Typical host-LV wiring

      # in mount/3, after `connected?`:
      caps = socket.assigns.current_caps
      TerminalSeam.subscribe(agent_uri, caps)
      socket = TerminalSeam.push_initial_buffer(socket, agent_uri, caps)

      # PubSub fan-out:
      def handle_info({:pty_output, _uri, chunk}, socket),
        do: {:noreply, TerminalSeam.push_chunk(socket, chunk)}

      # keystrokes:
      def handle_event("pty_input", %{"bytes" => bytes}, socket) do
        case TerminalSeam.dispatch_input(agent_uri, bytes, ctx) do
          :ok -> {:noreply, socket}
          {:error, reason} -> {:noreply, flash(socket, reason)}
        end
      end

      # resize is a server-side no-op (TUI handles its own winsz):
      def handle_event("pty_resize", _p, socket),
        do: {:noreply, socket}
  """

  alias Ezagent.Domain.Pty.Server

  @doc """
  Subscribe the calling process to `agent_uri`'s PTY output stream, IF `caps`
  authorize reading that terminal.

  Call from the host LV's `mount/3` once `connected?(socket)` is true. After
  this, `{:pty_output, agent_uri, chunk}` messages arrive in the LV's
  `handle_info/2` — feed them to `push_chunk/2`.

  Returns `{:error, :unauthorized}` and subscribes to NOTHING when the caller
  may not read this agent's terminal. Fails closed.
  """
  @spec subscribe(URI.t(), Enumerable.t()) :: :ok | {:error, :unauthorized}
  def subscribe(%URI{} = agent_uri, caps) do
    if Ezagent.Domain.Pty.Access.may_read?(agent_uri, caps) do
      Phoenix.PubSub.subscribe(
        EzagentCore.PubSub,
        Server.output_topic(agent_uri)
      )
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  ttyd-style initial buffer replay.

  Asks the `Ezagent.Domain.Pty.Server` for the current screen buffer
  and pushes it as a `pty_chunk` event so a fresh page load shows the
  existing screen state immediately. No-op (returns the socket
  unchanged) when no server is alive or the buffer is empty.

  Returns the socket UNCHANGED (no buffer pushed) when `caps` do not authorize
  reading this agent's terminal. Fails closed.
  """
  @spec push_initial_buffer(Phoenix.LiveView.Socket.t(), URI.t(), Enumerable.t()) ::
          Phoenix.LiveView.Socket.t()
  def push_initial_buffer(socket, %URI{} = agent_uri, caps) do
    if Ezagent.Domain.Pty.Access.may_read?(agent_uri, caps) do
      do_push_initial_buffer(socket, agent_uri)
    else
      socket
    end
  end

  defp do_push_initial_buffer(socket, %URI{} = agent_uri) do
    case Server.snapshot_buffer(agent_uri) do
      {:ok, buf} when byte_size(buf) > 0 ->
        Phoenix.LiveView.push_event(socket, "pty_chunk", %{bytes: buf})

      _ ->
        socket
    end
  end

  @doc """
  Fan one PTY output chunk out to the browser xterm via a `pty_chunk`
  push-event. Call from the host LV's
  `handle_info({:pty_output, _, chunk}, socket)`.
  """
  @spec push_chunk(Phoenix.LiveView.Socket.t(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def push_chunk(socket, chunk) when is_binary(chunk) do
    Phoenix.LiveView.push_event(socket, "pty_chunk", %{bytes: chunk})
  end

  @doc """
  Dispatch a keystroke payload to the agent's PTY via
  `?action=pty.write`.

  `ctx` is the standard dispatch context map (`%{caller:, caps:,
  reply:}`) the host LV already builds. Returns `:ok` on success or
  `{:error, reason}` so the host LV can surface a flash. CapBAC +
  audit happen inside `Ezagent.Invocation.dispatch/1` against the
  caller's caps — exactly as before; this just removes the copy-paste.
  """
  @spec dispatch_input(URI.t(), binary(), map()) :: :ok | {:error, term()}
  def dispatch_input(%URI{} = agent_uri, bytes, ctx) when is_binary(bytes) do
    target = Ezagent.URI.new!(URI.to_string(agent_uri) <> "?action=pty.write")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{bytes: bytes},
      ctx: ctx,
      origin: :authenticated_external
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Human-readable flash text for a `dispatch_input/3` error reason.

  Centralised so every PTY surface shows the same wording for
  `:unauthorized` / `:cross_workspace_denied` / other failures.
  """
  @spec input_error_message(term()) :: String.t()
  def input_error_message(:unauthorized),
    do:
      "Unauthorized — this agent's terminal belongs to its creator. " <>
        "Needs the agent's manage cap (agent.manage on this instance); " <>
        "an agent.pty cap no longer grants terminal access."

  def input_error_message(:cross_workspace_denied),
    do:
      "Cross-workspace denied — your workspace differs from this agent's workspace."

  def input_error_message(reason),
    do: "PTY input failed: #{inspect(reason)}"
end
