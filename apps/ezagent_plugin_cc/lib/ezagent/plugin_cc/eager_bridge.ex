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
  2. else: wait for startup dialogs (theme picker, dev-channels, trust)
     to clear, then `Ezagent.Domain.Pty.Server.write_input(pty_pid, "\\r")`
  3. Poll `Registry.lookup/1` every 100ms until `{:ok, _}` or timeout

  ## Dialog wait behaviour (claude 2.1.92 note)

  The gate waits for one-shot startup dialogs to fire before sending the
  bridge-init `\\r`. If a dialog doesn't appear (e.g. `trust_folder` is
  skipped when the cwd is already trusted in the operator's `~/.claude`),
  the gate proceeds after `@dialog_wait_ms` anyway — a timeout here is
  **not fatal**; the kick_loop still runs and retries.

  The only immediately fatal case is `{:error, :oauth_required}`: if the
  PTY server detects claude's OAuth login screen it means the
  `CLAUDE_CONFIG_DIR` has no valid credentials. No amount of `\\r` kicks
  will help — the caller must seed credentials before spawning the agent
  (see `docs/runbook/cc-agent-e2e.md` §"Credential-copy").

  ## Idempotency + concurrent calls

  `ensure_bound!/2` is safe to call concurrently for the same `agent_uri`:
  the registry-lookup is atomic, the `write_input` is itself idempotent
  (writing `\\r` twice is harmless), and the poll loop is per-process so
  two callers each get their own `:ok` once binding lands.

  ## Failure modes

  Returns `{:error, :timeout}` after `timeout_ms` (default 15_000) if the
  binding never forms. Caller should surface a real error to the customer
  (e.g. SSE close with `event: error`), NOT silently retry.

  Returns `{:error, :no_pty}` if the PtyServer isn't alive.

  Returns `{:error, :oauth_required}` if the PTY scanner detected an OAuth
  login screen — the CLAUDE_CONFIG_DIR has no valid credentials for
  claude 2.1.92. Seed credentials and respawn the agent before retrying.
  """

  @poll_interval_ms 100
  @kick_interval_ms 1_000
  @stabilize_ms 500
  @default_timeout_ms 15_000
  # Maximum time to wait for startup dialogs before proceeding to kick anyway.
  # Dialogs that don't appear (e.g. trust_folder when cwd already trusted) must
  # not block the kick indefinitely — after this window we proceed optimistically.
  @dialog_wait_ms 8_000

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
          :ok | {:error, :timeout | :no_pty | :oauth_required | term()}
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
        # Gate the trigger on "all one-shot auto_prompts fired" + stabilize.
        # That puts claude at its main TUI prompt where `\r` triggers MCP init.
        #
        # 2026-06-01 finding: some dialogs may NOT appear (e.g. trust_folder
        # is skipped when cwd is already trusted in ~/.claude), so a timeout
        # from wait_for_auto_prompts is NOT fatal — we proceed to kick anyway.
        # Only {:error, :oauth_required} is immediately fatal: that means
        # CLAUDE_CONFIG_DIR has no credentials and no kick will help.
        dialog_budget = min(timeout_ms, @dialog_wait_ms)

        case wait_for_auto_prompts(pty_pid, dialog_budget) do
          {:error, :oauth_required} ->
            {:error, :oauth_required}

          _ok_or_timeout ->
            # Proceed whether dialogs all fired or we hit the dialog window
            # limit — an optimistic kick is safer than never kicking at all.
            elapsed = dialog_budget + @stabilize_ms
            remaining = remaining_after(timeout_ms, elapsed)
            Process.sleep(@stabilize_ms)
            kick_loop(agent_uri, pty_pid, remaining)
        end

      :error ->
        {:error, :no_pty}
    end
  end

  defp remaining_after(orig_ms, used_ms), do: max(0, orig_ms - used_ms)

  # Poll PtyServer state until every one-shot auto_prompt has fired.
  # Returns :ok, {:error, :timeout}, or {:error, :oauth_required}.
  # Tolerates servers where auto_prompts is absent / empty → immediate :ok.
  defp wait_for_auto_prompts(_pty_pid, remaining_ms) when remaining_ms <= 0 do
    {:error, :timeout}
  end

  defp wait_for_auto_prompts(pty_pid, remaining_ms) do
    state = :sys.get_state(pty_pid, @poll_interval_ms)
    prompts = Map.get(state, :auto_prompts, []) || []

    cond do
      Map.get(state, :oauth_blocked?) ->
        # PTY scanner detected the OAuth login screen: CLAUDE_CONFIG_DIR has
        # no valid credentials for claude 2.1.92. No kick will help.
        {:error, :oauth_required}

      all_fired?(prompts) ->
        :ok

      true ->
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
    Enum.all?(prompts, fn p ->
      # `repeat?: true` prompts (e.g. the claude 2.1.92 theme picker) re-arm
      # and NEVER latch `fired?: true` by design — and they may not even
      # appear on a given spawn. They must NOT block this bridge-kick gate,
      # or EagerBridge waits forever and the agent never binds (the
      # 2026-06-01 regression: adding :theme_picker_dialog as a repeat prompt
      # silently froze the gate for every agent). Only the one-shot mandatory
      # dialogs (dev-channels / trust) gate the kick.
      Map.get(p, :repeat?, false) or Map.get(p, :fired?, true)
    end)
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
