defmodule Ezagent.Kind do
  @moduledoc """
  Kind — contract for a Kind type module.

  Per DECISIONS P1-D2 / Decision #84: Phase 1 uses the
  `@behaviour Ezagent.Kind` + shared `Ezagent.Kind.Server` approach (path B
  in ARCHITECTURE.md §5.7.4), **not** a `use Ezagent.Kind` macro. The
  Kind module is a pure data declaration: which Behaviors it has,
  what its persistence policy is, etc. The `Ezagent.Kind.Server`
  GenServer instantiates one process per `{kind_module, args}` and
  delegates lifecycle (register → subscribe → announce_ready) so
  plugin authors cannot bypass it.

  ## Required callbacks

  - `type_name/0`: stable type atom (e.g. `:echo`, `:user`, `:agent`).
    Stored in snapshots — used to rehydrate, so renaming the module
    must not require a migration. Per Decision #62.
  - `behaviors/0`: list of `Ezagent.Behavior` modules this Kind composes.
  - `persistence/0`: snapshot strategy.

  ## Optional callbacks

  - `uri_from_args/1`: build the URI from instance args. Default
    implementation expects `args[:uri]` to be set by the caller.
  - `supervisor/0`: declare which `DynamicSupervisor` should host this
    Kind's processes. Defaults to `Ezagent.KindSupervisor` (a generic
    catch-all started by `EzagentCore.Application`). Per-Kind
    supervisors are encouraged when the Kind wants its own restart
    policy or domain-app ownership boundary.
  - `snapshot_version/0`: integer rev for snapshot schema migration.

  ## V1 structural prevention (Phase 9 follow-up, Allen 2026-05-21)

  All Kind processes must be spawned via `Ezagent.Kind.spawn/2` — the
  sole programmatic entry. Direct `DynamicSupervisor.start_child` for
  Kind modules is caught by the CI gate
  `Ezagent.Invariants.SingleSpawnEntryTest` plus the runtime invariant
  `Ezagent.Invariants.KindProvenanceTest`. Sidecars
  (`Ezagent.Domain.Pty.Server` and friends) are NOT Kinds and are
  exempt.
  """

  @type persistence_policy ::
          :ephemeral
          | {:snapshot, :on_change}
          | {:snapshot, :periodic, ms :: pos_integer()}
          | :on_terminate
          | :external

  @callback type_name() :: atom()
  @callback behaviors() :: [module()]
  @callback persistence() :: persistence_policy()
  @callback uri_from_args(args :: map()) :: URI.t()
  @callback snapshot_version() :: non_neg_integer()
  @callback supervisor() :: module()

  @optional_callbacks [uri_from_args: 1, snapshot_version: 0, supervisor: 0]

  @doc """
  The SOLE programmatic entry for spawning a Kind process.

  Determines the target `DynamicSupervisor` via `kind_module.supervisor/0`
  (each Kind declares its own; defaults to `Ezagent.KindSupervisor`
  when not defined). Calls `DynamicSupervisor.start_child/2` with the
  standard `Ezagent.Kind.Server` child spec wrapping
  `{kind_module, params}`.

  **Critical**: NO other lib code should call
  `DynamicSupervisor.start_child` for a Kind process. CI grep gate
  `Ezagent.Invariants.SingleSpawnEntryTest` enforces; runtime invariant
  `Ezagent.Invariants.KindProvenanceTest` enforces. Sidecars
  (PtyServer etc.) are NOT Kinds and live in their own exemption table.

  Returns the same as `DynamicSupervisor.start_child/2`:

      {:ok, pid()} | {:error, term()}

  Callers expecting idempotency typically match
  `{:error, {:already_started, pid}}` and treat it as success — the
  underlying `DynamicSupervisor` semantics are preserved.

  ## Examples

      Ezagent.Kind.spawn(Ezagent.Entity.User, %{
        uri: Ezagent.Entity.User.admin_uri(),
        initial_caps: Ezagent.Entity.User.admin_caps()
      })

      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri})
  """
  @spec spawn(module(), map()) :: DynamicSupervisor.on_start_child()
  def spawn(kind_module, params) when is_atom(kind_module) and is_map(params) do
    supervisor = resolve_supervisor(kind_module)
    DynamicSupervisor.start_child(supervisor, {Ezagent.Kind.Server, {kind_module, params}})
  end

  defp resolve_supervisor(kind_module) do
    if function_exported?(kind_module, :supervisor, 0) do
      kind_module.supervisor()
    else
      Ezagent.KindSupervisor
    end
  end
end
