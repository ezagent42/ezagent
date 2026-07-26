defmodule Ezagent.Kind.IngressCensus do
  @moduledoc """
  V5 pid-closure (use-side) — ENUMERATION-phase ingress census for
  `Ezagent.Kind.Server` (report-only, log-only).

  ## Purpose

  Before the Kind actor's mailbox can be SEALED (a later V5 phase), we need
  the empirical list of every message shape that actually reaches the
  GenServer callbacks of the shared Kind host. This module is the
  classifier half of that census: `Ezagent.Kind.Server` calls
  `observe/2` as the FIRST expression of every ingress callback clause
  (`init/1`, `handle_continue/2`, `handle_call/3`, `handle_cast/2`,
  `handle_info/2`, `terminate/2`), and this module classifies the ingress
  and emits it as a telemetry event:

      [:ezagent, :kind, :ingress_census]
      measurements: %{count: 1}
      metadata:     %{callback: callback, class: class, shape: shape}

  Same `:telemetry.execute/3` idiom as `Ezagent.Dlq` (`[:ezagent, :dlq, :write]`)
  and `Ezagent.Notifications` (`[:ezagent, :notification, :emit]`).

  ## Hard guarantees (enumeration phase contract)

  - **NO enforcement.** A `{:would_drop, _}` classification is a census
    observation, never an error. Nothing in this module raises, exits, or
    gates; no CI job may read these events as a pass/fail signal.
  - **NO behavior change.** `observe/2` never touches the message and
    always returns `:ok`; the instrumented clause then runs its ORIGINAL
    logic unchanged. Runtime behavior is byte-for-byte identical with or
    without the instrumentation.
  - **Bounded metadata.** The `shape` descriptor is SMALL by construction
    (a head atom + tuple size, a bare atom, or a fixed `:other_*` tag).
    Full message payloads are NEVER dumped into telemetry metadata —
    Kind traffic can carry private authority state, slices, and cap
    artifacts, none of which may leave the process.

  ## Classes

  `class` is `:would_drop` for anything unrecognized (the future seal
  candidate list). Sanctioned classes:

  - `:lifecycle` — `init/1`, `handle_continue/2`, `terminate/2` (these are
    OTP-driven, not mailbox ingress; classified for completeness).
  - `:kind_message_verb` — the known Kind protocol verbs (bare atoms or
    tuple heads), mirrored from
    `Ezagent.ActorBoundaryScanner.@kind_message_verbs`. Mirrored as DATA
    (this app cannot reference the core scanner module — the §4.2
    reverse-boundary gate forbids actor → core references); drift is
    acceptable because a NEW verb simply lands in `:would_drop` and shows
    up in the census dump for a human to re-classify.
  - `:ready_gate` — `{:ezagent_external_ready_gate, uri_str, result}`
    self-signals from the ReadyGate waiter.
  - `:run_deferred` — `{:ezagent_run_deferred, cmds}` deferred post-commit
    dispatch self-messages.
  - `:snapshot_tick` — `:snapshot_tick` periodic-persistence self-timer.
  - `:monitor_down` — `{:DOWN, ref, :process, pid, reason}` (monitors;
    includes `Task.async` companion DOWNs).
  - `:exit` — `{:EXIT, pid, reason}` (the Kind traps exits for graceful
    `terminate/2`, so linked-resource deaths arrive as messages).
  - `:task_reply` — `{ref, result}` reference-headed replies
    (`Task.async` / detached-task results).

  ## `:sys` traffic — PERMANENT static-ban-only tier

  `:sys.get_state/2`, `:sys.replace_state/2`, `:sys.get_status/1` and
  friends are handled INSIDE the `:gen_server`/`proc_lib` shim and NEVER
  reach these callbacks — they cannot appear in this census BY DESIGN.
  `:sys` is therefore a PERMANENT static-ban-only tier (enforced by the
  actor-boundary scanner's `@sys_banned`, not by any runtime census):
  out of census scope, permanently. See the comment at the first
  instrumentation site in `Ezagent.Kind.Server.init/1`.
  """

  @event [:ezagent, :kind, :ingress_census]

  @callbacks [:init, :handle_continue, :handle_call, :handle_cast, :handle_info, :terminate]

  # Mirror of `Ezagent.ActorBoundaryScanner.@kind_message_verbs`
  # (apps/ezagent_core/lib/ezagent/actor_boundary_scanner.ex:95-120).
  # Mirrored as data — see the moduledoc "Classes" section for why the
  # actor app cannot reference the core SSOT directly.
  @kind_message_verbs MapSet.new([
                        :ezagent_detach,
                        :ezagent_dispatch,
                        :ezagent_em_reconcile,
                        :ezagent_external_ready_gate,
                        :ezagent_get_slice,
                        :ezagent_kind_module,
                        :ezagent_launch_context_relay,
                        :ezagent_lifecycle_destroy,
                        :ezagent_mount,
                        :ezagent_post_init,
                        :ezagent_presence_diff,
                        :ezagent_recover_settlements,
                        :ezagent_recredential_generation,
                        :ezagent_reply,
                        :ezagent_resolve_action_subject,
                        :ezagent_revoke_all_to,
                        :ezagent_run_deferred,
                        :ezagent_runtime_view,
                        :ezagent_validate_cap_artifact,
                        :ezagent_verify_cap_artifact,
                        :ezagent_worker_initial_subscribe,
                        :ezagent_worker_resubscribe_result,
                        :ezagent_worker_resubscribe_retry,
                        :ezagent_worker_subscribe_result
                      ])

  @typedoc "GenServer ingress callback being observed."
  @type callback ::
          :init | :handle_continue | :handle_call | :handle_cast | :handle_info | :terminate

  @typedoc """
  Census class. `:would_drop` = unrecognized shape (seal candidate);
  every other value is a sanctioned framework/verb class.
  """
  @type class ::
          :lifecycle
          | :kind_message_verb
          | :ready_gate
          | :run_deferred
          | :snapshot_tick
          | :monitor_down
          | :exit
          | :task_reply
          | :would_drop

  @doc """
  Classify one ingress and emit it to `[:ezagent, :kind, :ingress_census]`.

  NEVER raises, NEVER touches `message`, always returns `:ok`. Called as
  the first expression of every `Ezagent.Kind.Server` ingress callback
  clause; instrumentation is observe-and-log ONLY (enumeration phase).
  """
  @spec observe(callback(), term()) :: :ok
  def observe(callback, message) when callback in @callbacks do
    {class, shape} = classify(callback, message)

    :telemetry.execute(@event, %{count: 1}, %{callback: callback, class: class, shape: shape})

    :ok
  end

  @doc """
  Pure classification of an ingress, exposed for tests. Returns
  `{class, shape}` where `class == :would_drop` marks an unrecognized
  shape. `shape` is always a SMALL bounded descriptor (see moduledoc).
  """
  @spec classify(callback(), term()) :: {class(), term()}

  # OTP-driven callbacks are not mailbox ingress — classified :lifecycle.
  def classify(callback, message) when callback in [:init, :handle_continue, :terminate] do
    {:lifecycle, shape_summary(message)}
  end

  def classify(_callback, message) when is_atom(message) do
    cond do
      message == :snapshot_tick -> {:snapshot_tick, :snapshot_tick}
      MapSet.member?(@kind_message_verbs, message) -> {:kind_message_verb, message}
      true -> {:would_drop, message}
    end
  end

  def classify(_callback, message) when is_tuple(message) and tuple_size(message) > 0 do
    head = elem(message, 0)
    size = tuple_size(message)

    cond do
      is_atom(head) and MapSet.member?(@kind_message_verbs, head) ->
        {verb_class(head), {head, size}}

      head == :DOWN and size == 5 ->
        {:monitor_down, {:DOWN, 5}}

      head == :EXIT and size == 3 ->
        {:exit, {:EXIT, 3}}

      is_reference(head) ->
        {:task_reply, {:ref_reply, size}}

      true ->
        {:would_drop, shape_summary(message)}
    end
  end

  def classify(_callback, message), do: {:would_drop, shape_summary(message)}

  defp verb_class(:ezagent_external_ready_gate), do: :ready_gate
  defp verb_class(:ezagent_run_deferred), do: :run_deferred
  defp verb_class(_verb), do: :kind_message_verb

  # Bounded shape summary — NEVER a payload dump. Atom heads and tuple
  # sizes only; everything else collapses to a fixed `:other_*` tag.
  defp shape_summary(message) when is_atom(message), do: message

  defp shape_summary(message) when is_tuple(message) do
    size = tuple_size(message)

    if size > 0 and is_atom(elem(message, 0)) do
      {elem(message, 0), size}
    else
      {:other_tuple, size}
    end
  end

  defp shape_summary(message) when is_list(message), do: :other_list
  defp shape_summary(message) when is_binary(message), do: :other_binary
  defp shape_summary(message) when is_map(message), do: :other_map
  defp shape_summary(message) when is_reference(message), do: :other_reference
  defp shape_summary(message) when is_pid(message), do: :other_pid
  defp shape_summary(_message), do: :other
end
