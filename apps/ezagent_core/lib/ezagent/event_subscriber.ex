defmodule Ezagent.EventSubscriber do
  @moduledoc """
  `Ezagent.EventSubscriber` — declarative event-driven cross-Kind
  reactions (SPEC §5.5).

  See `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
  §5.5. Phase 1B (this module) provides the `use Ezagent.EventSubscriber`
  macro, the `@behaviour` callback contract, and a `Registry`-backed
  catalogue of subscriber declarations the framework will consume at
  boot. Actual event-fan-out plumbing (EventLog → PubSub → handle_event)
  lands in Phase 2.

  ## Declaration shape

      defmodule Ezagent.Plugin.ExternalMirror.WorkerBootstrapSubscriber do
        use Ezagent.EventSubscriber

        subscribe to: :all,
                  only: [:binding_created, :binding_destroyed]

        @impl true
        def interested?(%{event_name: "binding_created"} = _event), do: true
        def interested?(_), do: false

        @impl true
        def handle_event(event, state) do
          {:dispatch, [%Ezagent.Cmd{...}], state}
        end
      end

  `subscribe/1` is the declarative declaration; `interested?/1` is the
  per-event filter (cheap, runs on every event in the subscribed scope);
  `handle_event/2` is the action (returns effects from the same
  EFFECT vocabulary as `Ezagent.Behavior`, so the framework applies
  them through the Router pipeline — no direct PubSub / dispatch calls
  from inside the subscriber).

  ## Subscription scopes

  | `to:` | Semantics |
  |-------|-----------|
  | `:all`              | Every event written to `Ezagent.EventLog` |
  | `{:aggregate, uri}` | Events whose `aggregate_uri` matches `uri` |
  | `{:workspace, uri}` | Events whose `workspace_uri` matches `uri` |

  `only: [event_names]` is a coarse pre-filter applied before
  `interested?/1` — used to avoid waking the subscriber for events it
  could never care about. Equivalent to `interested?/1` returning
  `false` for the un-named event, but evaluated once at declaration
  time rather than per-event.

  ## Framework-internal — NO plugin contact in Phase 1 (SPEC §11)

  Phase 1 explicitly forbids plugin code from `use Ezagent.EventSubscriber`.
  The first plugin consumer arrives in Phase 2 (`Ezagent.Plugin.ExternalMirror.
  WorkerBootstrapSubscriber` per SPEC §5.5 example). Phase 1 builds the
  framework primitive in isolation; the SPEC §11 grep gate verifies no
  `ezagent_plugin_*` app references this module.

  ## Phase 2 extension — partition mode (codex r2 closure)

  @todo Phase 2: `partition_mode/0` callback — lets a subscriber declare
  whether handler invocations across distinct events SHOULD or MUST be
  serialised on a partition key. Default `:none` (concurrent dispatch
  per event); `{:partition_by, &fn/1}` serialises on the function's
  return value (e.g. `&Map.get(&1, :aggregate_uri)` to enforce
  per-aggregate ordering — matches today's `BootReconciler` invariant
  that workspace events for the same workspace are handled in EventLog
  order). Phase 1 leaves the placeholder so Phase 2 can add it without
  re-shaping the boot-time registration call.

  ## Catalogue

  At app boot, `Ezagent.EventSubscriber.register/1` records the
  module + its declared `__ezagent_event_subscription__/0` value in a
  `Registry` (`Ezagent.EventSubscriber.Registry`). The Phase 2
  dispatcher reads the catalogue to know whom to call. Phase 1 builds
  the catalogue but no producer fires events yet — the registry is
  observable in isolation.
  """

  @typedoc "An event row as exposed by `Ezagent.EventLog`."
  @type event :: %{
          required(:event_id) => pos_integer(),
          required(:aggregate_uri) => String.t(),
          required(:event_name) => String.t(),
          required(:payload) => map() | nil,
          required(:caller) => String.t() | nil,
          required(:workspace_uri) => String.t(),
          required(:trace_id) => String.t() | nil,
          required(:inserted_at) => DateTime.t()
        }

  @typedoc "Subscription declaration captured by the `subscribe/1` macro."
  @type subscription :: %{
          required(:to) =>
            :all | {:aggregate, URI.t() | String.t()} | {:workspace, URI.t() | String.t()},
          required(:only) => :any | [event_name :: atom() | String.t()]
        }

  @typedoc "Return shape from `handle_event/2`. Phase 2 expands to the full effect vocabulary."
  @type handle_result :: {effects :: [term()], state :: term()} | :ok | {:ok, state :: term()}

  @doc """
  Per-event filter — runs after the static `only:` allowlist passes.

  Returning `false` short-circuits dispatch for this event without
  calling `handle_event/2`. The contract is intentionally pure: no
  side effects allowed; the framework MAY call `interested?/1` for
  the same event multiple times across a node (e.g. on replay).
  """
  @callback interested?(event()) :: boolean()

  @doc """
  Handle one event. State is whatever the subscriber returned from
  its prior call (Phase 1: framework passes `nil` as initial state;
  Phase 2 introduces explicit `init/0`).

  Effects use the same vocabulary as `Ezagent.Behavior` (`{:dispatch,
  ...}`, `{:emit, ...}`, `{:notify, ...}`, etc.); the framework
  applies them through the Router pipeline. Phase 1 documents the
  callback shape; Phase 2 wires the dispatch path.
  """
  @callback handle_event(event(), state :: term()) :: handle_result()

  # ---------------------------------------------------------------------
  # `use Ezagent.EventSubscriber`
  # ---------------------------------------------------------------------

  defmacro __using__(_opts) do
    quote do
      @behaviour Ezagent.EventSubscriber

      import Ezagent.EventSubscriber, only: [subscribe: 1]

      Module.register_attribute(__MODULE__, :ezagent_event_subscription, accumulate: false)
    end
  end

  @doc """
  Declarative subscription macro.

  ## Options

  - `:to` (required) — `:all | {:aggregate, uri} | {:workspace, uri}`
  - `:only` (optional, default `:any`) — list of event_names this
    subscriber wants. `:any` means no static pre-filter (all events
    in scope reach `interested?/1`).

  Stored on the module as `@ezagent_event_subscription` and exposed
  via the auto-generated `__ezagent_event_subscription__/0` function.
  """
  defmacro subscribe(opts) do
    quote bind_quoted: [opts: opts] do
      Ezagent.EventSubscriber.__validate_subscribe__!(opts)

      to_scope = Keyword.fetch!(opts, :to)
      only = Keyword.get(opts, :only, :any)

      @ezagent_event_subscription %{to: to_scope, only: only}

      @doc false
      @spec __ezagent_event_subscription__() :: Ezagent.EventSubscriber.subscription()
      def __ezagent_event_subscription__, do: @ezagent_event_subscription
    end
  end

  @doc false
  def __validate_subscribe__!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError,
            "Ezagent.EventSubscriber.subscribe/1: expected keyword opts, " <>
              "got #{inspect(opts)}"
    end

    case Keyword.fetch(opts, :to) do
      {:ok, :all} ->
        :ok

      {:ok, {:aggregate, _uri}} ->
        :ok

      {:ok, {:workspace, _uri}} ->
        :ok

      {:ok, other} ->
        raise ArgumentError,
              "Ezagent.EventSubscriber.subscribe/1 — :to must be :all, " <>
                "{:aggregate, uri}, or {:workspace, uri}; got #{inspect(other)}"

      :error ->
        raise ArgumentError,
              "Ezagent.EventSubscriber.subscribe/1 — :to is required " <>
                "(:all | {:aggregate, uri} | {:workspace, uri})"
    end

    case Keyword.get(opts, :only, :any) do
      :any ->
        :ok

      list when is_list(list) ->
        Enum.each(list, fn
          a when is_atom(a) ->
            :ok

          s when is_binary(s) ->
            :ok

          other ->
            raise ArgumentError,
                  "Ezagent.EventSubscriber.subscribe/1 — :only entries must " <>
                    "be atoms or strings; got #{inspect(other)}"
        end)

      other ->
        raise ArgumentError,
              "Ezagent.EventSubscriber.subscribe/1 — :only must be :any " <>
                "or a list of event names; got #{inspect(other)}"
    end
  end

  # ---------------------------------------------------------------------
  # Catalogue (framework-owned)
  # ---------------------------------------------------------------------

  @doc """
  Register a subscriber module. Idempotent.

  Reads `__ezagent_event_subscription__/0` and records the
  `{module, subscription}` pair in the in-memory catalogue. The Phase
  2 dispatcher iterates the catalogue per event.

  Raises `ArgumentError` if `module` does not implement the behaviour
  or never called `subscribe/1`.
  """
  @spec register(module()) :: :ok
  def register(module) when is_atom(module) do
    unless function_exported?(module, :__ezagent_event_subscription__, 0) do
      raise ArgumentError,
            "Ezagent.EventSubscriber.register/1: #{inspect(module)} did not " <>
              "call `subscribe/1` inside its `use Ezagent.EventSubscriber` block. " <>
              "Add a `subscribe to: ..., only: [...]` declaration."
    end

    subscription = module.__ezagent_event_subscription__()
    :ok = ensure_catalogue!()
    :ets.insert(catalogue_table(), {module, subscription})
    :ok
  end

  @doc "Return all currently-registered `{module, subscription}` pairs."
  @spec list() :: [{module(), subscription()}]
  def list do
    :ok = ensure_catalogue!()
    :ets.tab2list(catalogue_table())
  end

  @doc "Return the subscription for a single registered module, or `:error`."
  @spec lookup(module()) :: {:ok, subscription()} | :error
  def lookup(module) when is_atom(module) do
    :ok = ensure_catalogue!()

    case :ets.lookup(catalogue_table(), module) do
      [{^module, subscription}] -> {:ok, subscription}
      [] -> :error
    end
  end

  @doc "Clear the catalogue. Test-only helper."
  @spec __reset__() :: :ok
  def __reset__ do
    :ok = ensure_catalogue!()
    :ets.delete_all_objects(catalogue_table())
    :ok
  end

  @doc false
  def catalogue_table, do: :ezagent_event_subscriber_catalogue

  # The catalogue is a lightweight ETS table — not a Registry (we don't
  # need pid tracking, and the catalogue outlives any particular
  # subscriber process). Created lazily on first access so Phase 1
  # doesn't depend on EtsOwner sequencing; Phase 2 will move the
  # table ownership into `EzagentCore.EtsOwner` alongside the other
  # registries (`Ezagent.PluginRegistry` shape).
  defp ensure_catalogue! do
    case :ets.whereis(catalogue_table()) do
      :undefined ->
        try do
          :ets.new(catalogue_table(), [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          # Two concurrent callers raced on :ets.new — whichever lost
          # the race observes ArgumentError because the table now
          # exists. That's fine; either way the table is up.
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end
end
