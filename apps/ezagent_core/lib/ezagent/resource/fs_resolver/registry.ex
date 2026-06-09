defmodule Ezagent.Resource.FsResolver.Registry do
  @moduledoc """
  Sole writer of the `Ezagent.Resource.FsResolver` `<type>` allowlist
  (Resource-unification SPEC §5.1, codex round-1..4 HIGH/CRITICAL).

  The allowlist lives in a `:protected` ETS table:

    * **reads** (`Ezagent.Resource.FsResolver.resolve/2` `:ets.lookup`) go direct
      from any process — `:protected` allows cross-process reads.
    * **writes** happen ONLY inside this GenServer's own `init/1`, from a
      boot-defined registration source — there is **no post-`init` write path**
      (no `insert/seal/unseal` message) in `:prod`.

  ## Registration happens at `init/1`, then the table is final (codex round-4)

  Earlier rounds tried a post-boot `seal/0`:

    * round-2: seal held in GenServer state → lost on restart;
    * round-3: seal in `:persistent_term` → globally `erase/1`-able;
    * round-3-final: seal in the `:protected` table but re-seeded from a mutable
      `Application` env key on restart → that key is itself reopenable.

  Every one of those left an externally-mutable reopen window. The fix is to make
  the allowlist a **pure function of a boot-defined registration source, applied
  once at `init/1`**, after which the table is never written again:

    * `init/1` reads `boot_registrations/0` (compile/config-time, NOT runtime
      mutable), inserts each valid type, and returns — there is **no message** to
      add/remove a type or to flip a seal afterwards.
    * A Registry crash + supervised restart re-runs `init/1`, which re-applies the
      EXACT SAME boot registrations and is otherwise empty — a restart can only
      reproduce the boot allowlist, never reopen it to a forged type.
    * Arbitrary runtime code calling `:ets.insert/2`/`:ets.delete/2` on the
      `:protected` table raises `ArgumentError` (non-owner), and the GenServer
      exposes no write message, so the allowlist is immutable post-boot by
      construction — no app-env / persistent_term / public-key dependency.

  For P0 `boot_registrations/0` is empty (dormant — zero real types). P1 adds the
  config-dir type and P2 the uploads type by extending that boot source, NOT by
  any runtime call.

  ## Test-only registration

  In `:test`, `register_for_test/2` / `unregister_for_test/1` mailbox messages
  exist (compiled out of `:prod`) so each test can register/clean up its own
  test-only types against the same `:protected` table.

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

    # Apply the boot-defined allowlist once. After init returns there is no write
    # path in :prod, so the table is immutable for the process lifetime; a restart
    # re-applies exactly this same source (round-4: no externally-mutable reopen).
    Enum.each(boot_registrations(), fn {type, spec} ->
      case validate_spec(type, spec) do
        :ok ->
          unless :ets.insert_new(@table, {type, spec}) do
            raise ArgumentError, "duplicate boot registration for resource type #{inspect(type)}"
          end

        {:error, reason} ->
          raise ArgumentError, "invalid boot registration #{inspect(type)}: #{inspect(reason)}"
      end
    end)

    {:ok, %{}}
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

    @impl true
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
