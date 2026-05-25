defmodule Ezagent.Behavior.ExternalMirrorWorker do
  @moduledoc """
  `Ezagent.Behavior.ExternalMirrorWorker` — the per-binding Worker
  Behavior on `Ezagent.Entity.ExternalMirrorWorker`.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §4.3 / §6.1 / §8.3.

  Owns:
  - the `:external_mirror_worker` slice
  - the `:publish` action (the only action this Behavior implements)
  - the post-init split-init pattern (PR-EM-CORE hook): `post_init/2`
    returns `{:continue, :subscribe_and_init}`; `handle_continue/3`
    runs AFTER `:announce_ready` and (a) subscribes to the Session
    Publisher (b) calls `binding.init/1`
  - the `{:publisher_event, %Event{}}` mailbox hook
    (`handle_kind_message/3`) which self-dispatches `:publish`

  ## Slice shape (`:external_mirror_worker`)

      %{
        # static — set at spawn time
        session_uri:        %URI{},
        adapter_id:         String.t(),
        target_id:          term(),
        opts:               map(),

        # late-bound — set in handle_continue/3 after init succeeds
        adapter_module:     module() | nil,
        binding_module:     module() | nil,
        binding_state:      term() | nil,
        subscription_state: :pending | :active,
        publisher_cursor:   non_neg_integer() | :latest,

        # accumulated over publishes
        count:              non_neg_integer(),
        error_count:        non_neg_integer(),
        last_published_at:  DateTime.t() | nil,
        last_publish_result: :ok | :skip | {:error, term()} | nil
      }

  ## :publish action

  Self-dispatched (`:cast`) from `handle_kind_message/3` on receipt
  of a `{:publisher_event, %Event{}}` message — routing the publish
  through `Kind.Runtime.handle_dispatch/4` so step 5.5 CapBAC +
  audit + telemetry + idempotency apply (P14 hygiene).

  Body:
    1. `payload = adapter_module.event_to_payload(event)`
    2. if `:skip` → update cursor + count, no transport call
    3. if `{:publish, payload}` → `binding_module.publish(payload, binding_state)`
    4. on `{:ok, new_binding_state}` → update slice cursor / count / timestamps
    5. on `{:error, reason, new_binding_state}` → recoverable; log +
       update error_count; carry new_binding_state forward
    6. on RAISE inside `event_to_payload` or `publish` → let it
       crash; PerBindingSupervisor restarts per `:permanent` budget

  ## Failure semantics (per `feedback_let_it_crash_no_workarounds`)

  NO `:warning`+degrade paths. Recoverable failures
  (`{:error, _, _}` from `publish/2`) update slice telemetry
  fields and return successfully — the next slice change
  dispatches a fresh `:publish` and the binding may recover.
  UNrecoverable failures (RAISE inside adapter or binding) let
  the Worker crash; the PerBindingSupervisor's 3/30s budget
  absorbs short bursts; a sustained crash loop trips the
  PerBindingSupervisor itself and leaves it down — operator sees
  telemetry, unbinds.

  ## data_owner/1

  `:no_owner` — Worker Kinds are framework-internal (SPEC §4.3 /
  §7.3 Cap 3). Users never hold caps on Worker instances directly;
  the Session Kind holds a scope-bounded
  `{:within_session, session_uri}` delegation cap that PR-EM-3 will
  wire when `:bind` spawns the worker. PR-EM-2 leaves the cap
  table populated with the `:publish` subject (registered in
  `EzagentDomainExternalMirror.Application`) but does not yet
  enforce the per-session delegation — that's PR-EM-3's scope.
  """

  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}
  alias Ezagent.Publisher.Event

  # ----- Ezagent.Behavior contract ----------------------------------------

  @impl Ezagent.Behavior
  def actions, do: [:publish]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # ExternalMirrorWorker is registered on the ExternalMirrorWorker Kind
  # only — kind axis is `:external_mirror_worker`.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      publish: Ezagent.Capability.cap(:external_mirror_worker, __MODULE__, :publish)
    }
  end

  @impl Ezagent.Behavior
  def state_slice, do: :external_mirror_worker

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:publish,
       "publish a Publisher event to an external system via the bound adapter+binding pair"}
    ]
  end

  @impl Ezagent.Behavior
  def init_slice(args) do
    # SPEC §8.3 r4 HIGH-1 fix: minimal slice. NO Publisher.subscribe_from
    # here (would deadlock — see Behavior.post_init/2 + handle_continue/3
    # below). NO binding.init/1 either (transport open is the binding
    # module's job, deferred to handle_continue/3).
    %{
      session_uri: Map.fetch!(args, :session_uri),
      adapter_id: Map.fetch!(args, :adapter_id),
      target_id: Map.fetch!(args, :target_id),
      opts: Map.get(args, :opts, %{}),
      adapter_module: nil,
      binding_module: nil,
      binding_state: nil,
      subscription_state: :pending,
      publisher_cursor: :latest,
      count: 0,
      error_count: 0,
      last_published_at: nil,
      last_publish_result: nil
    }
  end

  @doc """
  Defer Publisher subscription + binding transport-open until AFTER
  `:announce_ready`. The PR-EM-CORE post-init hook handles the
  chaining; see SPEC §6.1 + §8.3 for the deadlock rationale.

  Returning `{:continue, :subscribe_and_init}` populates
  `Kind.Server`'s `post_init_queue`; the queue drains via
  `handle_continue/3` below.
  """
  @impl Ezagent.Behavior
  def post_init(_args, _slice), do: {:continue, :subscribe_and_init}

  @doc """
  Subscribe to the Session Publisher + open the binding's transport.
  Runs after `:announce_ready` (PR-EM-CORE invariant — see
  `Ezagent.Kind.Server` moduledoc).

  Both calls go through the lookup-then-act pattern:
  1. Resolve `adapter_module` + `binding_module` from registries
     (raises on missing — structural error per SPEC §5.2).
  2. Subscribe `self()` to the Session Publisher at cursor `:latest`
     (no replay — V1 fire-and-forget per OQ-EM-10).
  3. Call `binding_module.init({target_id, adapter_module, opts})`
     to open the transport.
  4. On success → flip `subscription_state` to `:active` + store
     `binding_state` + the resolved modules in the slice.
  5. On binding init failure → raise (let-it-crash; PerBindingSupervisor
     restarts per `:permanent` budget per SPEC §6.2).
  """
  @impl Ezagent.Behavior
  def handle_continue(:subscribe_and_init, slice, %{self_uri: self_uri}) do
    adapter_module = AdapterRegistry.lookup!(slice.adapter_id)
    binding_module = BindingRegistry.lookup!(slice.adapter_id)

    # SPEC §6.1: subscribe via the Publisher API (NOT
    # Phoenix.PubSub.subscribe — invariant 4 enforced by PR-EM-FINAL
    # grep gate). For PR-EM-2 we use the 4-ary form on
    # `Ezagent.Entity.Session.subscribe_from/4` with the Worker's
    # OWN URI as caller + a synthetic delegation cap so step 5.5
    # admits the subscribe. PR-EM-3 will replace the synthetic cap
    # with the formal scope-bounded `{:within_session, session_uri}`
    # delegation per SPEC §7.3 Cap 3.
    {:ok, current_cursor} = subscribe_to_session_publisher(slice.session_uri, self_uri)

    case binding_module.init({slice.target_id, adapter_module, slice.opts}) do
      {:ok, binding_state} ->
        new_slice = %{
          slice
          | adapter_module: adapter_module,
            binding_module: binding_module,
            binding_state: binding_state,
            subscription_state: :active,
            publisher_cursor: current_cursor
        }

        {:ok, new_slice}

      {:error, reason} ->
        # SPEC §6.2: binding's transport failed to open; raise to
        # crash the worker — PerBindingSupervisor restarts per
        # `:permanent` + 3/30s budget. If init keeps failing the
        # PerBindingSupervisor itself crashes and stays down
        # (operator sees telemetry; unbinds to recover).
        raise "ExternalMirrorWorker binding init failed: #{inspect(reason)}"
    end
  end

  @doc """
  Hook into the Kind.Server mailbox for `{:publisher_event, event}`
  messages from the Session Publisher (we subscribed in
  `handle_continue/3`).

  Self-dispatch the `:publish` action via
  `Ezagent.Invocation.dispatch/1` (`:cast`) — routes the publish
  through `Kind.Runtime.handle_dispatch/4` so step 5.5 CapBAC +
  audit + telemetry + idempotency apply (P14 hygiene). Self-dispatch
  is the idiomatic Kind pattern when an external event needs to
  enter the dispatch flow.

  Slice unchanged — return `:ignore` so `Kind.Server` skips the
  snapshot commit path. The slice mutation happens in `invoke/4`
  which runs from the dispatched action via the standard pipeline.
  """
  def handle_kind_message({:publisher_event, %Event{} = event}, slice, %{self_uri: self_uri}) do
    if slice.subscription_state == :active do
      dispatch_publish_to_self(self_uri, event)
    else
      # Defensive: events shouldn't arrive while subscription_state
      # is :pending (we're not subscribed yet). Log + drop per
      # latest-wins (SPEC §3).
      Logger.warning(
        "ExternalMirrorWorker received publisher_event while subscription_state=:pending; " <>
          "dropping (latest-wins per SPEC §3). uri=#{URI.to_string(self_uri)}"
      )
    end

    :ignore
  end

  def handle_kind_message(_other, _slice, _ctx), do: :ignore

  @doc """
  PR-EM-2 codex round-1 HIGH-1 fix (2026-05-25): graceful shutdown
  hook — invoked by `Ezagent.Kind.Server.terminate/2` on Kind
  exit. Calls `binding_module.terminate(reason, binding_state)`
  per SPEC §6.2 ("`terminate/2` runs on graceful unbind ... the
  Worker Kind's `terminate/2` callback calls the binding module's
  `terminate/2` to release transport resources").

  Defensive: if the Binding's terminate is not exported (optional
  per SPEC §2.3), skip. If the slice was never advanced past
  `:pending` (e.g. terminate during handle_continue), there's no
  binding_state to clean up — skip.
  """
  def terminate(reason, slice, _ctx) do
    cond do
      slice.subscription_state != :active ->
        # Binding never finished init (still :pending) — no
        # transport handle to release.
        :ok

      not is_atom(slice.binding_module) ->
        :ok

      not function_exported?(slice.binding_module, :terminate, 2) ->
        # Binding.terminate/2 is optional per SPEC §2.3.
        :ok

      true ->
        try do
          _ = slice.binding_module.terminate(reason, slice.binding_state)
          :ok
        rescue
          err ->
            Logger.warning(
              "ExternalMirrorWorker: binding #{inspect(slice.binding_module)}.terminate/2 " <>
                "raised on shutdown (#{inspect(err)}); transport resources may leak. " <>
                "binding_id=#{slice.adapter_id}/#{inspect(slice.target_id)}"
            )

            :ok
        end
    end
  end

  # ----- The :publish action ------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:publish, slice, %{event: %Event{} = event}, _ctx) do
    case slice.adapter_module.event_to_payload(event) do
      :skip ->
        new_slice = %{
          slice
          | publisher_cursor: event.cursor,
            count: slice.count + 1,
            last_publish_result: :skip,
            last_published_at: DateTime.utc_now()
        }

        {:ok, new_slice, %{ok: true, cursor: event.cursor, skipped: true}}

      {:publish, payload} ->
        case slice.binding_module.publish(payload, slice.binding_state) do
          {:ok, new_binding_state} ->
            new_slice = %{
              slice
              | binding_state: new_binding_state,
                publisher_cursor: event.cursor,
                count: slice.count + 1,
                last_publish_result: :ok,
                last_published_at: DateTime.utc_now()
            }

            {:ok, new_slice, %{ok: true, cursor: event.cursor}}

          {:error, reason, new_binding_state} ->
            # Recoverable: log + bump error_count; do NOT crash.
            # The next slice change dispatches a fresh :publish and
            # the binding may recover.
            Logger.warning(
              "ExternalMirror publish failed (recoverable): " <>
                "adapter_id=#{inspect(slice.adapter_id)} " <>
                "target_id=#{inspect(slice.target_id)} " <>
                "reason=#{inspect(reason)}"
            )

            new_slice = %{
              slice
              | binding_state: new_binding_state,
                publisher_cursor: event.cursor,
                count: slice.count + 1,
                error_count: slice.error_count + 1,
                last_publish_result: {:error, reason},
                last_published_at: DateTime.utc_now()
            }

            {:ok, new_slice, %{ok: false, cursor: event.cursor, reason: reason}}
        end
    end
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      publish: %{
        description:
          "Translate a Publisher event via the bound adapter, then transport via the bound binding",
        args: %{},
        returns: %{ok: :boolean, cursor: :integer},
        modes: [:cast]
      }
    }
  end

  @doc """
  SPEC §4.3: Worker Kinds are framework-internal; only bootstrap
  admin can grant caps. Users never hold caps on `entity://worker/...`
  URIs directly — the Session Kind holds a scope-bounded delegation
  cap (PR-EM-3 will wire this) per SPEC §7.3 Cap 3.
  """
  @impl Ezagent.Behavior
  def data_owner(%URI{scheme: "entity", host: "worker"} = _worker_uri), do: :no_owner
  def data_owner(:any), do: :no_owner
  def data_owner({:scope, :within_session, %URI{}}), do: :no_owner
  def data_owner(_), do: :no_owner

  # ----- internals ----------------------------------------------------------

  # PR-EM-2 wiring of Publisher.subscribe_from. Uses an inline
  # admin-elevated ctx for the subscribe so step 5.5 admits the
  # call — PR-EM-3 replaces this with the formal scope-bounded
  # cap (`{:within_session, session_uri}` per SPEC §7.3 Cap 3)
  # delegated to the Session Kind at bind time.
  #
  # codex round-1 STRUCTURAL fix (2026-05-25): the PR-EM-2 deferral
  # to PR-EM-3 covers BOTH internal dispatch sites — `subscribe_to_
  # session_publisher/2` AND `dispatch_publish_to_self/2` (the
  # `:publish` self-cast on `{:publisher_event, _}` mailbox
  # message). Both currently use the inline admin caps; PR-EM-3
  # will:
  #
  #   - subscribe path: switch to the scope-bounded
  #     `{:within_session, session_uri}` Cap 3 delegated at bind time
  #   - publish path: switch to the Worker's own default-granted
  #     publish cap (auto-granted on spawn per SPEC §7.3 Cap 3 +
  #     caps-data-ownership §4.1)
  #
  # The Worker NEVER accepts admin caps from external callers;
  # admin caps appear ONLY in these two internal self-dispatches
  # for the structural reason that ezagent's dispatch pipeline
  # has no ambient-caps mechanism (every Invocation.dispatch/1
  # requires explicit ctx.caps per CapBAC step 5.5).
  #
  # We don't call `Ezagent.Entity.Session.subscribe_from/4`
  # directly: `:ezagent_domain_chat` depends on
  # `:ezagent_domain_external_mirror` (for the Publisher contract),
  # so a reverse reference here would form a Mix dep cycle.
  # The dispatch goes through `?action=publisher.subscribe_from`
  # — identical wire-shape to what `Session.subscribe_from/4`
  # constructs (SPEC §8.1).
  defp subscribe_to_session_publisher(%URI{} = session_uri, %URI{} = self_uri) do
    target = URI.parse("#{URI.to_string(session_uri)}?action=publisher.subscribe_from")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{subscriber_pid: self(), cursor: :latest},
      # SPEC caps-cleanup-v1 §4.4 — Worker's internal dispatches run
      # under `system://worker-publish` per the closed Catalog.
      ctx: %{
        caller: self_uri,
        caps: Ezagent.SystemPrincipal.caps("system://worker-publish"),
        reply: :ignore
      }
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, %{cursor: cursor}} -> {:ok, cursor}
      {:error, _} = err -> err
      :ok -> {:ok, :latest}
    end
  end

  defp dispatch_publish_to_self(%URI{} = self_uri, %Event{} = event) do
    target = URI.parse("#{URI.to_string(self_uri)}?action=external_mirror_worker.publish")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{event: event},
      # SPEC caps-cleanup-v1 §4.4 — Worker outbound publish runs
      # under `system://worker-publish` (closed Catalog).
      ctx: %{
        caller: self_uri,
        caps: Ezagent.SystemPrincipal.caps("system://worker-publish"),
        reply: :ignore,
        idempotency_key: "external_mirror_worker.publish/#{event.cursor}"
      }
    })
  end
end
