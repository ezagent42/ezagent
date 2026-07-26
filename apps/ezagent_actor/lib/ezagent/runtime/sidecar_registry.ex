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
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri
end
