defmodule Ezagent.Behavior.NpAgent do
  @moduledoc """
  NpAgent Behavior — receives chat messages, evaluates numpy / sympy
  expressions in a per-agent Python subprocess via `Ezagent.Domain.Python`,
  and dispatches the result back into the originating session.

  ## Phase 2-g r3 migration (2026-05-28)

  Migrated to `use Ezagent.Behavior` + per-action declarative
  contract per SPEC `2026-05-28-router-behavior-kind-architecture.md`
  §2.2 + §4.4. The `:receive` handler builds a `chat.send` reply
  via the `{:dispatch, %Cmd{}}` effect; `:reset` and `:configure`
  mutate the slice via `{:set, _, _}` effects.

  `required_caps/0` is still manually exported to preserve the
  kind axis `:np_agent` (the macro auto-derives uses `:any`).

  Registered for `(Ezagent.Entity.NpAgent, :receive | :configure | :reset)`
  in `EzagentPluginNp.Application`. The chat router targets
  `entity://agent/<ws>/np_<name>?action=chat.receive`; the dispatcher
  pattern-matches behavior_module to land here.

  ## Slice (state_slice :np_agent)

  See `Ezagent.Entity.NpAgent` moduledoc for the schema. This Behavior:
  - reads `python_handle` for outbound JSON-RPC calls
  - records `last_input / last_result / last_error` for observability

  ## Per-receive flow

  1. Extract `text` from message body — that's the expression / latex.
  2. Decide method: `compute_latex` if the text looks like LaTeX
     (contains `\\` or `^` or `_`), else `compute`. Plain `numpy/sympy`
     expressions go to `compute`.
  3. `Ezagent.Domain.Python.call(handle, method, %{"expr" => text}, 10_000)`
  4. On `{:ok, %{"result" => r}}`, format `"= <r>"` and dispatch
     `chat.send` back into the originating session.
  5. On error, format the error human-readably and reply with that.

  ## Loop safety

  Mirrors the curl_agent pattern: ignore messages whose sender is the
  np-agent itself.

  ## Cap reuse

  Reply dispatch runs under `Ezagent.SystemPrincipal` (`system://chat-reply`)
  per SPEC caps-cleanup-v1 §4.4 — same v1 trust model as curl_agent / echo.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.{Cmd, Message}
  alias Ezagent.Domain.Python

  @default_timeout_ms 10_000

  action :receive,
    args: %{message: :map},
    returns: %{ok: :boolean, result: :string, error: :atom},
    caps: [:receive],
    modes: [:cast],
    description:
      "Evaluate the inbound text as a numpy/sympy expression and reply " <>
        "with the computed value"

  action :reset,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:reset],
    modes: [:call],
    description: "Clear the agent's last_input / last_result / last_error"

  action :configure,
    args: %{timeout_ms: :integer},
    returns: %{ok: :boolean},
    caps: [:configure],
    modes: [:call],
    description: "Update the agent's per-call timeout (ms)"

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # NpAgent is registered on Entity.NpAgent Kind (type_name :np_agent) —
  # kind axis is `:np_agent`. Manually exported to override the macro's
  # `:any` default.
  def required_caps do
    %{
      receive: Ezagent.Capability.cap(:np_agent, __MODULE__, :receive),
      reset: Ezagent.Capability.cap(:np_agent, __MODULE__, :reset),
      configure: Ezagent.Capability.cap(:np_agent, __MODULE__, :configure)
    }
  end

  def state_slice, do: :np_agent

  def init_slice(args) do
    %{
      python_handle: Map.get(args, :python_handle) || Map.get(args, :uri),
      timeout_ms: Map.get(args, :timeout_ms, @default_timeout_ms),
      cwd: Map.get(args, :cwd),
      python_phase: validate_phase(Map.get(args, :python_phase)),
      last_input: nil,
      last_result: nil,
      last_error: nil
    }
  end

  # Legacy-contract shim — required to satisfy `@behaviour
  # Ezagent.Behavior` until `invoke/4` is added to `@optional_callbacks`
  # in core. `Ezagent.Kind.Runtime` detects new-style via
  # `Behavior.new_style?/1` (the macro injects `__behavior__?/0`) and
  # dispatches through `handle_<action>/2`, so this clause is never
  # called in production. Phase 2-g r3 migration.
  def invoke(action, _slice, _args, _ctx) do
    {:error, {:legacy_invoke_deprecated_use_handle_action, __MODULE__, action}}
  end

  # Reject corrupt rehydrated values. NpAgent's persistence is
  # `:ephemeral` so this is more defensive than load-bearing.
  defp validate_phase(p) when p in [:starting, :running, :dead, nil], do: p
  defp validate_phase(_), do: nil

  # ---------------------------------------------------------------
  # handle_<action>/2 (new contract)
  # ---------------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    # Loop prevention: ignore messages we sent ourselves.
    self_uri = Map.get(ctx, :self_uri)
    sender_str = sender_string(msg.sender)
    self_uri_str = if is_struct(self_uri, URI), do: URI.to_string(self_uri), else: ""

    if sender_str == self_uri_str do
      {:ok, %{ok: true, ignored: :self_message}, []}
    else
      do_receive_effects(msg, ctx)
    end
  end

  def handle_reset(_args, _ctx) do
    {:ok, %{ok: true},
     [
       {:set, :last_input, nil},
       {:set, :last_result, nil},
       {:set, :last_error, nil}
     ]}
  end

  def handle_configure(args, ctx) when is_map(args) do
    cur_timeout = ctx[:read].(:timeout_ms, @default_timeout_ms)
    new_timeout = Map.get(args, :timeout_ms, cur_timeout)

    {:ok, %{ok: true}, [{:set, :timeout_ms, new_timeout}]}
  end

  # --- internals ---------------------------------------------------------

  defp do_receive_effects(%Message{} = msg, ctx) do
    text = extract_text(msg.body)
    source_session_uri = ctx[:caller]
    self_uri = Map.get(ctx, :self_uri)
    python_handle = ctx[:read].(:python_handle, self_uri)
    timeout_ms = ctx[:read].(:timeout_ms, @default_timeout_ms)

    case run_compute(python_handle, timeout_ms, text) do
      {:ok, result_value} ->
        result_text = "= #{format_result(result_value)}"

        effects =
          [
            {:set, :last_input, text},
            {:set, :last_result, result_value},
            {:set, :last_error, nil}
          ] ++ maybe_reply_effect(source_session_uri, self_uri, result_text, msg)

        {:ok, %{ok: true, result: result_text}, effects}

      {:error, reason} ->
        if is_struct(self_uri, URI) do
          Logger.warning(
            "NpAgent #{URI.to_string(self_uri)} compute failed " <>
              "input=#{inspect(text)} reason=#{inspect(reason)}"
          )
        end

        reply_text = "compute error: #{format_error(reason)}"

        effects =
          [
            {:set, :last_input, text},
            {:set, :last_result, nil},
            {:set, :last_error, reason}
          ] ++ maybe_reply_effect(source_session_uri, self_uri, reply_text, msg)

        {:ok, %{ok: false, error: error_kind(reason)}, effects}
    end
  end

  defp run_compute(handle, timeout, text) when is_binary(text) and text != "" do
    method = pick_method(text)

    case Python.call(handle, method, %{"expr" => text}, timeout) do
      {:ok, %{"result" => r}} ->
        {:ok, r}

      {:ok, other} ->
        {:error, {:bad_python_result, other}}

      {:error, %{"code" => code, "message" => message}} ->
        {:error, {:python_error, code, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_compute(_handle, _timeout, _empty), do: {:error, :empty_input}

  # Heuristic: latex if it contains a backslash command. Pure numpy
  # expressions (`2 + 2`, `sin(0.5)`, `np.array([1,2,3]).sum()`) go to
  # `compute`.
  defp pick_method(text) do
    cond do
      String.contains?(text, "\\") -> "compute_latex"
      true -> "compute"
    end
  end

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  defp sender_string(%URI{} = u), do: URI.to_string(u)
  defp sender_string(s) when is_binary(s), do: s
  defp sender_string(_), do: ""

  defp format_result(r) when is_number(r), do: to_string(r)
  defp format_result(r) when is_binary(r), do: r

  defp format_result(r) when is_list(r) do
    Enum.map(r, &format_result/1) |> Enum.join(", ") |> then(&("[" <> &1 <> "]"))
  end

  defp format_result(r), do: inspect(r)

  defp format_error({:python_error, code, message}),
    do: "python error #{code}: #{message}"

  defp format_error({:bad_python_result, other}),
    do: "unexpected python result shape: #{inspect(other)}"

  defp format_error(:not_alive), do: "python subprocess not running"
  defp format_error(:rpc_timeout), do: "python compute timed out"
  defp format_error(:empty_input), do: "empty input"
  defp format_error(reason), do: inspect(reason)

  defp error_kind({:python_error, _, _}), do: :python_error
  defp error_kind({:bad_python_result, _}), do: :bad_python_result
  defp error_kind(:not_alive), do: :not_alive
  defp error_kind(:rpc_timeout), do: :rpc_timeout
  defp error_kind(:empty_input), do: :empty_input
  defp error_kind(_), do: :other

  # Build a single `{:dispatch, %Cmd{}}` effect when source session +
  # self URI are both well-formed; otherwise emit nothing.
  defp maybe_reply_effect(nil, _self_uri, _text, _in_msg), do: []
  defp maybe_reply_effect("", _self_uri, _text, _in_msg), do: []
  defp maybe_reply_effect(_, nil, _text, _in_msg), do: []

  defp maybe_reply_effect(session_uri, %URI{} = self_uri, text, in_msg) do
    case parse_session_uri(session_uri) do
      nil ->
        []

      %URI{} = session ->
        reply_msg =
          Message.new(self_uri, %{text: text, attachments: []}, ref_id: in_msg.id)

        target = URI.new!("#{URI.to_string(session)}?action=chat.send")

        cmd =
          Cmd.new(target, :send, %{message: reply_msg}, %{
            caller: self_uri,
            # SPEC caps-cleanup-v1 §4.4 — agent reply runs under
            # `system://chat-reply` (closed Catalog).
            caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
            reply: :ignore
          })

        [{:dispatch, cmd}]
    end
  end

  defp parse_session_uri(%URI{scheme: "session"} = u), do: u

  defp parse_session_uri(s) when is_binary(s) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the nil fallback for malformed input.
    try do
      case Ezagent.URI.parse!(s) do
        %URI{scheme: "session"} = u -> u
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_session_uri(_), do: nil

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): admin-only Behavior —
  # no per-entity owner; only bootstrap admin grants via §5.2 admin
  # branch.
  def data_owner(_), do: :no_owner

  # --- PTY-orphan-restart 2026-05-26 — Python subprocess re-spawn -----------
  #
  # Same lifecycle hook contract as the legacy implementation;
  # carries through unchanged from the @behaviour callback set
  # (optional callbacks `post_init/2` + `handle_continue/3` +
  # `handle_kind_message/3`).
  def post_init(_args, _slice) do
    # PTY-phase-state-machine 2026-05-26 follow-up (b): ALWAYS schedule
    # the post_init continuation so the Kind.Server subscribes to
    # `pty:phase:<self_uri>` regardless of whether `cwd` is populated.
    {:continue, :setup_phase_tracking_and_ensure_python}
  end

  def handle_continue(:setup_phase_tracking_and_ensure_python, slice, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    cwd = Map.get(slice, :cwd)

    subscribe_to_phase_topic(self_uri)

    cond do
      not is_struct(self_uri, URI) ->
        Logger.warning(
          "Ezagent.Behavior.NpAgent.post_init: non-URI self_uri " <>
            "#{inspect(self_uri)} — skipping subprocess re-spawn"
        )

        :ignore

      not is_binary(cwd) or cwd == "" ->
        # No cwd → demand-spawn path. Phase subscription still in
        # place; eventual Loader pass triggers a fresh
        # `ensure_subprocess_alive` via its own dispatch.
        :ignore

      true ->
        do_ensure_python_alive(self_uri, cwd)
    end
  end

  defp subscribe_to_phase_topic(%URI{} = self_uri) do
    topic = "pty:phase:" <> URI.to_string(self_uri)

    try do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
    catch
      kind, reason ->
        Logger.warning(
          "Ezagent.Behavior.NpAgent.post_init: PubSub.subscribe failed " <>
            "(#{inspect(kind)}, #{inspect(reason)}) for #{URI.to_string(self_uri)}; " <>
            "phase tracking disabled for this incarnation"
        )

        :ok
    end
  end

  defp subscribe_to_phase_topic(_), do: :ok

  defp do_ensure_python_alive(self_uri, cwd) do
    case Ezagent.PluginNp.Template.NpAgent.ensure_subprocess_alive(self_uri, %{
           "cwd" => cwd
         }) do
      :ok ->
        :ignore

      {:error, reason} ->
        Logger.error(
          "Ezagent.Behavior.NpAgent.post_init: " <>
            "Template.NpAgent.ensure_subprocess_alive/2 failed for " <>
            "#{URI.to_string(self_uri)}: #{inspect(reason)}. " <>
            "NpAgent Kind stays alive in DEGRADED state (no Python " <>
            "subprocess); next dispatched compute call surfaces " <>
            ":not_alive."
        )

        :telemetry.execute(
          [:ezagent, :np_agent, :subprocess_unhealthy],
          %{},
          %{
            agent_uri: URI.to_string(self_uri),
            reason: inspect(reason)
          }
        )

        :ignore
    end
  end

  # PTY-phase-state-machine 2026-05-26 follow-up (b): consume Python
  # Server's phase broadcasts. Optional hook — probed via
  # `function_exported?/3` by `Kind.Server`.
  def handle_kind_message({:pty_phase, %URI{} = agent_uri, phase, meta}, slice, ctx)
      when phase in [:starting, :running, :dead] do
    self_uri = Map.get(ctx, :self_uri)

    # codex round-1 MED-2: PubSub topics are not an authentication
    # boundary. Verify identity BEFORE mutating the slice.
    if uris_equal?(agent_uri, self_uri) do
      :telemetry.execute(
        [:ezagent, :np_agent, :python_phase],
        %{at: Map.get(meta, :at, System.os_time(:millisecond))},
        %{
          agent_uri: URI.to_string(agent_uri),
          phase: phase,
          os_pid: Map.get(meta, :os_pid),
          reason: Map.get(meta, :reason)
        }
      )

      {:ok, Map.put(slice, :python_phase, phase)}
    else
      Logger.warning(
        "Ezagent.Behavior.NpAgent.handle_kind_message: pty_phase " <>
          "agent_uri=#{URI.to_string(agent_uri)} != self_uri=" <>
          "#{inspect(self_uri)}; dropping (topic-collision defense)"
      )

      :ignore
    end
  end

  def handle_kind_message(_other, _slice, _ctx), do: :ignore

  defp uris_equal?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp uris_equal?(_, _), do: false
end
