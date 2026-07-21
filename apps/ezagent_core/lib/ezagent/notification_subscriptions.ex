defmodule Ezagent.NotificationSubscriptions do
  @moduledoc """
  Unified registry for notification subscriptions (SPEC v2 PR-N1
  Allen 2026-05-24 amendment).

  Analogue of `Ezagent.CapabilityRegistry` for notification streams:
  one entry point to register / list / unregister an entity's
  subscriptions, cap-gated, persistent across process restarts.

  ## Why a registry instead of raw PubSub.subscribe

  Per Allen 2026-05-24 — ad-hoc `Phoenix.PubSub.subscribe` calls
  scattered across LV / plugin code = drift + invisibility:
  - operators can't see who's subscribed to what
  - cap denial has nothing to enforce against
  - LV reconnection loses subscriptions (PubSub is process-scoped;
    the registry survives)

  The registry stores intent (`entity X subscribes to stream Y`),
  and live processes (LV mount, plugin worker) consult it on startup
  to actually `PubSub.subscribe`. Adding a subscription
  re-subscribes any live owners; removing it unsubscribes them.

  ## Owner-mediated `:protected` ETS (codex PR-N1 round-2 HIGH-1 fix)

  Round-1 placed the table under `EzagentCore.EtsOwner` with `:public`
  (matching other registries). Codex round-2 correctly observed:
  `:public` lets ANY BEAM code call `:ets.insert/2` / `:ets.delete/2`
  on `:ezagent_notification_subscriptions`, bypassing
  `check_subscribe_cap/2` + `authorize_unregister/2`.

  This module now owns its OWN `:protected` ETS table via a
  dedicated GenServer:

  - reads (`list_subscriptions/1`, `list_subscribers/1`) go direct
    via `:ets.match` — `:protected` allows reads from any process
  - writes (`register_*`, `unregister_*`) go through GenServer.call
    so the table is only modified after cap enforcement; serialised
    on the owner process

  Trade-off: writes are now serialised (one-at-a-time through the
  GenServer mailbox). Subscriptions are not a hot path (1 per LV
  mount / plugin worker), so the cost is acceptable for the
  enforcement boundary it gives.

  ## Explicit ctx — no `:system` default (codex round-2 CRITICAL fix)

  Round-1 had `ctx \\ %{caps: :system}` defaults. ANY caller could
  call the arity-2 form and get system authority — the cap fix
  was a no-op. Round-2 removes the defaults; all public mutation
  APIs require a 3-arg `ctx`. Trusted internal callers use
  `system_register/2` / `system_unregister/2` — same module, but
  the call site is grep-visible.

  ## Tightened admin predicate (codex round-2 HIGH-3 fix)

  Round-1 `has_admin_cap?` matched ANY `workspace_uri: :any` cap.
  Codex round-2: a narrow cross-workspace Chat.send cap would
  qualify. Now requires `behavior == Ezagent.ActionSet.Notifications
  AND workspace_uri == :any` — i.e., specifically a notifications-
  admin cap. Tested.

  ## Threat model (codex PR-N1 round-5 disposition, option a, Allen 2026-05-24)

  This registry enforces **USER-level authorization** (entity A is
  allowed / forbidden to subscribe to entity B's stream). It does
  **NOT** defend against malicious BEAM-resident code.

  Specifically, the following bypass paths are KNOWN and accepted:

  1. `:sys.replace_state(__MODULE__, fn s -> :ets.insert(table, …);
     s end)` — runs in the owner-process context, bypasses cap
     checks. OTP intends `:sys.*` messages to be usable by any
     in-VM caller.
  2. `Phoenix.PubSub.subscribe(EzagentCore.PubSub, "esr:entity:VICTIM:slice_changed")`
     — topic names are public-derivable from URIs; PubSub has no
     subscriber authorization. Listeners may receive broadcasts
     they had no cap for.

  Mitigations available IF FUTURE PHASES need plugin-vs-plugin
  isolation:

  - Move untrusted code to a separate BEAM node, talk via supervised
    Erlang RPC (Roadmap §6+ federation)
  - Run untrusted plugins in OS-level isolation (container / process)
  - Per-recipient PubSub fan-out with subscriber tokens (instead of
    open topics)

  Current ezagent threat model assumes plugin authors are TRUSTED
  (they ship code with full BEAM access by definition). The cap
  system protects USER data (Alice can't unsubscribe Bob), not
  PLUGIN code from other PLUGIN code.

  ## Cap-gated subscribe (`subscribe/2`)

  The companion to `Ezagent.SliceChange.subscribe_unverified/1` —
  goes through this registry to record the intent AND then calls
  the unverified subscribe. Use this from LV mounts + plugin
  workers acting on behalf of a logged-in user; use the unverified
  path only from internal machinery (e.g. a Kind subscribing to
  its OWN topic).
  """

  use GenServer
  require Logger
  alias Ezagent.Capability

  @table :ezagent_notification_subscriptions

  # --- supervised init ----------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "ETS table name (read-only access via `:ets.match/2`)."
  def table, do: @table

  # --- public mutation API (cap-gated) ------------------------------

  @doc """
  Register that `entity_uri` wants to receive slice-change events
  for `stream_uri`. Cap-gated by `ctx`.

  `ctx` MUST include `:caps` (MapSet of `Ezagent.Capability` structs
  OR the atom `:system`). For non-`:system` ctx, must also include
  `:caller` (the URI on whose behalf the registration is being made).

  Returns `:ok` on cap success, `{:error, :unauthorized}` on cap
  miss, `{:error, :missing_caps_in_ctx}` when `ctx[:caps]` is absent.
  """
  @spec register_subscription(URI.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def register_subscription(%URI{} = entity_uri, stream_uri, ctx)
      when is_map(ctx) and (is_struct(stream_uri, URI) or is_binary(stream_uri)) do
    # Codex PR-N1 round-3 CRITICAL fix: the public API MUST NOT
    # accept caller-supplied `%{caps: :system}`. Round-2 trusted
    # the ctx shape, so any plugin could pass `%{caps: :system}`
    # and bypass cap enforcement entirely. The distinct
    # `:public_register` GenServer message guarantees the cap path
    # ALWAYS runs for this entry point.
    case ctx do
      %{caps: :system} ->
        {:error, :system_caps_not_allowed_in_public_api}

      _ ->
        GenServer.call(__MODULE__, {:public_register, entity_uri, stream_uri, ctx})
    end
  end

  def register_subscription(_, _, _), do: {:error, :invalid_args}

  @doc """
  Unregister a subscription.

  `ctx` MUST include `:caller`. Authorisation:
  - `ctx.caller == entity_uri` (self-unsubscribe) — allowed
  - notifications-admin cap (`Behavior.Notifications` +
    `workspace_uri: :any`) — allowed
  - otherwise — `{:error, :unauthorized}`

  Idempotent: deleting a missing row returns `:ok`.
  """
  @spec unregister_subscription(URI.t() | String.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def unregister_subscription(entity_uri, stream_uri, ctx)
      when is_map(ctx) and
             (is_struct(entity_uri, URI) or is_binary(entity_uri)) and
             (is_struct(stream_uri, URI) or is_binary(stream_uri)) do
    # Codex round-3 CRITICAL fix — see `register_subscription/3`.
    case ctx do
      %{caps: :system} ->
        {:error, :system_caps_not_allowed_in_public_api}

      _ ->
        GenServer.call(__MODULE__, {:public_unregister, entity_uri, stream_uri, ctx})
    end
  end

  def unregister_subscription(_, _, _), do: {:error, :invalid_args}

  # --- system call sites — DELETED (codex round-4 CRITICAL fix) ----
  #
  # Round-3 added `system_register/2` + `system_unregister/2` that
  # dispatched to distinct `:system_register` / `:system_unregister`
  # GenServer messages, which bypassed the cap check. Codex round-4
  # correctly identified: message TAGS don't AUTHENTICATE callers.
  # Any in-VM module could `GenServer.call(__MODULE__,
  # {:system_register, victim, stream})` and reach the bypass path
  # directly.
  #
  # Since PR-N1 has ZERO production callers of system_*, the safest
  # fix is to delete the API + the GenServer clauses entirely. There
  # is now NO system bypass — every write goes through the cap-gated
  # public path.
  #
  # When PR-N2+ legitimately needs to seed subscriptions at boot
  # (e.g. plugin-supplied default subscriptions), design a
  # constrained mechanism then. Likely shape:
  #   - `init/1` of this GenServer reads a config-derived seed list
  #     ONCE during its own startup — the only trusted moment when
  #     plugin code cannot have run yet to forge a message
  #   - The seed list lives in `:ezagent_core, :notification_seeds`
  #     compile-time config, populated by each plugin's `boot/1`
  #     return value (not by runtime function calls)
  #
  # Until then: any caller wanting a subscription MUST present a
  # real `Behavior.Notifications` cap.

  # --- cap-gated subscribe (codex round-5 option a) -----------------

  @doc """
  Cap-gated subscribe: record intent in the registry AND subscribe
  the calling process to `Ezagent.SliceChange` events for `stream_uri`.

  This is the audit-trail-friendly path. Bypassing this and calling
  `SliceChange.subscribe_unverified/1` directly works at the BEAM
  level (PubSub is open), but the registry won't know about your
  subscription — LV reconnect re-subscribe + plugin reboot re-subscribe
  + operator introspection of "who's listening to X" all lose
  visibility.

  Same authorisation as `register_subscription/3`: explicit `ctx`,
  no `:system` shortcut, caller must be the entity or notifications-admin.

  Returns `:ok | {:error, term()}`. On `:ok`, the calling process is
  now subscribed (receives `{:slice_changed, event_map}`) AND the
  registry row is in place.
  """
  @spec subscribe(URI.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def subscribe(%URI{} = entity_uri, stream_uri, ctx)
      when is_map(ctx) and (is_struct(stream_uri, URI) or is_binary(stream_uri)) do
    # Codex PR-N1 round-6 HIGH fix: TRANSACTIONAL ordering.
    # Round-5 inserted the registry row first, then called
    # PubSub.subscribe. If the second step failed, the row was
    # left durably committed but the caller process was NOT
    # subscribed — an LV reconnect path that consults the registry
    # would later "restore" a phantom subscription that the caller
    # was told failed.
    #
    # New ordering: register intent → try PubSub.subscribe →
    # on failure or exception, ROLLBACK the registry row by
    # deleting it via the same ctx (which passes the original
    # auth check, so rollback is auditable + idempotent).
    with :ok <- register_subscription(entity_uri, stream_uri, ctx) do
      try do
        case Ezagent.SliceChange.subscribe_unverified(stream_uri) do
          :ok ->
            :ok

          {:error, _} = pubsub_err ->
            rollback_register(entity_uri, stream_uri, ctx)
            pubsub_err
        end
      rescue
        exception ->
          rollback_register(entity_uri, stream_uri, ctx)
          reraise(exception, __STACKTRACE__)
      end
    end
  end

  def subscribe(_, _, _), do: {:error, :invalid_args}

  @doc """
  Inverse — drop the registry row AND unsubscribe from the PubSub
  topic. Same auth shape as `unregister_subscription/3`.

  Codex PR-N1 round-7 MED fix: AUTH PREFLIGHT FIRST (no side
  effects on failure), THEN PubSub unsubscribe, THEN registry
  delete. Round-6 reordered PubSub-then-row, which leaked a
  PubSub-state mutation on unauthorized calls: an unauthorized
  caller could silently `PubSub.unsubscribe` a victim process
  before the cap check rejected the operation.

  Failure-mode ordering for authorized calls:
  - PubSub unsubscribe fails → registry row stays (operator-
    visible intent beats silent process-still-subscribed leak)
  - All steps :ok → caller cleanly off both transport + intent
  """
  @spec unsubscribe(URI.t() | String.t(), URI.t() | String.t(), map()) ::
          :ok | {:error, term()}
  def unsubscribe(entity_uri, stream_uri, ctx)
      when is_map(ctx) and
             (is_struct(entity_uri, URI) or is_binary(entity_uri)) and
             (is_struct(stream_uri, URI) or is_binary(stream_uri)) do
    with :ok <- public_ctx?(ctx),
         :ok <- preflight_unsubscribe(entity_uri, ctx),
         :ok <- Ezagent.SliceChange.unsubscribe_unverified(stream_uri) do
      unregister_subscription(entity_uri, stream_uri, ctx)
    end
  end

  def unsubscribe(_, _, _), do: {:error, :invalid_args}

  # Codex round-7 MED — pure auth check (no side effects). Mirrors
  # the auth path inside `authorize_unregister/2` but does NOT
  # touch the table. Used by `unsubscribe/3` as a preflight so an
  # unauthorized caller never reaches the PubSub side-effecting
  # step. Defers to GenServer.call so we use the same predicate
  # the real `unregister_subscription/3` will run.
  defp preflight_unsubscribe(entity_uri, ctx) do
    GenServer.call(__MODULE__, {:preflight_unsubscribe, entity_uri, ctx})
  end

  # Public-API ctx-shape guard — mirror the rejection in
  # `unregister_subscription/3` so preflight surfaces the same
  # error class for `%{caps: :system}` callers.
  defp public_ctx?(%{caps: :system}), do: {:error, :system_caps_not_allowed_in_public_api}
  defp public_ctx?(_), do: :ok

  # Codex round-6 rollback helper — best-effort row delete.
  # We do NOT propagate this error; the caller already has the
  # PubSub failure to react to. Logging the rollback failure
  # (rare — would require the registry GenServer to be down right
  # after it accepted the insert) is informational only.
  defp rollback_register(entity_uri, stream_uri, ctx) do
    case unregister_subscription(entity_uri, stream_uri, ctx) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Ezagent.NotificationSubscriptions: rollback_register failed after PubSub error " <>
            "(entity=#{URI.to_string(entity_uri)} stream=#{inspect(stream_uri)} " <>
            "reason=#{inspect(reason)}) — registry row may be inconsistent"
        )

        :ok
    end
  end

  # --- read API (direct ETS) ----------------------------------------

  @doc """
  List `entity_uri`'s subscriptions. Returns
  `[{stream_uri_string, metadata_map}]`. No cap check on the read
  side — keyed by entity, so any process can introspect.
  """
  @spec list_subscriptions(URI.t() | String.t()) :: [{String.t(), map()}]
  def list_subscriptions(entity_uri) do
    entity_str = entity_to_string(entity_uri)

    @table
    |> :ets.match({{entity_str, :"$1"}, :"$2"})
    |> Enum.map(fn [stream, meta] -> {stream, meta} end)
  end

  @doc """
  List all subscribers of `stream_uri`. Used by the runtime hook
  to know who to notify (PR-N2 — currently informational only).
  """
  @spec list_subscribers(URI.t() | String.t()) :: [String.t()]
  def list_subscribers(stream_uri) do
    stream_str = stream_to_string(stream_uri)

    @table
    |> :ets.match({{:"$1", stream_str}, :_})
    |> Enum.map(fn [entity] -> entity end)
  end

  # --- GenServer callbacks ------------------------------------------

  @impl true
  def handle_call({:public_register, entity_uri, stream_uri, ctx}, _from, state) do
    stream_str = stream_to_string(stream_uri)
    stream_uri_parsed = parse_stream_uri(stream_uri)

    # Defence-in-depth — public path should never see `:system` ctx
    # (entry point already rejected it), but a misuse of internal
    # GenServer.call/cast would land here; force-deny.
    reply =
      case ctx do
        %{caps: :system} ->
          {:error, :system_caps_not_allowed_in_public_api}

        _ ->
          do_register(entity_uri, stream_str, stream_uri_parsed, ctx)
      end

    {:reply, reply, state}
  end

  def handle_call({:public_unregister, entity_uri, stream_uri, ctx}, _from, state) do
    entity_str = entity_to_string(entity_uri)
    stream_str = stream_to_string(stream_uri)

    reply =
      case ctx do
        %{caps: :system} ->
          {:error, :system_caps_not_allowed_in_public_api}

        _ ->
          do_unregister(entity_str, stream_str, ctx)
      end

    {:reply, reply, state}
  end

  # Codex round-7 MED — pure auth preflight used by `unsubscribe/3`
  # to refuse unauthorized callers BEFORE they reach the PubSub
  # side-effecting step. No mutation, no ETS read needed beyond
  # the auth predicates.
  def handle_call({:preflight_unsubscribe, entity_uri, ctx}, _from, state) do
    entity_str = entity_to_string(entity_uri)
    {:reply, authorize_unregister(entity_str, ctx), state}
  end

  # Codex round-4 CRITICAL fix — :system_register / :system_unregister
  # handlers DELETED. The forgery-rejection catch-all below ensures
  # any direct `GenServer.call(__MODULE__, {:system_register, ...})`
  # from a plugin or other module gets `{:error, :unknown_message}`
  # instead of crashing the GenServer (which would DOS-amplify a
  # hostile call).
  def handle_call(other, _from, state) do
    {:reply, {:error, {:unknown_message, normalize_unknown(other)}}, state}
  end

  # Return a stable tag for the rejected message so tests can
  # assert the rejection deterministically without leaking the
  # full payload.
  defp normalize_unknown({tag, _, _}) when is_atom(tag), do: tag
  defp normalize_unknown({tag, _, _, _}) when is_atom(tag), do: tag
  defp normalize_unknown(tag) when is_atom(tag), do: tag
  defp normalize_unknown(_), do: :unrecognised

  defp do_register(entity_uri, stream_str, stream_uri_parsed, ctx) do
    # Codex round-4 HIGH fix — symmetric authorisation with
    # unregister. Round-3 only checked stream cap; any caller with
    # a valid Notifications cap on stream X could insert a
    # subscription row keyed at any arbitrary `entity_uri`,
    # poisoning another user's registry. Now require the caller to
    # BE the entity OR hold a notifications-admin cap.
    with :ok <- authorize_register(URI.to_string(entity_uri), ctx),
         :ok <- check_subscribe_cap(stream_uri_parsed, ctx) do
      :ets.insert(@table, {
        {URI.to_string(entity_uri), stream_str},
        %{
          registered_at: DateTime.utc_now(),
          granted_by: Map.get(ctx, :caller, :unknown)
        }
      })

      :ok
    end
  end

  # Mirrors authorize_unregister — caller must be the entity OR an
  # explicit notifications-admin. No `:system` shortcut (system
  # path was deleted in round-4 CRITICAL).
  defp authorize_register(entity_str, %{caller: %URI{} = caller} = ctx) do
    cond do
      URI.to_string(caller) == entity_str -> :ok
      notifications_admin?(ctx) -> :ok
      true -> {:error, :unauthorized_for_entity}
    end
  end

  defp authorize_register(_, _), do: {:error, :unauthorized_for_entity}

  defp do_unregister(entity_str, stream_str, ctx) do
    case authorize_unregister(entity_str, ctx) do
      :ok ->
        :ets.delete(@table, {entity_str, stream_str})
        :ok

      {:error, _} = err ->
        err
    end
  end

  # --- internals ----------------------------------------------------

  defp entity_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp entity_to_string(s) when is_binary(s), do: s

  defp stream_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp stream_to_string(s) when is_binary(s), do: s

  defp parse_stream_uri(%URI{} = u), do: u
  defp parse_stream_uri(s) when is_binary(s), do: Ezagent.URI.new!(s)

  # Codex round-3 CRITICAL fix: REMOVED the `%{caps: :system} -> :ok`
  # clause entirely. System callers no longer go through this
  # predicate — they use the dedicated `:system_register` /
  # `:system_unregister` GenServer messages which skip the cap
  # check by message-tag, not by trusting caller-supplied ctx.
  # Public callers ALWAYS hit a real cap check now.

  defp check_subscribe_cap(
         %URI{} = stream_uri,
         %{authenticated_principal: %URI{} = holder, caps: caps}
       ) do
    needed = %{
      kind: :user,
      behavior: Ezagent.ActionSet.Notifications,
      # SPEC 2026-05-27 capability-action-axis — the action this site
      # gates is `:subscribe` (matches `Notifications.required_caps[:subscribe]`).
      action: :subscribe,
      instance: stream_uri,
      workspace_uri: Capability.workspace_of(stream_uri)
    }

    case Ezagent.Cap.authorize(holder, normalize_caps(caps), needed) do
      {:ok, %Capability{}} -> :ok
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp check_subscribe_cap(_, _), do: {:error, :missing_caps_in_ctx}

  # Codex round-3 CRITICAL fix: REMOVED the `%{caps: :system} -> :ok`
  # clause — same rationale as `check_subscribe_cap/2`. System
  # unregister goes through the `:system_unregister` GenServer
  # message which never reaches this predicate.

  defp authorize_unregister(entity_str, %{caller: %URI{} = caller} = ctx) do
    cond do
      URI.to_string(caller) == entity_str ->
        :ok

      notifications_admin?(ctx) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp authorize_unregister(_, _), do: {:error, :unauthorized}

  # Admin over subscriptions = the `:subscribe` action axis, cross-
  # workspace (`workspace_uri: :any`). SPEC 2026-05-27 capability-
  # action-axis §3.6.1: an admin predicate matches the action axis
  # EXPLICITLY (no missing-key tolerance), so a holder of a `:notify`
  # cap — the action plugins use to PUSH into an inbox — cannot
  # administer (register / unregister on behalf of others) another
  # user's subscriptions. Cross-action elevation was the bug: pre-fix
  # this matched ANY `Behavior.Notifications` cross-workspace cap,
  # so a `:notify`-scoped wildcard satisfied subscription-admin.
  defp notifications_admin?(%{caps: caps}) do
    caps
    |> normalize_caps()
    |> Enum.any?(fn
      %Ezagent.Capability{
        behavior: Ezagent.ActionSet.Notifications,
        action: :subscribe,
        workspace_uri: :any
      } ->
        true

      _ ->
        false
    end)
  end

  defp notifications_admin?(_), do: false

  defp normalize_caps(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp normalize_caps(caps) when is_list(caps), do: caps
  defp normalize_caps(_), do: []
end
