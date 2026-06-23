defmodule Ezagent.Resource.FsResolver.Registry do
  @moduledoc """
  Sole writer of the `Ezagent.Resource.FsResolver` `<type>` allowlist
  (Resource-unification SPEC §5.1, codex round-1..4 HIGH/CRITICAL; plugin-owned
  resource types SPEC `docs/superpowers/specs/2026-06-24-plugin-resource-type-registration-design.md`).

  The allowlist lives in a `:protected` ETS table:

    * **reads** (`Ezagent.Resource.FsResolver.resolve/2` `:ets.lookup`) go direct
      from any process — `:protected` allows cross-process reads.
    * **writes** happen ONLY inside this GenServer — at `init/1` (core
      `boot_registrations/0`) and via the `register_all/1` GenServer call (plugin
      `resource_types/0`, published at plugin Phase-2 boot). Post-init writes are
      **append-only, write-once on BOTH `<type>` and `backend_component`,
      owner-serialized, all-or-nothing per batch; no overwrite, no delete, no
      reopen flag.**

  ## Write-once on both `<type>` AND `backend_component` (codex HIGH-1)

  Approach A (plugin-resource SPEC §3) keeps every structural defense and removes
  only the old "no post-init write message" restriction — by adding a
  `register_all/1` call that runs the SAME `validate_spec/2` + `:ets.insert_new/2`
  the boot loop uses, PLUS a `backend_component`-uniqueness precheck:

    * **Owner-only** — the table is `:protected`; non-owner `:ets.insert/2` raises
      `ArgumentError`. `register_all/1` runs inside this GenServer, the sole writer.
    * **Write-once on `<type>`** — `:ets.insert_new/2` makes a second registration
      of an existing `<type>` fail; precheck returns `{:error, {:duplicate_type, t}}`.
    * **Write-once on `backend_component` (codex HIGH-1)** — precheck ALSO rejects
      a spec whose `backend_component` is already claimed by any registered type:
      `{:error, {:duplicate_backend, b}}`. Without this, write-once on the key
      alone is insufficient — a plugin could register a FRESH `<type>` whose
      `backend_component` is `"uploads"` with a WEAKER `authority/2` and reach the
      same bytes through the new type (a cross-type authority bypass that never
      touches the protected `"uploads"` key). Backend-uniqueness makes
      (type ↔ backend) a bijection: the authority fn guarding a backend's bytes is
      fixed by whoever registered that backend FIRST.
    * **All-or-nothing per batch (codex HIGH-5)** — `register_all/1` prechecks
      EVERY decl (validate + type-uniqueness + backend-uniqueness, against both the
      live table AND the other decls in the same batch) BEFORE inserting any; on
      any failure it inserts NOTHING and returns `{:error, reason}`.
    * **No overwrite, no delete, no reopen flag** — there is no update or delete
      path in any env except the existing `:test`-only `unregister_for_test`.
      Nothing mutable gates the decision; the table simply never accepts a second
      write to a key.

  ## Ordering — core registers first (plugin-resource SPEC §5)

  `init/1` applies core `boot_registrations/0` (`cc-agents`, `codex-agents`,
  `uploads`) when `ezagent_core` starts, BEFORE any plugin boots (plugins depend
  on core → start later). So core backends are claimed first and a plugin can
  neither shadow a core `<type>` (write-once) nor alias a core backend
  (backend-uniqueness). Core `boot_registrations/0` flows through the SAME
  precheck as plugin `register_all/1`, so the write-once-on-both property holds
  uniformly.

  ## Restart resilience (codex HIGH-2 — matched to the sibling registries)

  Plugin types live in this Registry's ETS, appended at plugin boot. If this
  GenServer alone crashes and restarts under `:one_for_one`, `init/1` re-applies
  ONLY core `boot_registrations/0` — plugin types are NOT replayed (the plugins
  stay up).

  **Finding (audit of the sibling plugin-fed registries):** `BehaviorRegistry`,
  `TemplateRegistry`, and `AgentFlavorRegistry` do NOT self-own their tables —
  their `:set`/`:public` tables are created by `EzagentCore.EtsOwner`, a single
  GenServer holding every reliability-primitive table. On an isolated `EtsOwner`
  restart, ALL of those tables come back EMPTY (core + plugin alike) with no
  replay; they purely rely on being a start-critical singleton (`:permanent`
  child under `:one_for_one`), so a crash-loop escalates and fails the node loud
  rather than serving a half-populated registry. A `:public` table is unusable
  for THIS Registry, though: it would let any process `:ets.insert/2` a forged
  type spec and defeat the owner-only authority contract. The in-repo precedent
  for a security-gated registry that therefore canNOT live in `EtsOwner` is
  `Ezagent.NotificationSubscriptions` — a self-owned `:protected` GenServer.

  **Posture chosen (matched, not invented):** this Registry keeps its self-owned
  `:protected` table (the authority contract requires it) and adopts the siblings'
  start-critical-singleton restart treatment: on restart `init/1` re-applies
  `boot_registrations/0` so CORE types self-heal; plugin types are not replayed
  (identical to the EtsOwner siblings, whose tables come back empty). The Registry
  is a `:permanent` child (`use GenServer` default) under `:one_for_one`, so a
  crash-loop escalates and fails the node loud rather than serving a half
  allowlist. Plugin types require the owning plugin to re-`boot` (re-publish
  Phase-2) to reappear — there is deliberately NO re-publish hook / escalation
  machinery (that would be the novel scheme the design forbids).

  The "never silently missing" guarantee has two arms, both regression-tested:
  (1) **self-heal** — after a supervised restart a core boot type resolves again;
  (2) **loud-when-absent** — while the ETS table is GONE (table dies with its
  owner), `FsResolver.resolve/2`'s `lookup/2` rescue RAISES rather than treating
  every type as unregistered. One honest caveat: the rescue covers the
  table-ABSENT case; in the sub-millisecond restart window where the named table
  has been created by `init/1` but `boot_registrations/0` has not yet been applied,
  `resolve/2` can return a transient (retryable) `:none`. That is an availability
  blip during crash-recovery, NOT an authority bypass (a `:none` denies access,
  never swaps authority or reaches another type's bytes) — and it is strictly
  narrower than the EtsOwner siblings' window (their tables come back fully empty
  and stay empty until the contributing plugins re-boot). Closing it would require
  a pre-populated-table heir/give_away transfer or a readiness flag — the "novel
  scheme" / reopen-flag the design forbids — so it is accepted by construction.

  ## Test-only registration

  In `:test`, `register_for_test/2` / `unregister_for_test/1` mailbox messages
  exist (compiled out of `:prod`) so each test can register/clean up its own
  test-only types against the same `:protected` table. `register_for_test/2`
  retains its type-only precheck (validate + `:ets.insert_new`); the
  backend-uniqueness axis is exercised through the production `register_all/1`
  path (existing tests reuse a shared test backend across serialized cases).

  Starts in the `ezagent_core` supervision tree (child ①·5) before any consumer.
  """
  use GenServer

  alias Ezagent.Resource.FsResolver

  @table :ezagent_resource_fs_types

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # :protected — readable by anyone (resolve/2 reads), writable ONLY here.
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    # Apply the boot-defined core allowlist once, through the SAME precheck the
    # plugin `register_all/1` path uses (validate + type-uniqueness +
    # backend-uniqueness, all-or-nothing) — so the write-once-on-both property
    # holds uniformly for core and plugin types. Core types register FIRST (here,
    # before any plugin boots), claiming their backends; a plugin can therefore
    # never shadow a core type nor alias a core backend (codex HIGH-1). A restart
    # re-applies exactly this same source (round-4: no externally-mutable reopen);
    # plugin types are not replayed (restart-resilience finding in the moduledoc).
    case batch_register(boot_registrations()) do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        raise ArgumentError, "invalid core boot registration: #{inspect(reason)}"
    end
  end

  @doc """
  Batch-register plugin-contributed `{type, spec}` decls (plugin-resource SPEC
  §4.3). Owner-serialized, write-once on BOTH `<type>` and `backend_component`,
  all-or-nothing: EVERY decl is prechecked (validate + type-uniqueness +
  backend-uniqueness, against the live table AND the other decls in this batch)
  BEFORE any insert; on any failure nothing is inserted and `{:error, reason}` is
  returned. Called by `Ezagent.Plugin.boot/1` Phase 2 with `plugin.resource_types/0`.
  """
  @spec register_all([{String.t(), FsResolver.type_spec()}]) :: :ok | {:error, term()}
  def register_all(decls) when is_list(decls),
    do: GenServer.call(__MODULE__, {:register_all, decls})

  # Shared precheck-then-insert used by BOTH `init/1` (core boot types) and the
  # `register_all/1` GenServer call (plugin types). Runs entirely in the owner
  # process — `init/1` calls it directly (cannot `GenServer.call/2` itself), the
  # handle_call delegates here too, so there is ONE write path with one set of
  # invariants. Prechecks the WHOLE batch against the live table AND the other
  # decls in the batch (intra-batch uniqueness — `:ets.insert_new/2` only keys on
  # `<type>`, so two decls sharing a backend would both insert without this),
  # then inserts all-or-nothing.
  @spec batch_register([{String.t(), map()}]) :: :ok | {:error, term()}
  defp batch_register(decls) do
    with :ok <- precheck_batch(decls) do
      Enum.each(decls, fn {type, spec} -> true = :ets.insert_new(@table, {type, spec}) end)
      :ok
    end
  end

  # Reduce over the batch carrying the set of types + backends already SEEN in
  # this batch, so a duplicate within the batch is caught (not only a duplicate
  # against the live table). Halts on the first failure → nothing is inserted.
  defp precheck_batch(decls) do
    decls
    |> Enum.reduce_while({:ok, MapSet.new(), MapSet.new()}, fn {type, spec},
                                                               {:ok, seen_types, seen_backends} ->
      case precheck(type, spec, seen_types, seen_backends) do
        :ok ->
          backend = backend_component_of(spec)
          {:cont, {:ok, MapSet.put(seen_types, type), MapSet.put(seen_backends, backend)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, _, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # precheck = validate_spec + type-uniqueness + backend-uniqueness, NO write.
  # Uniqueness is checked against BOTH the live table and the within-batch seen
  # sets (so two new decls colliding on type or backend are rejected as a pair).
  defp precheck(type, spec, seen_types, seen_backends) do
    with :ok <- validate_spec(type, spec),
         backend = backend_component_of(spec),
         :ok <- check_type_unique(type, seen_types),
         :ok <- check_backend_unique(backend, seen_backends) do
      :ok
    end
  end

  defp check_type_unique(type, seen_types) do
    if MapSet.member?(seen_types, type) or type_taken?(type) do
      {:error, {:duplicate_type, type}}
    else
      :ok
    end
  end

  defp check_backend_unique(backend, seen_backends) do
    if MapSet.member?(seen_backends, backend) or backend_taken?(backend) do
      {:error, {:duplicate_backend, backend}}
    else
      :ok
    end
  end

  defp backend_component_of(%{backend_component: backend}), do: backend
  defp backend_component_of(_), do: nil

  # `<type>` is the ETS key — an O(1) membership test.
  defp type_taken?(type), do: :ets.member(@table, type)

  # `backend_component` is NOT the key — scan the table for any entry already
  # claiming this backend (codex HIGH-1). Returns false for a nil backend (a
  # malformed spec is rejected earlier by `validate_spec/2`).
  defp backend_taken?(nil), do: false

  defp backend_taken?(backend) do
    :ets.tab2list(@table)
    |> Enum.any?(fn {_type, %{backend_component: b}} -> b == backend end)
  end

  # Boot-defined registration source — a pure, NOT-runtime-mutable list of
  # `{type, spec}`. P1 adds the per-agent config-dir families (one `<ns>-agents`
  # type per config-dir namespace in use). P2 extends with uploads. Kept as a
  # function so future phases add entries here, never via a runtime call.
  #
  # Resource-unification P1 — config-dir types. Each `<ns>-agents` type's
  # `backend_component` is the SAME `"<ns>-agents"` string, so the resolver joins
  # `Home.path("<ns>-agents")/<ws>/<name>` — BYTE-IDENTICAL to the pre-P1
  # `Ezagent.Sandbox.ConfigDir.path/2` layout (Locked-contract #7). The namespaces
  # are the catalog declared by Template classes' `config_dir_namespace/0` (cc,
  # codex); listed here statically because the resolver allowlist is immutable at
  # boot and must not depend on plugin Application start ordering.
  @config_dir_namespaces ["cc", "codex"]

  # Resource-unification P2b — uploads type. Chat attachments live at
  # `Home.path("uploads")/<ws>/<name>` (ws-partitioned). `uploads_authority/2`
  # asserts `uri.<ws> == scope.workspace`, the structural replacement for the old
  # participation-based controller authz. A DISTINCT authority fn from
  # config-dir's so `config_dir_type?/1` (which keys on authority identity) never
  # claims uploads.
  @uploads_type "uploads"

  @spec boot_registrations() :: [{String.t(), map()}]
  defp boot_registrations do
    config_dir =
      Enum.map(@config_dir_namespaces, fn namespace ->
        type = "#{namespace}-agents"

        {type,
         %{
           backend_component: type,
           authority: &FsResolver.config_dir_authority/2
         }}
      end)

    uploads =
      {@uploads_type,
       %{
         backend_component: @uploads_type,
         authority: &FsResolver.uploads_authority/2
       }}

    config_dir ++ [uploads]
  end

  # All `handle_call/3` clauses grouped here (the production `:register_all` and,
  # in non-prod, the `:register_for_test` / `:unregister_for_test` clauses).
  @impl true
  def handle_call({:register_all, decls}, _from, state) do
    {:reply, batch_register(decls), state}
  end

  # Test-only `handle_call/3` clauses (compiled out of `:prod`) — kept directly
  # below the production `:register_all` clause so all three stay grouped.
  if Mix.env() != :prod do
    def handle_call({:register_for_test, type, spec}, _from, state) do
      reply =
        cond do
          match?({:error, _}, validate_spec(type, spec)) -> validate_spec(type, spec)
          :ets.insert_new(@table, {type, spec}) -> :ok
          true -> {:error, {:already_registered, type}}
        end

      {:reply, reply, state}
    end

    def handle_call({:unregister_for_test, type}, _from, state) do
      :ets.delete(@table, type)
      {:reply, :ok, state}
    end
  end

  if Mix.env() != :prod do
    @doc """
    Register a test-only `<type>`. **Test-only** — compiled out of `:prod`, so
    there is NO production runtime registration path.
    """
    @spec register_for_test(String.t(), map()) ::
            :ok | {:error, {:already_registered, String.t()} | {:invalid_type_spec, term()}}
    def register_for_test(type, spec) when is_binary(type) and is_map(spec) do
      GenServer.call(__MODULE__, {:register_for_test, type, spec})
    end

    @doc "Remove a test-only `<type>`. **Test-only** — compiled out of `:prod`."
    @spec unregister_for_test(String.t()) :: :ok
    def unregister_for_test(type) when is_binary(type) do
      GenServer.call(__MODULE__, {:unregister_for_test, type})
    end
  end

  # Re-validate the full spec at the trust boundary. `backend_component` must be a
  # SINGLE safe Home component — reject ".", "..", separators, NUL, path-shaped or
  # absolute values (codex round-5 HIGH) so a registration cannot point a type's
  # backend outside its intended Home component (e.g. "../credentials"). `type`
  # must likewise be a single safe component (a registered `<type>` is matched
  # against a URI segment that has already passed R-2).
  defp validate_spec(type, %{backend_component: backend, authority: authority})
       when is_function(authority, 2) do
    cond do
      not FsResolver.safe_component?(type) ->
        {:error, {:invalid_type_spec, {:unsafe_type, type}}}

      not FsResolver.safe_component?(backend) ->
        {:error, {:invalid_type_spec, {:unsafe_backend_component, backend}}}

      true ->
        :ok
    end
  end

  defp validate_spec(_type, spec), do: {:error, {:invalid_type_spec, spec}}
end
