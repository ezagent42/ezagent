defmodule Ezagent.Behavior.NpAgent do
  @moduledoc """
  NpAgent Behavior — receives chat messages, evaluates numpy / sympy
  expressions in a per-agent Python subprocess via `Ezagent.Domain.Python`,
  and dispatches the result back into the originating session.

  ## Phase B migration (2026-05-29) — Lifecycle API

  Migrated from `use Ezagent.Behavior` to `use Ezagent.Lifecycle`
  per SPEC `2026-05-29-lifecycle-hooks-design.md` §2.3B (the
  TRANSIENTS case — modeled on the reference `Ezagent.Behavior.Sandbox`
  conversion). Two state containers + lifecycle moments hide the engine.

  ### Two-container split (SPEC §0.1 / §2.1 / §2.3B)

  - **`state` (PERSISTENT — auto-snapshotted)** — `python_handle`,
    `timeout_ms`, `cwd`, `python_phase`, `last_input`, `last_result`,
    `last_error`. `cwd` is read by the cold-load `activate/2` to
    re-spawn the Python subprocess; `python_phase` is the
    snapshot-persisted LV-badge mirror. All durable → `state`.
  - **`transients` (NEVER persisted — rebuilt every `activate/2`)** —
    `phase_subscription: %{topic, subscriber}`. The PTY phase-topic
    PubSub subscription binds the host `Kind.Server` process; it DIES
    with the process and has no serialization path (the textbook
    transient). `activate/2` re-subscribes on EVERY start, recording
    the CURRENT subscriber pid (the cold-restart-detectable token).

  ### Hook mapping (SPEC §3)

  - `init_slice/1` → `create/1` (PERSISTENT `state` only).
  - `post_init/2` + `handle_continue/3` → `activate/2` (UNIFIED start
    hook): subscribe to the phase topic (transient) + self-heal the
    Python subprocess from `state.cwd` on EVERY start (the §4-#113
    "fresh works, restart doesn't" fix made structural).
  - `handle_kind_message({:pty_phase, ...})` → `handle_signal/2`
    returning `{:set, :python_phase, phase}` (the phase is DURABLE
    state; the subscription delivering it is the transient).

  ## Phase 2-g r3 migration (2026-05-28)

  Earlier this Behavior was migrated to the declarative per-action
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

  use Ezagent.Lifecycle

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

  # The auto-derived slice key for `Ezagent.Behavior.NpAgent` is the
  # underscored last segment `NpAgent` → `:np_agent`, EXACTLY the
  # pre-Lifecycle `state_slice/0`. The snapshot-compat key is preserved
  # with no explicit override (SPEC §5 step 2 / §7 OQ-7) — the
  # hand-rolled `def state_slice, do: :np_agent` is gone.

  # `init_slice/1` → `create/1` (SPEC §3 mapping). Build ONLY the
  # durable fields. The phase subscription transient is `activate/2`'s
  # job. `args` carries the spawn-time values; a snapshot rehydrate
  # shadows this `state` on cold-load, so `create/1` runs once-ever.
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       python_handle: Map.get(args, :python_handle) || Map.get(args, :uri),
       timeout_ms: Map.get(args, :timeout_ms, @default_timeout_ms),
       cwd: Map.get(args, :cwd),
       python_phase: validate_phase(Map.get(args, :python_phase)),
       last_input: nil,
       last_result: nil,
       last_error: nil
     }}
  end

  # Reject corrupt rehydrated values (anything not nil-or-one-of-the-
  # three-atoms). The next live phase broadcast writes the correct value.
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
      case Ezagent.URI.new!(s) do
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

  # --- activate/2 — rebuild ALL transients + self-heal (SPEC §5 step 4) ----
  #
  # PTY-orphan-restart 2026-05-26 (Allen directive). UNIFIES the
  # pre-Lifecycle `post_init/2` + `handle_continue/3` into the ONE start
  # hook. Runs on EVERY start (fresh spawn, supervisor restart,
  # cold-load) — the structural guarantee that makes the §4-#113 "fresh
  # works, restart doesn't" bug impossible. Both steps are pre-`:ready`
  # boot work with NO self-deferral, so per §10-R1 both belong here in
  # `activate` (NOT `activated/2`):
  #
  #   1. transient: subscribe to the PTY phase topic. The subscription
  #      binds THIS Kind.Server process; it is rebuilt every start and
  #      recorded in `transients` (the subscriber pid is the
  #      cold-restart-detectable token).
  #   2. self-heal: (re)spawn the Python subprocess if `state.cwd` says
  #      there should be one. Best-effort — a brutal kill may have
  #      skipped `destroy`/`deactivate`, so the ensure-alive runs HERE
  #      every start (§OTP / §10-F4).
  @impl Ezagent.Lifecycle
  def activate(state, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    cwd = Map.get(state, :cwd)

    # 1. Rebuild the phase-topic subscription transient. Best-effort: a
    #    subscribe failure (PubSub down) is logged + swallowed —
    #    operator-visibility plumbing must not crash the boot.
    phase_subscription = subscribe_to_phase_topic(self_uri)

    # 2. Self-heal the Python subprocess from durable `state`. Skipped on
    #    the demand-spawn path (no cwd) — the phase subscription is still
    #    in place; an eventual Loader pass triggers a fresh
    #    `ensure_subprocess_alive` via its own dispatch.
    cond do
      not is_struct(self_uri, URI) ->
        Logger.warning(
          "Ezagent.Behavior.NpAgent.activate: non-URI self_uri " <>
            "#{inspect(self_uri)} — skipping subprocess re-spawn"
        )

      not is_binary(cwd) or cwd == "" ->
        :ok

      true ->
        _ = do_ensure_python_alive(self_uri, cwd)
    end

    {:ok, %{phase_subscription: phase_subscription}}
  end

  # Subscribe THIS process to the agent's PTY phase topic and return the
  # transient record. The `subscriber` pid (= the host Kind.Server) is the
  # cold-restart-detectable token: after a brutal kill + cold-load it is a
  # DIFFERENT, live pid — proving the subscription was rebuilt against the
  # new process, not rehydrated as a stale binding (SPEC §6 step 5c).
  defp subscribe_to_phase_topic(%URI{} = self_uri) do
    topic = "pty:phase:" <> URI.to_string(self_uri)

    try do
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
      %{topic: topic, subscriber: self()}
    catch
      kind, reason ->
        Logger.warning(
          "Ezagent.Behavior.NpAgent.activate: PubSub.subscribe failed " <>
            "(#{inspect(kind)}, #{inspect(reason)}) for #{URI.to_string(self_uri)}; " <>
            "phase tracking disabled for this incarnation"
        )

        %{topic: topic, subscriber: self()}
    end
  end

  defp subscribe_to_phase_topic(_), do: %{topic: nil, subscriber: self()}

  defp do_ensure_python_alive(self_uri, cwd) do
    case Ezagent.PluginNp.Template.NpAgent.ensure_subprocess_alive(self_uri, %{
           "cwd" => cwd
         }) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Ezagent.Behavior.NpAgent.activate: " <>
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

        {:error, reason}
    end
  end

  # --- handle_signal/2 — non-action GenServer messages (SPEC §9 OQ-3) ------
  #
  # `handle_kind_message/3` → `handle_signal/2`: consume the Python
  # Server's phase broadcasts on every `:starting | :running | :dead`
  # transition. The phase is DURABLE `state` (the snapshot-persisted
  # LV-badge mirror), so it is written via `{:set, :python_phase, phase}`
  # — NOT a transient. The subscription delivering the message is the
  # transient; the phase value it carries is persistent state.
  @impl Ezagent.Lifecycle
  def handle_signal({:pty_phase, %URI{} = agent_uri, phase, meta}, ctx)
      when phase in [:starting, :running, :dead] do
    self_uri = Map.get(ctx, :self_uri)

    # codex round-1 MED-2: PubSub topics are not an authentication
    # boundary. Verify identity BEFORE mutating state — drop mismatches
    # with a warning log.
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

      {:ok, [{:set, :python_phase, phase}]}
    else
      Logger.warning(
        "Ezagent.Behavior.NpAgent.handle_signal: pty_phase " <>
          "agent_uri=#{URI.to_string(agent_uri)} != self_uri=" <>
          "#{inspect(self_uri)}; dropping (topic-collision defense)"
      )

      :ignore
    end
  end

  def handle_signal(_other, _ctx), do: :ignore

  defp uris_equal?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp uris_equal?(_, _), do: false
end
