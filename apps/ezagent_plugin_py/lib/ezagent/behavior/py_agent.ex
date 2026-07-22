defmodule Ezagent.ActionSet.PyAgent do
  @moduledoc """
  PyAgent Behavior (py-agent P4b) — the STATE half of the GENERAL script-driven
  Python flavor, folded onto the UNIFIED `Ezagent.Entity.Agent` Kind (curl
  precedent). The operator script runs via the `"receive"` JSON-RPC method on
  the per-agent `Ezagent.Domain.Python` subprocess, but that round-trip lives in
  the TRANSPORT half (`EzagentPluginPy.BridgeAdapter`, `:in_process_sync`). The
  base flavor-blind `Behavior.Agent.Receive` owns `:receive` on `Entity.Agent`,
  routes to the adapter, then re-dispatches the result to this Behavior's
  `:py_sync_result` action.

  The former `np` compute agent is a py-ROLE — its chat→compute heuristic lives
  in the role's script, not in a Behavior.

  - **`:py_sync_result`** — persist the adapter's result (`last_*`) and, on a
    non-nil reply, dispatch a `chat.send` back into the originating session. The
    actions are py-NAMESPACED (the `{Kind, action}` map is global per Kind; curl
    owns generic `:configure`/`:sync_result` on `Entity.Agent`).
  - **cap axis** — `:py_sync_result` on `:agent`; `:py_reset`/`:py_configure`
    on `:any` (substituted to the host type_name); see `required_caps/0`.
  - **script is immutable post-create** — `:py_configure` sets `timeout_ms`
    ONLY (never the script); `:py_reset` clears `last_*`. The script file is
    written once at create (`Template.PyAgent.instantiate/3`); see spec §5.

  ## The wire (spec §1)

      Domain.Python.call(handle, "receive", %{text, from, session}, timeout)

  runs in `BridgeAdapter`. The script registers a `@method("receive")` handler
  returning a reply payload (a map with a `"text"` key) or `None`/`nil` to stay
  silent. A raising script is captured to `last_error` (durable) + logged; the
  BEAM Kind does NOT crash.

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

  Self-reply flood protection is handled at the ROUTING layer (#98 — an Always
  rule no longer re-triggers on the agent's own reply), shared by all flavors on
  `Entity.Agent`; it is no longer this Behavior's concern.
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.{Cmd, Message}
  alias Ezagent.Agent.ErrorSignal
  alias Ezagent.Domain.Python.AgentLifecycle

  @default_timeout_ms 10_000

  action(:py_sync_result,
    # `result` is the adapter's `{:ok, %{text}} | {:ok, :silent} | {:error, term}`
    # tuple this handler pattern-matches itself, hence `:term`. `source_session`
    # is the originating session URI. `in_msg_id` rides through undeclared (read
    # via Map.get in the handler, curl precedent).
    args: %{result: :term, source_session: {:option, :uri}, user_text: :string},
    returns: %{ok: :boolean, error: :atom},
    caps: [:py_sync_result],
    modes: [:cast],
    description:
      "Persist the py :in_process_sync bridge_adapter result (the operator " <>
        "script's receive() output) and reply it into the originating session"
  )

  action(:py_reset,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:py_reset],
    modes: [:call],
    description: "Clear the agent's last_input / last_result / last_error"
  )

  action(:py_configure,
    args: %{timeout_ms: :integer},
    returns: %{ok: :boolean},
    caps: [:py_configure],
    modes: [:call],
    description:
      "Update the agent's per-call timeout (ms). NEVER mutates the script " <>
        "(immutable post-create, spec §5)"
  )

  action(:py_ensure_alive,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:py_ensure_alive],
    modes: [:cast],
    description:
      "Retry the Python subprocess provision from durable script_path/cwd " <>
        "(PR #1259 item 1b — the async adopt-path retry; sets/clears the " <>
        ":last_error {:provision_failed, _} marker)"
  )

  # P4b — PyAgent folded onto the UNIFIED Entity.Agent Kind. Every action is
  # py-NAMESPACED (cc-headless precedent) because the {Kind, action} → Behavior
  # map is global per Kind and curl already owns generic `:configure`/
  # `:sync_result` on Entity.Agent.
  #   - :py_reset / :py_configure — operator actions on the `:any` kind axis
  #     (the runtime substitutes the host type_name `:agent` at dispatch).
  #   - :py_sync_result — the internal re-dispatch (curl model): declare it on
  #     `:agent` to mirror curl; the base :receive re-dispatch grants a matching
  #     `cap(:any, :any, :py_sync_result)` which authorizes it.
  @doc false
  def required_caps do
    %{
      py_reset: Ezagent.Capability.cap(:any, __MODULE__, :py_reset),
      py_configure: Ezagent.Capability.cap(:any, __MODULE__, :py_configure),
      py_sync_result: Ezagent.Capability.cap(:agent, __MODULE__, :py_sync_result),
      # PR #1259 item 1b — self-authority retry (the adopt path dispatches it
      # with an inline self-cap, mirroring sandbox.update_config).
      py_ensure_alive: Ezagent.Capability.cap(:agent, __MODULE__, :py_ensure_alive)
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

  # P4b — :py_sync_result is re-dispatched by the base flavor-blind
  # `Behavior.Agent.Receive` after the py `:in_process_sync` bridge_adapter ran
  # the script (curl precedent). `result` is the adapter's return; this STATE
  # half persists `last_*` + replies into the originating session.
  @doc false
  def handle_py_sync_result(%{result: result} = args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    source_session = Map.get(args, :source_session)
    user_text = Map.get(args, :user_text, "")
    in_msg_id = Map.get(args, :in_msg_id)
    reply_cap = Map.get(args, :reply_cap)

    case result do
      {:ok, :silent} ->
        {:ok, %{ok: true}, set_last(user_text, nil, nil)}

      {:ok, %{text: reply}} when is_binary(reply) ->
        effects =
          set_last(user_text, reply, nil) ++
            maybe_reply_effect(source_session, self_uri, reply, in_msg_id, reply_cap)

        {:ok, %{ok: true}, effects}

      {:error, reason} ->
        if is_struct(self_uri, URI) do
          Logger.warning(
            "PyAgent #{URI.to_string(self_uri)} receive failed " <>
              "input=#{inspect(user_text)} reason=#{inspect(reason)}"
          )
        end

        # G5 source 2 — a py failure was previously SILENT to the user (only
        # `last_error` + this log line). Reply with the STRUCTURED error body
        # so the shared error surface renders a per-viewer card.
        effects =
          set_last(user_text, nil, reason) ++
            maybe_reply_error(source_session, self_uri, reason, in_msg_id, reply_cap)

        {:ok, %{ok: false, error: error_kind(reason)}, effects}
    end
  end

  @doc false
  def handle_py_reset(_args, _ctx) do
    {:ok, %{ok: true}, set_last(nil, nil, nil)}
  end

  # PR #1259 item 1b — asynchronous provision retry. Dispatched as a
  # fire-and-forget `:cast` by `Template.PyAgent.instantiate/3`'s adopt arm
  # when it finds the adopted agent's subprocess DEAD (a prior provision
  # failed), so an adopt RETRIES instead of reporting success over a zombie.
  # Runs in the agent's own Kind process (same blocking profile as
  # `activate/2`'s provision — the agent's mailbox waits, never the creator).
  # Sets/clears the `{:provision_failed, _}` `:last_error` marker (item 1a).
  @doc false
  def handle_py_ensure_alive(_args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    script_path = ctx[:read].(:script_path, nil)
    cwd = ctx[:read].(:cwd, nil)

    cond do
      not is_struct(self_uri, URI) ->
        {:ok, %{ok: false}, []}

      not (is_binary(script_path) and script_path != "") or not (is_binary(cwd) and cwd != "") ->
        # No installed script yet (pre-instantiate) — nothing to provision.
        {:ok, %{ok: false}, []}

      true ->
        case ensure_python_alive(self_uri, script_path, cwd) do
          :ok ->
            effects =
              case ctx[:read].(:last_error, nil) do
                {:provision_failed, _} -> [{:set, :last_error, nil}]
                _ -> []
              end

            {:ok, %{ok: true}, effects}

          {:error, reason} ->
            {:ok, %{ok: false}, [{:set, :last_error, {:provision_failed, reason}}]}
        end
    end
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
  def handle_py_configure(args, ctx) when is_map(args) do
    cur_timeout = ctx[:read].(:timeout_ms, @default_timeout_ms)
    new_timeout = Map.get(args, :timeout_ms, cur_timeout)
    {:ok, %{ok: true}, [{:set, :timeout_ms, new_timeout}]}
  end

  # --- internals ------------------------------------------------------------

  defp error_kind({:python_error, _, _}), do: :python_error
  defp error_kind({:bad_python_result, _}), do: :bad_python_result
  defp error_kind(:not_alive), do: :not_alive
  defp error_kind(:rpc_timeout), do: :rpc_timeout
  defp error_kind(_), do: :other

  # Build a single `{:dispatch, %Cmd{}}` chat.send reply effect. Mirrors
  # the per-subprocess agent: the agent presents its OWN inline narrow `session.send` cap on
  # the concrete reply session (#154 — no `system://chat-reply` wildcard).
  defp maybe_reply_effect(nil, _self_uri, _text, _in_msg_id, _reply_cap), do: []
  defp maybe_reply_effect("", _self_uri, _text, _in_msg_id, _reply_cap), do: []
  defp maybe_reply_effect(_, nil, _text, _in_msg_id, _reply_cap), do: []

  defp maybe_reply_effect(
         session_uri,
         %URI{} = self_uri,
         text_or_body,
         in_msg_id,
         %Ezagent.Capability{} = reply_cap
       ) do
    case parse_session_uri(session_uri) do
      nil ->
        []

      %URI{} = session ->
        reply_msg =
          Message.new(self_uri, reply_body(text_or_body), ref_id: in_msg_id)

        target = Ezagent.URI.with_action(session, :session, :send)

        cmd =
          Cmd.new(target, :send, %{message: reply_msg}, %{
            caller: self_uri,
            authenticated_principal: self_uri,
            caps: MapSet.new([reply_cap]),
            reply: :ignore
          })

        [{:dispatch, cmd}]
    end
  end

  # Cap-signing: reply only with a REAL signed capability struct; any other
  # `reply_cap` shape (nil/unsigned) drops the reply rather than dispatching
  # unauthenticated.
  defp maybe_reply_effect(_session_uri, _self_uri, _text, _in_msg_id, _reply_cap), do: []

  # G5 source 2 — structured error reply (see `Ezagent.ActionSet.CurlAgent`).
  defp maybe_reply_error(session_uri, self_uri, reason, in_msg_id, reply_cap) do
    maybe_reply_effect(
      session_uri,
      self_uri,
      ErrorSignal.reply_body(reason),
      in_msg_id,
      reply_cap
    )
  end

  defp reply_body(text) when is_binary(text), do: %{text: text, attachments: []}
  defp reply_body(%{} = body), do: body

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

  # Admin-only Behavior — no per-entity owner.
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

    transients = %{phase_subscription: phase_subscription}

    cond do
      not is_struct(self_uri, URI) ->
        Logger.warning(
          "Ezagent.ActionSet.PyAgent.activate: non-URI self_uri " <>
            "#{inspect(self_uri)} — skipping subprocess re-spawn"
        )

        {:ok, transients}

      not (is_binary(script_path) and script_path != "") or not (is_binary(cwd) and cwd != "") ->
        # Demand-spawn / pre-instantiate: no installed script yet. The phase
        # subscription is in place; the Template's instantiate (or a later
        # ensure) brings the subprocess up.
        {:ok, transients}

      true ->
        # PR #1259 codex review item 1a — a provision failure must be VISIBLY
        # recorded, not just logged: persist the `{:provision_failed, reason}`
        # marker into the durable `:last_error` (the same observability field
        # the receive path uses), and clear a stale provision marker on a
        # successful (re)provision. Operators/tests can read the slice instead
        # of tailing logs; the adopt path (`Template.PyAgent.instantiate/3`
        # `:already_started` arm) retries a dead subprocess asynchronously via
        # `:py_ensure_alive`.
        case ensure_python_alive(self_uri, script_path, cwd) do
          :ok ->
            {:ok, transients, clear_provision_failure(state)}

          {:error, reason} ->
            {:ok, transients, Map.put(state, :last_error, {:provision_failed, reason})}
        end
    end
  end

  # Clear ONLY a provision-failure marker (never a receive-path last_error).
  defp clear_provision_failure(%{last_error: {:provision_failed, _}} = state),
    do: %{state | last_error: nil}

  defp clear_provision_failure(state), do: state

  # Build py's OWN %Spec{} (caller-owned, per the AgentLifecycle contract) and
  # delegate the alive-check + start to the shared helper.
  defp ensure_python_alive(self_uri, script_path, cwd) do
    spec = Ezagent.Template.PyAgent.build_spec(self_uri, script_path, cwd)

    case AgentLifecycle.ensure_alive(spec) do
      :ok ->
        :ok

      {:error, reason} = err ->
        Logger.error(
          "Ezagent.ActionSet.PyAgent.activate: ensure_alive failed for " <>
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
            "Ezagent.ActionSet.PyAgent.handle_signal: pty_phase agent_uri=" <>
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
