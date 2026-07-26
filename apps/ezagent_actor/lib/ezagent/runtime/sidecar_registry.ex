defmodule Ezagent.Runtime.SidecarRegistry do
  @moduledoc """
  V5 pid-closure, A1a/A1b — the ONE unified sidecar registry.

  This registry REPLACES the 6 per-plugin sidecar registries one pilot at a
  time (A1b: PTY first, then the rest). A1b starts it in
  `EzagentActor.Application` (runtime infra, next to `Ezagent.KindRegistry`)
  and migrates the PTY sidecar onto it; unmigrated plugins keep their own
  registries until their turn.

  ## Keys: plugin-qualified tuples

  Every key is a `{parent_uri, plugin, role}` tuple (codex round-2 #4): the
  key PHYSICALLY includes the plugin identity, so plugins never have to
  coordinate on a shared role vocabulary — two plugins may both register a
  `:backend` role under the same parent URI without colliding. Sidecars are
  addressed by this resolver key, NOT by a new URI string (no URI-grammar
  change).

  ## Registration: `:via` SELF-registration by the child

  A sidecar child registers ITSELF by starting under
  `name: Ezagent.Runtime.SidecarRegistry.via(parent_uri, plugin, role)` — the
  entry is owned by, and dies with, the child (std `Registry` DOWN-cleanup).
  There is deliberately NO `register(key, pid)` function: no other process —
  the resolver included — may become the owner of a child's entry.

  ## Surviving a registry restart (V5 A1b codex #5)

  The registry is a `:one_for_one` child of `EzagentActor.Application`,
  while sidecar WORKERS live under their own domain app's supervisor. If
  the registry crashes, its supervisor restarts it EMPTY — live workers
  stay up but lose their entry and become permanently unreachable. The
  robustness contract is therefore: **a sidecar worker watches the
  registry and re-registers ITSELF on its `:DOWN`**. The shared helper is
  three functions (reused by every sidecar, not per-sidecar boilerplate):

    * `watch/0` — in `init/1`: monitor the registry, keep the ref in state;
    * `registry_down?/2` — in `handle_info/2`: is this `:DOWN` the
      registry's (match it BEFORE any generic stale-DOWN clause);
    * `re_register/1` — on that `:DOWN`: re-register the CALLING process
      under its key (self-registration, same owner rule as `:via`),
      waiting briefly for the restarted registry, then re-arm `watch/0`.
      COLLISION POLICY (V5 A1b codex blocker B): if a replacement won the
      key during the empty-restart window, `re_register` reports
      `{:error, :already_registered}` and the LOSING worker terminates
      itself gracefully (its `terminate/2` releases the OS child) instead
      of retrying forever — exactly one sidecar survives per key.
  """

  @registry __MODULE__

  @typedoc """
  A normalized sidecar key: `{parent_uri_string, plugin, role}`.
  """
  @type key :: {String.t(), atom(), atom()}

  @doc """
  Child spec for the (future, A1b) supervision-tree entry. Forces
  `keys: :unique` + the module name; callers cannot override them.
  """
  def child_spec(opts) do
    opts
    |> Keyword.merge(keys: :unique, name: @registry)
    |> Registry.child_spec()
  end

  @doc """
  Start the unified sidecar registry (standalone).

  A1b: started by `EzagentActor.Application` in production/test boots;
  `start_link/1` remains for standalone use.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Registry.start_link(keys: :unique, name: Keyword.get(opts, :name, @registry))
  end

  @doc """
  The `:via` tuple a sidecar child SELF-registers under:

      GenServer.start_link(MySidecar, args,
        name: Ezagent.Runtime.SidecarRegistry.via(parent_uri, :my_plugin, :backend))

  `parent_uri` is normalized to its string form; `plugin` and `role` are
  atoms (the plugin's own identity module/atom and its private role
  vocabulary).
  """
  @spec via(URI.t() | String.t(), atom(), atom()) :: {:via, Registry, {atom(), key()}}
  def via(parent_uri, plugin, role),
    do: {:via, Registry, {@registry, key(parent_uri, plugin, role)}}

  @doc """
  The normalized registry key for `{parent_uri, plugin, role}`.
  """
  @spec key(URI.t() | String.t(), atom(), atom()) :: key()
  def key(parent_uri, plugin, role) when is_atom(plugin) and is_atom(role),
    do: {uri_string(parent_uri), plugin, role}

  @doc """
  Is the registry process running? The resolver treats "not started" as
  "no sidecar registered" rather than crashing (A1a left it unwired; A1b
  starts it in `EzagentActor.Application`).
  """
  @spec started?() :: boolean()
  def started?, do: Process.whereis(@registry) != nil

  # ── Registry-restart robustness (V5 A1b codex #5) ─────────────────────────
  # Shared helper for EVERY sidecar worker: watch the registry, notice its
  # :DOWN, re-register SELF (same owner rule as the :via start), re-arm.

  @doc """
  Monitor the unified registry from a sidecar worker (call ONCE from the
  worker's own process, e.g. in `init/1`). Keep the returned ref in state
  and pass incoming `:DOWN` messages to `registry_down?/2`.
  """
  @spec watch() :: reference()
  def watch, do: Process.monitor(@registry)

  @doc """
  True when `msg` is the `:DOWN` of the registry monitor `ref` returned by
  `watch/0`. A worker matches this BEFORE any generic stale-`:DOWN` clause
  (its own child/process monitors use different refs, so this never
  misfires).
  """
  @spec registry_down?(term(), reference() | nil) :: boolean()
  def registry_down?({:DOWN, ref, :process, _pid, _reason}, ref)
      when is_reference(ref),
      do: true

  def registry_down?(_msg, _ref), do: false

  @doc """
  Re-register the CALLING process under `{parent_uri, plugin, role}` after
  a registry restart. Self-registration only — the same owner rule as the
  `:via` start (there is still no way to register SOMEONE ELSE).

  Waits briefly (≤ ~500 ms) for the supervisor-restarted registry to come
  back before giving up: `:ok` on success, `{:error, :registry_unavailable}`
  if it did not. On failure the worker should retry later (its entry is
  gone until it does). Pid-free: the registry's owner pid never leaves the
  seam.

  ## Collision policy (V5 A1b codex blocker B)

  During the registry's empty-restart window a fresh sidecar start can
  register a REPLACEMENT under the same key. When the ORIGINAL worker then
  re-registers and finds the key owned by a DIFFERENT LIVE pid, it lost the
  race: `re_register` returns `{:error, :already_registered}` and does NOT
  retry. Two live sidecars for one key must never coexist — and the
  replacement is the one reachable through the seam — so the ONLY correct
  handling is for the LOSING (original) worker to TERMINATE ITSELF
  gracefully (stop; its `terminate/2` releases its OS child). Every sidecar
  inherits the detection here; the graceful-stop mapping lives in each
  sidecar's re-register clause (see `Ezagent.Domain.Pty.Server`). A
  `{:error, :already_registered}` whose owner is already DEAD is just the
  Registry's asynchronous DOWN-cleanup lagging — that case retries normally.
  """
  @spec re_register({URI.t() | String.t(), atom(), atom()}, non_neg_integer()) ::
          :ok | {:error, :registry_unavailable} | {:error, :already_registered}
  def re_register(key, attempts \\ 50)
  def re_register(_key, 0), do: {:error, :registry_unavailable}

  def re_register({parent_uri, plugin, role} = key_tuple, attempts) do
    if started?() do
      try do
        case Registry.register(@registry, key(parent_uri, plugin, role), nil) do
          {:ok, _owner} -> :ok
          {:error, {:already_registered, pid}} when pid == self() -> :ok
          {:error, {:already_registered, pid}} -> collision_or_retry(pid, key_tuple, attempts)
        end
      rescue
        # The registry's name is back (started?/0) but its ETS tables are
        # still being built, or it died AGAIN mid-call: :ets raises raw
        # :badarg, which only `rescue` normalizes to ArgumentError (a raw
        # `catch :error, %ArgumentError{}` would MISS it). Same restart-
        # window race as lookup/1 — retry, never crash the worker.
        ArgumentError -> retry_re_register(key_tuple, attempts)
      catch
        :exit, _ -> retry_re_register(key_tuple, attempts)
      end
    else
      retry_re_register(key_tuple, attempts)
    end
  end

  # The key is owned by a DIFFERENT pid. A LIVE owner is a replacement that
  # won the restart race (collision policy above — the caller must stop, no
  # retry); a DEAD one is the Registry's DOWN-cleanup still in flight — wait
  # it out like any other restart-window race.
  defp collision_or_retry(pid, key_tuple, attempts) do
    if Process.alive?(pid),
      do: {:error, :already_registered},
      else: retry_re_register(key_tuple, attempts)
  end

  defp retry_re_register(key_tuple, attempts) do
    Process.sleep(10)
    re_register(key_tuple, attempts - 1)
  end

  # INTERNAL — the resolver seam's ONLY read path into this registry
  # (`Ezagent.Runtime.Resolver.pid_for/1`). Never call directly; the
  # acquisition-primitive census exempts this file as part of the seam.
  @doc false
  @spec lookup({URI.t() | String.t(), atom(), atom()}) :: {:ok, pid()} | :error
  def lookup({parent_uri, plugin, role}) do
    case Registry.lookup(@registry, key(parent_uri, plugin, role)) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  rescue
    # Registry-restart window (codex #5): the resolver's started?/0 check
    # raced the restart — treat "registry momentarily gone" as :error,
    # NEVER a crash (a resolver that raises during the window would take
    # every seam caller down with the registry).
    ArgumentError -> :error
  end

  # INTERNAL (seam-exempt) — enumerate every self-registered entry for one
  # plugin as `{parent_uri_string, role, pid}` triples. This is the A1b
  # replacement for the retired per-plugin `DynamicSupervisor.which_children/1`
  # + `:sys.get_state/2` enumeration (codex: the enumeration vector): a
  # sidecar app that must LIST its own children (e.g. PTY `list_agents/0`)
  # does it HERE, inside the seam, never by walking a supervisor.
  @doc false
  @spec entries_for_plugin(atom()) :: [{String.t(), atom(), pid()}]
  def entries_for_plugin(plugin) when is_atom(plugin) do
    if started?() do
      Registry.select(@registry, [
        {{{:"$1", :"$2", :"$3"}, :"$4", :_}, [{:==, :"$2", plugin}], [{{:"$1", :"$3", :"$4"}}]}
      ])
    else
      []
    end
  rescue
    # Registry-restart window (codex #5) — see lookup/1.
    ArgumentError -> []
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri
end
