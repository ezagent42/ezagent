defmodule EzagentPluginCc.EagerBridge do
  @moduledoc """
  Opt-in primitive that brings a cc agent's `esr-bridge` MCP up
  programmatically (without operator PTY interaction), so non-operator
  inbound flows (HTTP webhook, IM, etc.) can dispatch `chat.receive`
  to the agent without silent-drop on missing bridge.

  ## When to use

  Customer-facing channel plugins (e.g. `/api/customer/:workspace/chat`
  HTTP+SSE controller) call `ensure_bound!/2` after spawning a fresh
  cc agent and before dispatching the first customer message. For
  operator-facing flows where a human will open the terminal page,
  do NOT call this — the operator's first keystroke triggers the same
  MCP init naturally.

  ## How it works

  Empirically (per Phase 2.0 investigation, ezagent main ≥ f243a58):

  - Spawning a cc agent leaves claude alive but with **no MCP children**
    and **no `BridgeRegistry` binding**.
  - Writing a single bare `\\r` to the agent's PTY causes claude to
    spawn its configured MCP servers (including esr-bridge).
  - The esr-bridge python process opens a WS to the bridge endpoint,
    joins the `agent_bridge:cc:<uri>` channel, registers in
    `Ezagent.AgentBridge.Registry` — all within ~500-1000ms.

  This module wraps that handshake:

  1. `Ezagent.AgentBridge.Registry.lookup/1` → if `{:ok, _}`, fast no-op
  2. else: `Ezagent.Domain.Pty.Server.write_input(pty_pid, "\\r")`
  3. Poll `Registry.lookup/1` every 100ms until `{:ok, _}` or timeout

  ## Idempotency + concurrent calls

  `ensure_bound!/2` is safe to call concurrently for the same `agent_uri`:
  the registry-lookup is atomic, the `write_input` is itself idempotent
  (writing `\\r` twice is harmless — claude already past the `\\r`-triggered
  init the second time around is a no-op), and the poll loop is per-process
  so two callers each get their own `:ok` once binding lands.

  ## Failure mode

  Returns `{:error, :timeout}` after `timeout_ms` (default 5_000) if the
  binding never forms. Caller should surface a real error to the customer
  (e.g. SSE close with `event: error`), NOT silently retry — a timeout
  here means something deeper is wrong (PtyServer dead? bridge python
  can't reach WS endpoint? `EZAGENT_BRIDGE_WS_URL` env misconfigured? —
  see ezagent#435).

  Returns `{:error, :no_pty}` if `Ezagent.Domain.Pty.lookup/1` returns
  `:error` (agent's PtyServer isn't alive at all — caller likely spawned
  the agent wrong or it crashed).
  """

  @poll_interval_ms 100
  @kick_interval_ms 1_000
  @stabilize_ms 500
  @default_timeout_ms 15_000

  @doc """
  Ensure `Ezagent.AgentBridge.Registry.lookup(agent_uri)` returns
  `{:ok, _pid}` by the time this returns `:ok`.

  Triggers the MCP-init handshake via PTY input if not already bound.
  See module docs.

  ## Examples

      :ok = EzagentPluginCc.EagerBridge.ensure_bound!(agent_uri)
      :ok = EzagentPluginCc.EagerBridge.ensure_bound!(agent_uri, 10_000)
  """
  @spec ensure_bound!(URI.t(), pos_integer()) ::
          :ok | {:error, :timeout | :no_pty | term()}
  def ensure_bound!(%URI{} = agent_uri, timeout_ms \\ @default_timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    case Ezagent.AgentBridge.Registry.lookup(agent_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        kick_and_wait(agent_uri, timeout_ms)
    end
  end

  defp kick_and_wait(agent_uri, timeout_ms) do
    case Ezagent.Domain.Pty.lookup(agent_uri) do
      {:ok, pty_pid} ->
        # Empirically (Phase 2.0 + 2.1 followup): a `\r` written while
        # claude is still rendering startup dialogs (esp.
        # dev_channels_dialog) gets eaten AND can desync claude so
        # subsequent `\r`s also don't trigger MCP init.
        #
        # Gate the trigger on "all auto_prompts have fired? = true"
        # + a small stabilize delay. That puts claude at its main
        # TUI prompt where a bare `\r` reliably triggers MCP init.
        with :ok <- wait_for_auto_prompts(pty_pid, timeout_ms),
             remaining = remaining_after(timeout_ms, @stabilize_ms),
             _ = Process.sleep(@stabilize_ms),
             :ok <- kick_loop(agent_uri, pty_pid, remaining) do
          :ok
        end

      :error ->
        {:error, :no_pty}
    end
  end

  defp remaining_after(orig_ms, used_ms), do: max(0, orig_ms - used_ms)

  # Poll PtyServer state until every auto_prompt entry has `fired?: true`.
  # Returns :ok or {:error, :timeout}. Tolerates servers where auto_prompts
  # is absent / empty (no prompts to wait for → immediate :ok).
  defp wait_for_auto_prompts(_pty_pid, remaining_ms) when remaining_ms <= 0 do
    {:error, :timeout}
  end

  defp wait_for_auto_prompts(pty_pid, remaining_ms) do
    state = :sys.get_state(pty_pid, @poll_interval_ms)
    prompts = Map.get(state, :auto_prompts, []) || []

    if all_fired?(prompts) do
      :ok
    else
      Process.sleep(@poll_interval_ms)
      wait_for_auto_prompts(pty_pid, remaining_ms - @poll_interval_ms)
    end
  rescue
    _ -> {:error, :timeout}
  catch
    :exit, _ -> {:error, :timeout}
  end

  defp all_fired?([]), do: true

  defp all_fired?(prompts) when is_list(prompts) do
    Enum.all?(prompts, fn p -> Map.get(p, :fired?, true) end)
  end

  defp all_fired?(_), do: true

  defp kick_loop(_agent_uri, _pty_pid, remaining_ms) when remaining_ms <= 0 do
    {:error, :timeout}
  end

  defp kick_loop(agent_uri, pty_pid, remaining_ms) do
    case Ezagent.Domain.Pty.Server.write_input(pty_pid, "\r") do
      :ok ->
        case wait_for_binding(agent_uri, min(@kick_interval_ms, remaining_ms)) do
          :ok ->
            :ok

          :pending ->
            kick_loop(agent_uri, pty_pid, remaining_ms - @kick_interval_ms)
        end

      {:error, _} = err ->
        err
    end
  end

  defp wait_for_binding(_agent_uri, remaining_ms) when remaining_ms <= 0 do
    :pending
  end

  defp wait_for_binding(agent_uri, remaining_ms) do
    case Ezagent.AgentBridge.Registry.lookup(agent_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        Process.sleep(@poll_interval_ms)
        wait_for_binding(agent_uri, remaining_ms - @poll_interval_ms)
    end
  end

  @doc """
  Status probe — returns the current binding state without triggering
  a handshake. Useful for dashboard / observability surfaces.
  """
  @spec status(URI.t()) :: :bound | :unbound | :no_pty
  def status(%URI{} = agent_uri) do
    case Ezagent.AgentBridge.Registry.lookup(agent_uri) do
      {:ok, _pid} ->
        :bound

      :error ->
        case Ezagent.Domain.Pty.lookup(agent_uri) do
          {:ok, _} -> :unbound
          :error -> :no_pty
        end
    end
  end
end
