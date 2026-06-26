defmodule Ezagent.Behavior.PyAgent do
  @moduledoc """
  PyAgent Behavior — a GENERAL script-driven Python agent. Each inbound chat
  message is handed to the agent's OPERATOR-SUPPLIED python script (installed
  at create-time into the per-agent `config_dir` as `agent.py`) via the single
  `"receive"` JSON-RPC method on the per-agent `Ezagent.Domain.Python`
  subprocess; a non-nil reply is dispatched back into the originating session.

  Sibling of `Ezagent.Behavior.NpAgent`, but:

  - **one method** — `"receive"` (vs np's `compute`/`compute_latex` LaTeX
    heuristic). The script's per-message logic is operator-authored, not
    baked into the Behavior.
  - **own cap axis** — `:py_agent` (`required_caps/0`).
  - **script is immutable post-create** — `:configure` sets `timeout_ms`
    ONLY (never the script); `:reset` clears `last_*`. The script file is
    written once at create (`Template.PyAgent.instantiate/3`); see spec §5.

  ## The wire (spec §1)

      Domain.Python.call(handle, "receive", %{text, from, session}, timeout)

  The script registers a `@method("receive")` handler returning a reply
  payload (a map with a `"text"` key) or `None`/`nil` to stay silent. A
  raising script is captured to `last_error` (durable) + logged; the BEAM
  Kind does NOT crash.

  ## Two-container split (Lifecycle SPEC 2026-05-29)

  - **`state` (PERSISTENT)** — `python_handle`, `script_path` (under the
    config_dir), `timeout_ms`, `cwd`, `python_phase`, `last_input`,
    `last_result`, `last_error`. `script_path` + `cwd` are read by the
    cold-load `activate/2` to re-spawn the subprocess from the installed
    script (NOT re-write it).
  - **`transients` (NEVER persisted)** — `phase_subscription`. Rebuilt every
    `activate/2` via `Ezagent.Domain.Python.AgentLifecycle.subscribe_phase/1`.

  ## activate/2 — re-spawn from `script_path` on EVERY start

  `activate/2` (the unified start hook: fresh spawn, supervisor restart,
  cold-load) rebuilds the phase subscription transient AND self-heals the
  Python subprocess from durable `state` via the shared
  `Ezagent.Domain.Python.AgentLifecycle.ensure_alive/1` — re-spawning from
  the EXISTING `agent.py` (it is not re-written here; re-write only happens on
  the cap-gated create path). This closes the "fresh works, restart doesn't"
  bug class structurally (#113).

  ## Loop safety

  Mirrors np/curl: ignore messages whose sender is the py-agent itself.
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.{Cmd, Message}
  alias Ezagent.Domain.Python
  alias Ezagent.Domain.Python.AgentLifecycle

  @default_timeout_ms 10_000

  action(:receive,
    args: %{message: :map},
    returns: %{ok: :boolean, error: :atom},
    caps: [:receive],
    modes: [:cast],
    description:
      "Hand the inbound text to the operator script's receive() handler and " <>
        "reply with its returned payload"
  )

  action(:reset,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:reset],
    modes: [:call],
    description: "Clear the agent's last_input / last_result / last_error"
  )

  action(:configure,
    args: %{timeout_ms: :integer},
    returns: %{ok: :boolean},
    caps: [:configure],
    modes: [:call],
    description:
      "Update the agent's per-call timeout (ms). NEVER mutates the script " <>
        "(immutable post-create, spec §5)"
  )

  # Own kind axis `:py_agent` — PyAgent is registered on Entity.PyAgent Kind
  # (type_name :py_agent). Manually exported to override the macro's `:any`
  # default (same pattern as NpAgent).
  @doc false
  def required_caps do
    %{
      receive: Ezagent.Capability.cap(:py_agent, __MODULE__, :receive),
      reset: Ezagent.Capability.cap(:py_agent, __MODULE__, :reset),
      configure: Ezagent.Capability.cap(:py_agent, __MODULE__, :configure)
    }
  end

  # --- create/1 — PERSISTENT state only (transients are activate/2's job) ---
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       python_handle: Map.get(args, :python_handle) || Map.get(args, :uri),
       script_path: Map.get(args, :script_path),
       timeout_ms: Map.get(args, :timeout_ms, @default_timeout_ms),
       cwd: Map.get(args, :cwd),
       python_phase: validate_phase(Map.get(args, :python_phase)),
       last_input: nil,
       last_result: nil,
       last_error: nil
     }}
  end

  defp validate_phase(p) when p in [:starting, :running, :dead, nil], do: p
  defp validate_phase(_), do: nil

  # --- handle_<action>/2 ----------------------------------------------------

  @doc false
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    sender_str = sender_string(msg.sender)
    self_uri_str = if is_struct(self_uri, URI), do: URI.to_string(self_uri), else: ""

    if sender_str == self_uri_str do
      {:ok, %{ok: true, ignored: :self_message}, []}
    else
      do_receive_effects(msg, ctx)
    end
  end

  @doc false
  def handle_reset(_args, _ctx) do
    {:ok, %{ok: true}, set_last(nil, nil, nil)}
  end

  # The `last_input / last_result / last_error` observability triple is always
  # set together — one helper keeps the `{:set, ...}` site count low + the
  # snapshot mutation atomic.
  defp set_last(input, result, error) do
    [{:set, :last_input, input}, {:set, :last_result, result}, {:set, :last_error, error}]
  end

  # `:configure` sets timeout_ms ONLY — NEVER the script (spec §5). Even if a
  # caller smuggles a `script` arg it is ignored: the action schema declares
  # only `timeout_ms`, and we read only that key here.
  @doc false
  def handle_configure(args, ctx) when is_map(args) do
    cur_timeout = ctx[:read].(:timeout_ms, @default_timeout_ms)
    new_timeout = Map.get(args, :timeout_ms, cur_timeout)
    {:ok, %{ok: true}, [{:set, :timeout_ms, new_timeout}]}
  end

  # --- internals ------------------------------------------------------------

  defp do_receive_effects(%Message{} = msg, ctx) do
    text = extract_text(msg.body)
    source_session_uri = ctx[:caller]
    self_uri = Map.get(ctx, :self_uri)
    python_handle = ctx[:read].(:python_handle, self_uri)
    timeout_ms = ctx[:read].(:timeout_ms, @default_timeout_ms)

    params = %{
      "text" => text,
      "from" => sender_string(msg.sender),
      "session" => session_string(source_session_uri)
    }

    case run_receive(python_handle, timeout_ms, params) do
      {:ok, :silent} ->
        {:ok, %{ok: true}, set_last(text, nil, nil)}

      {:ok, reply_text} ->
        effects =
          set_last(text, reply_text, nil) ++
            maybe_reply_effect(source_session_uri, self_uri, reply_text, msg)

        {:ok, %{ok: true}, effects}

      {:error, reason} ->
        if is_struct(self_uri, URI) do
          Logger.warning(
            "PyAgent #{URI.to_string(self_uri)} receive failed " <>
              "input=#{inspect(text)} reason=#{inspect(reason)}"
          )
        end

        {:ok, %{ok: false, error: error_kind(reason)}, set_last(text, nil, reason)}
    end
  end

  # Call the operator script's `receive` handler. A raising handler surfaces
  # as a structured JSON-RPC error from Domain.Python (-32603 / RpcError),
  # captured to last_error — the BEAM Kind never crashes.
  defp run_receive(handle, timeout, params) do
    case Python.call(handle, "receive", params, timeout) do
      {:ok, nil} ->
        {:ok, :silent}

      {:ok, %{"text" => t}} when is_binary(t) ->
        {:ok, t}

      {:ok, other} ->
        {:error, {:bad_python_result, other}}

      {:error, %{"code" => code, "message" => message}} ->
        {:error, {:python_error, code, message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  defp sender_string(%URI{} = u), do: URI.to_string(u)
  defp sender_string(s) when is_binary(s), do: s
  defp sender_string(_), do: ""

  defp session_string(%URI{} = u), do: URI.to_string(u)
  defp session_string(s) when is_binary(s), do: s
  defp session_string(_), do: ""

  defp error_kind({:python_error, _, _}), do: :python_error
  defp error_kind({:bad_python_result, _}), do: :bad_python_result
  defp error_kind(:not_alive), do: :not_alive
  defp error_kind(:rpc_timeout), do: :rpc_timeout
  defp error_kind(_), do: :other

  # Build a single `{:dispatch, %Cmd{}}` chat.send reply effect. Mirrors
  # NpAgent: the agent presents its OWN inline narrow `session.send` cap on
  # the concrete reply session (#154 — no `system://chat-reply` wildcard).
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

        target = Ezagent.URI.with_action(session, :session, :send)

        cmd =
          Cmd.new(target, :send, %{message: reply_msg}, %{
            caller: self_uri,
            caps:
              MapSet.new([
                %Ezagent.Capability{
                  Ezagent.Capability.cap(
                    :session,
                    Ezagent.Behavior.Session,
                    :send,
                    Ezagent.URI.instance(session),
                    Ezagent.Capability.workspace_of(session)
                  )
                  | granted_by: self_uri,
                    granted_at: DateTime.utc_now()
                }
              ]),
            reply: :ignore
          })

        [{:dispatch, cmd}]
    end
  end

  defp parse_session_uri(%URI{scheme: "session"} = u), do: u

  defp parse_session_uri(s) when is_binary(s) do
    try do
      case Ezagent.URI.new!(s) do
        %URI{scheme: "session"} = u -> u
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_session_uri(_), do: nil

  # Admin-only Behavior — no per-entity owner (mirrors NpAgent).
  @doc false
  def data_owner(_), do: :no_owner

  # --- activate/2 — rebuild transients + self-heal the subprocess ----------
  #
  # Re-spawns the Python subprocess from the EXISTING installed script
  # (`state.script_path`) on EVERY start via the shared AgentLifecycle helper
  # — it never RE-WRITES agent.py (that is the cap-gated create path's job).
  @impl Ezagent.Lifecycle
  def activate(state, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    phase_subscription = AgentLifecycle.subscribe_phase(self_uri)

    script_path = Map.get(state, :script_path)
    cwd = Map.get(state, :cwd)

    cond do
      not is_struct(self_uri, URI) ->
        Logger.warning(
          "Ezagent.Behavior.PyAgent.activate: non-URI self_uri " <>
            "#{inspect(self_uri)} — skipping subprocess re-spawn"
        )

      not (is_binary(script_path) and script_path != "") or not (is_binary(cwd) and cwd != "") ->
        # Demand-spawn / pre-instantiate: no installed script yet. The phase
        # subscription is in place; the Template's instantiate (or a later
        # ensure) brings the subprocess up.
        :ok

      true ->
        _ = ensure_python_alive(self_uri, script_path, cwd)
    end

    {:ok, %{phase_subscription: phase_subscription}}
  end

  # Build py's OWN %Spec{} (caller-owned, per the AgentLifecycle contract) and
  # delegate the alive-check + start to the shared helper.
  defp ensure_python_alive(self_uri, script_path, cwd) do
    spec = Ezagent.Template.PyAgent.build_spec(self_uri, script_path, cwd)

    case AgentLifecycle.ensure_alive(spec) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error(
          "Ezagent.Behavior.PyAgent.activate: ensure_alive failed for " <>
            "#{URI.to_string(self_uri)}: #{inspect(reason)}. PyAgent Kind stays " <>
            "alive in DEGRADED state (no Python subprocess); next :receive " <>
            "surfaces :not_alive."
        )

        err
    end
  end

  # --- handle_signal/2 — phase broadcasts → durable python_phase -----------
  @impl Ezagent.Lifecycle
  def handle_signal({:pty_phase, %URI{}, _phase, _meta} = signal, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    case AgentLifecycle.phase_from_signal(signal) do
      {:ok, agent_uri, phase} ->
        # PubSub topics are not an auth boundary — verify identity before
        # mutating state.
        if uris_equal?(agent_uri, self_uri) do
          {:ok, [{:set, :python_phase, phase}]}
        else
          Logger.warning(
            "Ezagent.Behavior.PyAgent.handle_signal: pty_phase agent_uri=" <>
              "#{URI.to_string(agent_uri)} != self_uri=#{inspect(self_uri)}; " <>
              "dropping (topic-collision defense)"
          )

          :ignore
        end

      :ignore ->
        :ignore
    end
  end

  def handle_signal(_other, _ctx), do: :ignore

  defp uris_equal?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp uris_equal?(_, _), do: false
end
