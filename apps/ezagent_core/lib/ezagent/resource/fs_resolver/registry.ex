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

  `init/1` applies core `boot_registrations/0` (`uploads`, `git-identity` — SSH
  凭据 1b) when `ezagent_core` starts, BEFORE any plugin boots (plugins depend
  on core → start later). So core backends are claimed first and a plugin can
  never alias a core backend (backend-uniqueness). Core `boot_registrations/0`
  flows through the SAME precheck as plugin `register_all/1`, so the
  write-once-on-both property holds uniformly.

  ## Restart resilience (lifecycle rebuild-from-source on every start)

  Plugin types live in this Registry's ETS, first published at plugin boot
  (Phase-2 `register_all/1`). If this GenServer alone crashes and restarts under
  `:one_for_one`, its table dies with it and `init/1` runs anew. `init/1` rebuilds
  the **FULL** allowlist from source on EVERY start — core `boot_registrations/0`
  FIRST, then a **discovery-replay** of every loaded plugin's `resource_types/0`
  (`replay_plugin_resource_types/0`). So plugin types **self-heal** on restart;
  they do NOT vanish until the owning plugin re-boots.

  **Why this is the right shape (lifecycle principle).** The
  `use Ezagent.Lifecycle` contract (ezagent-developer `references/lifecycle.md`)
  mandates that a transient — a resource derivable from a source — is rebuilt in
  `activate/2`, which runs on EVERY start (fresh / supervisor-restart /
  cold-load), killing the "fresh-works-restart-doesn't" bug class (#110/#113/#114).
  This Registry is a plain GenServer (infra plumbing, not a Kind), so it has no
  `activate/2` — `init/1` IS its every-start hook. The allowlist is a transient
  (derivable from core `boot_registrations/0` + each plugin's `resource_types/0`),
  so `init/1` must rebuild ALL of it from source, not just core. Before this fix
  it rebuilt only core — the exact "rebuilt in the incomplete place" instance the
  lifecycle model exists to prevent.

  **Boot-mode convergence (idempotent re-registration).** Two boot modes order
  app *load* vs *start* differently, so the discovery-replay can run before OR
  alongside a plugin's own Phase-2 `register_all/1`:

    * **`Application.ensure_all_started` (dev `iex -S mix`)** — apps are loaded
      just-in-time in dependency order, so this core Registry inits BEFORE any
      plugin app is loaded → discovery finds nothing → plugins publish their types
      via Phase-2 as usual. No double call.
    * **OTP release** — the boot script LOADS every application before STARTING
      any, so at core init the plugin apps are already loaded and their
      `:ezagent_plugin` env is set → discovery replays their `resource_types/0`,
      and THEN each plugin's Phase-2 `register_all/1` re-presents the SAME decls.

  To stay correct in BOTH modes, `batch_register` is **idempotent on an identical
  re-registration**: a decl whose `<type>` is already live with the SAME
  `backend_component` is a no-op (first-writer-wins, existing spec kept), NOT an
  error. A genuine conflict is still rejected loud: a live `<type>` re-presented
  with a DIFFERENT backend (repoint), or a NEW `<type>` aliasing an
  already-claimed backend (the HIGH-1 alias attack). Without this, the release
  first-boot double call would turn into a `{:duplicate_type, …}` that
  `Ezagent.Plugin.boot/2` Phase-2 raises on — converting a silent restart bug into
  a first-boot crash. Core types are applied FIRST on every start, so a plugin can
  never shadow/alias a core type on any path. Discovery is RUNTIME (Application env
  + `apply/3`), not a compile dependency — core does not depend on any plugin; a
  plugin that raises or conflicts during the init-replay is logged + skipped, never
  crashing the Registry.

  **Security unchanged.** Still `:protected` (owner-only writes), write-once on
  both `<type>` and `backend_component`, no overwrite of a different spec, no
  reopen flag. Idempotency is strictly first-writer-wins (an identical re-register
  keeps the original spec, a conflicting one is rejected), so it cannot let a
  forged type in: every replayed decl passes the same `validate_spec` + uniqueness
  precheck, after core has claimed its backends.

  The table-ABSENT window (the GenServer down between crash and restart) is still
  covered by `FsResolver.resolve/2`'s `lookup/2` rescue, which RAISES (loud)
  rather than returning a silent `:none`; once `init/1` returns, the full
  allowlist (core + plugins) is present.

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

    # Apply the boot-defined core allowlist FIRST, through the SAME precheck the
    # plugin `register_all/1` path uses (validate + type-uniqueness +
    # backend-uniqueness, all-or-nothing) — so the write-once-on-both property
    # holds uniformly for core and plugin types. Core types register FIRST (here,
    # before any plugin type), claiming their backends; a plugin can therefore
    # never shadow a core type nor alias a core backend (codex HIGH-1).
    case batch_register(boot_registrations()) do
      :ok ->
        # Lifecycle principle (ezagent-developer `references/lifecycle.md`):
        # rebuild the FULL allowlist from source on EVERY start. This Registry is a
        # plain GenServer (infra plumbing), NOT a `use Ezagent.Lifecycle` Kind, so
        # it has no `activate/2` auto-rebuild — `init/1` IS its every-start hook and
        # must rebuild the WHOLE transient (core + plugin types), not just core. A
        # plugin's resource types are derivable from source (its `resource_types/0`
        # declaration), so on an isolated restart (plugins already loaded) we
        # re-discover + replay them here; this fixes the "fresh-works-restart-
        # doesn't" cold-restart bug class for plugin types. Boot-mode convergence:
        # under `ensure_all_started` (dev) core inits before any plugin loads →
        # discovery finds nothing → plugins publish via Phase-2 as usual; in an OTP
        # release (all apps loaded before any start) discovery runs first AND the
        # plugin's Phase-2 `register_all/1` re-presents the same decls — handled by
        # `batch_register` being IDEMPOTENT on an identical re-registration (see the
        # moduledoc "Boot-mode convergence"), so the double call no-ops instead of
        # raising a `{:duplicate_type, …}` first-boot crash.
        replay_plugin_resource_types()
        {:ok, %{}}

      {:error, reason} ->
        raise ArgumentError, "invalid core boot registration: #{inspect(reason)}"
    end
  end

  # Discover every loaded resource provider. Plugins publish their provider via
  # `:ezagent_plugin`; non-plugin domain apps use `:ezagent_resource_provider`.
  # Replay each provider's `resource_types/0` through the write-once
  # `batch_register`. RUNTIME discovery
  # (Application env + `apply/3`), NOT a compile dependency — core does not depend
  # on any plugin. Per-plugin isolation: a plugin that raises/throws/exits, or
  # whose decls conflict with an already-claimed (core or earlier-plugin)
  # type/backend, is logged + SKIPPED — never crashing the Registry. The `catch`
  # arm (codex MED-1) is essential: `init/1` calls this BEFORE returning
  # `{:ok, …}`, so an uncaught `throw`/`exit` from a buggy `resource_types/0` would
  # abort the Registry's own (re)start — the exact crash-resilience this fix adds.
  # A genuine conflict is also caught loudly at the plugin's own Phase-2 boot on
  # first start; here, during a restart-replay, best-effort restoration is correct.
  defp replay_plugin_resource_types do
    for {app, _desc, _vsn} <- Application.loaded_applications(),
        mod =
          Application.get_env(app, :ezagent_resource_provider) ||
            Application.get_env(app, :ezagent_plugin),
        is_atom(mod) and not is_nil(mod),
        Code.ensure_loaded?(mod),
        function_exported?(mod, :resource_types, 0) do
      try do
        case batch_register(mod.resource_types()) do
          :ok ->
            :ok

          {:error, reason} ->
            require Logger

            Logger.warning(
              "FsResolver.Registry: skipped #{inspect(mod)} resource_types on init-replay: " <>
                inspect(reason)
            )
        end
      rescue
        e ->
          require Logger

          Logger.warning(
            "FsResolver.Registry: #{inspect(mod)}.resource_types/0 raised on init-replay: " <>
              Exception.message(e)
          )
      catch
        # `rescue` covers only `:error`-class exceptions; a `throw/1` or `exit/1`
        # from the plugin callback (or its `batch_register`) must ALSO be isolated,
        # or it would escape this comprehension and crash the Registry start.
        kind, reason ->
          require Logger

          Logger.warning(
            "FsResolver.Registry: #{inspect(mod)}.resource_types/0 #{kind} on init-replay: " <>
              inspect(reason)
          )
      end
    end

    :ok
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
      # `precheck_batch` proved every decl is EITHER insertable-new OR an
      # idempotent identical re-registration (same `<type>` AND same
      # `backend_component` already live). `:ets.insert_new/2` does the right
      # thing for both: it inserts a new key, and returns `false` (a no-op,
      # KEEPING the existing spec) for an already-present key. We deliberately do
      # NOT assert `true =` on the result — the idempotent no-op is expected on the
      # release first-boot path (core init's discovery-replay registers a plugin's
      # types, then that plugin's own Phase-2 `register_all/1` re-presents the SAME
      # decls). First-writer-wins on the no-op preserves write-once authority.
      Enum.each(decls, fn {type, spec} -> :ets.insert_new(@table, {type, spec}) end)
      :ok
    end
  end

  # Reduce over the batch carrying the set of types + backends already SEEN in
  # this batch, so a duplicate within the batch is caught (not only a duplicate
  # against the live table). Halts on the first failure → nothing is inserted.
  defp precheck_batch(decls) do
    decls
    |> Enum.reduce_while({:ok, MapSet.new(), MapSet.new()}, fn
      {type, spec}, {:ok, seen_types, seen_backends}
      when is_binary(type) and is_map(spec) ->
        # `:ok` = insert a new type; `:idempotent` = the SAME type+backend is
        # already live (a no-op re-registration — release first-boot replay+Phase-2
        # double call). Both advance the seen-sets (so an intra-batch duplicate of
        # the same type/backend is still caught); only `:idempotent` skips the
        # insert (handled by `:ets.insert_new` returning false).
        case precheck(type, spec, seen_types, seen_backends) do
          outcome when outcome in [:ok, :idempotent] ->
            backend = backend_component_of(spec)
            {:cont, {:ok, MapSet.put(seen_types, type), MapSet.put(seen_backends, backend)}}

          {:error, _} = err ->
            {:halt, err}
        end

      # A malformed declaration (not a `{binary, map}` tuple) must NOT crash the
      # owner GenServer (codex MEDIUM — a plugin returning e.g. `[:bad]` from
      # resource_types/0 would otherwise FunctionClauseError the Registry and, on
      # the supervised restart, drop every OTHER plugin's already-registered
      # types). Reject it as a normal error → `Plugin.boot/1` raises naming the
      # offending plugin; the Registry stays alive.
      other, {:ok, _seen_types, _seen_backends} ->
        {:halt, {:error, {:invalid_resource_type_decl, other}}}
    end)
    |> case do
      {:ok, _, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # precheck = validate_spec + type-uniqueness + backend-uniqueness, NO write.
  # Returns `:ok` (insert a new type), `:idempotent` (the SAME type+backend is
  # already live — a no-op re-registration), or `{:error, _}` (a genuine conflict).
  # Uniqueness is checked against BOTH the live table and the within-batch seen
  # sets (so two new decls colliding on type or backend are rejected as a pair).
  defp precheck(type, spec, seen_types, seen_backends) do
    with :ok <- validate_spec(type, spec),
         backend = backend_component_of(spec) do
      case check_type_unique(type, backend, seen_types) do
        :idempotent ->
          # Same type + same backend already live → no-op. Its backend is
          # legitimately "claimed by itself", so SKIP the backend-uniqueness check
          # (which would otherwise flag the self-collision).
          :idempotent

        :ok ->
          check_backend_unique(backend, seen_backends)

        {:error, _} = err ->
          err
      end
    end
  end

  # A type is unique unless it is already live or already seen in this batch.
  # The one exception that is NOT an error: the SAME type re-registered with the
  # SAME `backend_component` already live — an idempotent no-op (release first-boot
  # discovery-replay + the plugin's own Phase-2 `register_all/1` both present the
  # identical decl). A live type re-presented with a DIFFERENT backend is a repoint
  # attempt → rejected (write-once authority). An intra-batch duplicate type is
  # always an author error → rejected.
  defp check_type_unique(type, backend, seen_types) do
    cond do
      MapSet.member?(seen_types, type) ->
        {:error, {:duplicate_type, type}}

      true ->
        case :ets.lookup(@table, type) do
          [] -> :ok
          [{^type, %{backend_component: ^backend}}] -> :idempotent
          [{^type, _other_spec}] -> {:error, {:duplicate_type, type}}
        end
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

  # `backend_component` is NOT the key — scan the table for any entry already
  # claiming this backend (codex HIGH-1). Returns false for a nil backend (a
  # malformed spec is rejected earlier by `validate_spec/2`).
  defp backend_taken?(nil), do: false

  defp backend_taken?(backend) do
    :ets.tab2list(@table)
    |> Enum.any?(fn {_type, %{backend_component: b}} -> b == backend end)
  end

  # Resource-unification P2b — uploads type. Chat attachments live at
  # `Home.path("uploads")/<ws>/<name>` (ws-partitioned). `uploads_authority/2`
  # asserts `uri.<ws> == scope.workspace`, the structural replacement for the old
  # participation-based controller authz. A DISTINCT authority fn from
  # config-dir's so `config_dir_type?/1` (which keys on authority identity) never
  # claims uploads.
  @uploads_type "uploads"

  @git_identity_type "git-identity"

  @spec boot_registrations() :: [{String.t(), map()}]
  defp boot_registrations do
    uploads =
      {@uploads_type,
       %{
         backend_component: @uploads_type,
         authority: &FsResolver.uploads_authority/2
       }}

    # SSH 凭据 1b — per-agent git 身份目录。core 注册（不是 plugin 的
    # `resource_types/0`）：这不是 flavor 概念，是 agent 通用概念。
    git_identity =
      {@git_identity_type,
       %{
         backend_component: @git_identity_type,
         authority: &FsResolver.git_identity_authority/2
       }}

    [uploads, git_identity]
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

    # Run the init-time plugin discovery+replay on demand (owner process), so a
    # test can prove restart-replay without killing the live singleton: set a
    # loaded app's `:ezagent_plugin` env to a module with `resource_types/0`, call
    # this, and assert the plugin type resolves. This is the SAME function `init/1`
    # runs on every start.
    def handle_call(:__replay_plugins_for_test__, _from, state) do
      {:reply, replay_plugin_resource_types(), state}
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

    @doc "Run the init-time plugin discovery+replay now. **Test-only.**"
    @spec replay_plugins_for_test() :: :ok
    def replay_plugins_for_test, do: GenServer.call(__MODULE__, :__replay_plugins_for_test__)
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
