defmodule Ezagent.Behavior.NpAgent do
  @moduledoc """
  NpAgent Behavior — receives chat messages, evaluates numpy / sympy
  expressions in a per-agent Python subprocess via `Ezagent.Domain.Python`,
  and dispatches the result back into the originating session.

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

  The Python script does the safety validation (no raw `eval`); see
  `np_compute_server.py` moduledoc.

  ## Loop safety

  Mirrors the curl_agent pattern: ignore messages whose sender is the
  np-agent itself (defensive — Resolver also drops the sender from
  fan-out, but {:always} rules + mention-gated routing both rely on
  this self-check).

  ## Cap reuse

  Reply dispatch runs under `Ezagent.SystemPrincipal` (`system://chat-reply`)
  per SPEC caps-cleanup-v1 §4.4 — same v1 trust model as curl_agent / echo.
  Granular per-agent caps are a Phase 9 concern (PR-CC-2 sub-PRs).
  """

  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.{Invocation, Message}
  alias Ezagent.Domain.Python

  @default_timeout_ms 10_000

  @impl Ezagent.Behavior
  def actions, do: [:receive, :reset, :configure]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # NpAgent is registered on Entity.NpAgent Kind (type_name :np_agent) —
  # kind axis is `:np_agent`.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      receive: Ezagent.Capability.cap(:np_agent, __MODULE__, :receive),
      reset: Ezagent.Capability.cap(:np_agent, __MODULE__, :reset),
      configure: Ezagent.Capability.cap(:np_agent, __MODULE__, :configure)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:receive,
       "receive a session message and forward to the Python compute subprocess (sympy/numpy)"},
      {:reset, "tear down + respawn the Python compute subprocess (clears state)"},
      {:configure, "set or update the np-agent's subprocess config (timeout, allowed funcs)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :np_agent

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{
      # The Python subprocess handle. By convention the Template Class
      # uses the agent URI itself — one Server per NpAgent Kind.
      python_handle: Map.get(args, :python_handle) || Map.get(args, :uri),
      timeout_ms: Map.get(args, :timeout_ms, @default_timeout_ms),
      # PTY-orphan-restart 2026-05-26: cwd for the Python subprocess.
      # Captured in slice so post_init/2's `handle_continue/3` can
      # respawn the subprocess on phx boot — without re-walking the
      # workspace template store (cross-tier coupling). NpAgent's Kind
      # persistence is `:ephemeral`, so the slice does NOT survive a
      # restart via snapshot; instead the Template Class re-runs
      # `instantiate/3` which threads `:cwd` through here on every
      # respawn.
      cwd: Map.get(args, :cwd),
      # PTY-phase-state-machine 2026-05-26 follow-up (b): mirror of
      # Python Server's `phase` field, updated via PubSub broadcasts
      # on `pty:phase:<agent_uri>`. Same shape as Sandbox's
      # `:pty_phase`; the LV badge reads whichever slice the agent's
      # Kind carries (Sandbox for cc, NpAgent for np).
      python_phase: validate_phase(Map.get(args, :python_phase)),
      last_input: nil,
      last_result: nil,
      last_error: nil
    }
  end

  # Reject corrupt rehydrated values. NpAgent's persistence is
  # `:ephemeral` so this is more defensive than load-bearing.
  defp validate_phase(p) when p in [:starting, :running, :dead, nil], do: p
  defp validate_phase(_), do: nil

  @impl Ezagent.Behavior
  def invoke(:receive, slice, %{message: %Message{} = msg}, ctx) do
    # Loop prevention: ignore messages we sent ourselves.
    self_uri_str = URI.to_string(ctx.self_uri)
    sender_str = sender_string(msg.sender)

    if sender_str == self_uri_str do
      {:ok, slice}
    else
      do_receive(slice, msg, ctx)
    end
  end

  def invoke(:reset, slice, _args, _ctx) do
    new_slice = %{slice | last_input: nil, last_result: nil, last_error: nil}
    {:ok, new_slice, %{ok: true}}
  end

  def invoke(:configure, slice, args, _ctx) when is_map(args) do
    new_slice = %{
      slice
      | timeout_ms: Map.get(args, :timeout_ms, slice.timeout_ms)
    }

    {:ok, new_slice, %{ok: true}}
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      receive: %{
        description:
          "Evaluate the inbound text as a numpy/sympy expression and reply " <>
            "with the computed value",
        args: %{message: :map},
        returns: %{ok: :boolean, result: :string, error: :atom},
        modes: [:cast]
      },
      reset: %{
        description: "Clear the agent's last_input / last_result / last_error",
        args: %{},
        returns: %{ok: :boolean},
        modes: [:call]
      },
      configure: %{
        description: "Update the agent's per-call timeout (ms)",
        args: %{timeout_ms: :integer},
        returns: %{ok: :boolean},
        modes: [:call]
      }
    }
  end

  # --- internals ---------------------------------------------------------

  defp do_receive(slice, %Message{} = msg, ctx) do
    text = extract_text(msg.body)
    source_session_uri = ctx[:caller]

    case run_compute(slice, text) do
      {:ok, result_value} ->
        result_text = "= #{format_result(result_value)}"
        new_slice = %{slice | last_input: text, last_result: result_value, last_error: nil}

        send_reply_to_session(source_session_uri, ctx.self_uri, result_text, msg)
        {:ok, new_slice, %{ok: true, result: result_text}}

      {:error, reason} ->
        Logger.warning(
          "NpAgent #{URI.to_string(ctx.self_uri)} compute failed " <>
            "input=#{inspect(text)} reason=#{inspect(reason)}"
        )

        new_slice = %{slice | last_input: text, last_result: nil, last_error: reason}

        reply_text = "compute error: #{format_error(reason)}"
        send_reply_to_session(source_session_uri, ctx.self_uri, reply_text, msg)
        {:ok, new_slice, %{ok: false, error: error_kind(reason)}}
    end
  end

  defp run_compute(slice, text) when is_binary(text) and text != "" do
    handle = slice.python_handle
    method = pick_method(text)
    timeout = slice.timeout_ms || @default_timeout_ms

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

  defp run_compute(_slice, _empty), do: {:error, :empty_input}

  # Heuristic: latex if it contains a backslash command, `^`, `_`, or
  # `\\frac` etc. Pure numpy expressions (`2 + 2`, `sin(0.5)`,
  # `np.array([1,2,3]).sum()`) go to `compute`.
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

  # Re-use the curl_agent reply-dispatch pattern.
  defp send_reply_to_session(nil, _, _, _), do: :ok
  defp send_reply_to_session("", _, _, _), do: :ok

  defp send_reply_to_session(session_uri, agent_uri, text, in_msg) do
    case parse_session_uri(session_uri) do
      nil ->
        :ok

      %URI{} = session ->
        msg =
          Message.new(agent_uri, %{text: text, attachments: []}, ref_id: in_msg.id)

        target = URI.new!("#{URI.to_string(session)}?action=chat.send")

        Invocation.dispatch(%Invocation{
          target: target,
          mode: :cast,
          args: %{message: msg},
          ctx: %{
            caller: agent_uri,
            # SPEC caps-cleanup-v1 §4.4 — agent reply runs under
            # `system://chat-reply` (closed Catalog).
            caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
            reply: :ignore
          }
        })

        :ok
    end
  end

  defp parse_session_uri(%URI{scheme: "session"} = u), do: u

  defp parse_session_uri(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: "session"} = u} -> u
      _ -> nil
    end
  end

  defp parse_session_uri(_), do: nil

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): admin-only
  # Behavior — no per-entity owner; only bootstrap admin grants
  # via §5.2 admin branch. Test/demo Behaviors + system control
  # surfaces fall here pending dedicated SPEC for any specific
  # owner model they need (e.g. FeishuOutbound: future PR could
  # delegate to session owner like Chat does, but the current
  # outbound path is admin-gated).
  @impl Ezagent.Behavior
  def data_owner(_), do: :no_owner

  # --- PTY-orphan-restart 2026-05-26 — Python subprocess re-spawn -----------
  #
  # Mirrors the cc-Sandbox post_init pattern. The Python subprocess
  # (uv-launched per agent) is NOT OTP-supervised across BEAM restarts.
  # An NpAgent Kind that gets demand-spawned by the chat router (e.g.
  # a chat message arriving before Workspace.Loader runs the template)
  # comes up WITHOUT a Python subprocess — `handle_continue/3` brings
  # it up via the Template Class's `ensure_subprocess_alive/2` callback.
  #
  # The Template Class's normal `instantiate/3` also covers this via
  # the `ensure_python_alive/2` branch on `:already_started`, but
  # there's a window between demand-spawn and Loader where the agent
  # is alive without a subprocess. post_init/2 closes it: the
  # subprocess is up by the time ReadyGate flips the Kind to `:ready`.
  @impl Ezagent.Behavior
  def post_init(_args, _slice) do
    # PTY-phase-state-machine 2026-05-26 follow-up (b): ALWAYS schedule
    # the post_init continuation so the Kind.Server subscribes to
    # `pty:phase:<self_uri>` regardless of whether `cwd` is populated
    # (i.e. whether we have respawn ammo). Same shape as
    # `Ezagent.Behavior.Sandbox` — the subscribe is unconditional;
    # the Python subprocess ensure is conditional on `cwd`.
    {:continue, :setup_phase_tracking_and_ensure_python}
  end

  @impl Ezagent.Behavior
  def handle_continue(:setup_phase_tracking_and_ensure_python, slice, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    cwd = Map.get(slice, :cwd)

    # 1. Subscribe to the phase topic — same topic shape as Sandbox.
    #    Subscribers for cc-flavor and np-flavor agents both consume
    #    `pty:phase:<agent_uri>`; the LV doesn't need to know which
    #    flavor produced the broadcast.
    subscribe_to_phase_topic(self_uri)

    # 2. Maybe ensure the Python subprocess is alive (the legacy
    #    PR #385 path). Skipped when slice has no cwd (demand-spawned
    #    NpAgent — Template Class Loader will rebuild the slice).
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
        # PTY-orphan-restart round-2 (codex finding #3) — same
        # degraded-state pattern as `Ezagent.Behavior.Sandbox`:
        # log + telemetry + :ignore. A raise here would exhaust
        # the EzagentPluginNp.InstanceSupervisor's intensity on
        # a persistent failure (uv missing, FS read-only) and
        # cascade to sibling np agents.
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
  # Server's phase broadcasts. Symmetric to Sandbox's
  # `handle_kind_message/3`; writes to `:python_phase` instead of
  # `:pty_phase` so the slice carries the np-flavor variant. Optional
  # hook — probed via `function_exported?/3`, NOT a declared
  # `@behaviour` callback.
  def handle_kind_message({:pty_phase, %URI{} = agent_uri, phase, meta}, slice, ctx)
      when phase in [:starting, :running, :dead] do
    self_uri = Map.get(ctx, :self_uri)

    # codex round-1 MED-2: PubSub topics are not an authentication
    # boundary. Verify identity BEFORE mutating the slice — drop
    # mismatches with a warning log. Symmetric to
    # `Ezagent.Behavior.Sandbox.handle_kind_message/3`.
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
