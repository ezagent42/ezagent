defmodule Ezagent.UI.SessionViewRegistry do
  @moduledoc """
  Phase 8b — ETS-backed registry of `Ezagent.UI.SessionView` modules.

  Mirrors the BehaviorRegistry / SpawnRegistry / TemplateRegistry pattern:
  plugins register at boot, consumers (admin_live) query at render.

  ## Lifecycle

  Plugin Applications call `init/0` (idempotent) before `register/1`.
  This keeps `ezagent_core` (and `EzagentCore.EtsOwner`) free of any
  UI dependency — the table is owned by whichever plugin Application
  initializes first. Subsequent inits are no-ops.

  If all plugins that registered views go down simultaneously the
  table dies with the last :public owner — but in normal operation
  the table outlives any individual plugin restart because plugin
  boot order keeps a holder alive.

  ## Operations

  - `init/0`: plugin calls this once in Application.start/2
  - `register/1`: plugin registers a SessionView module
  - `applicable_views/1`: admin_live queries with session_uri to get
    the list of views the user can choose
  - `lookup/1`: admin_live queries with the selected view id to get
    the module to render
  """

  @table :ezagent_session_view_registry

  @doc "ETS table name (for tests/debug)."
  def table, do: @table

  @doc """
  Create the ETS table. Idempotent — safe to call from every plugin
  Application.start/2. The first caller creates; subsequent callers
  see `:ets.whereis/1 != :undefined` and no-op.
  """
  @spec init() :: :ok
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Register a SessionView module. Overwrites if same id is registered."
  @spec register(module()) :: :ok
  def register(view_module) when is_atom(view_module) do
    id = view_module.id()
    :ets.insert(@table, {id, view_module})
    :ok
  end

  @doc """
  Get all registered views that apply to the given session_uri.

  Returns a list of maps `%{id, label, icon, module}` sorted by id.
  Each view's `applies_to?/1` callback is wrapped in try/catch so a
  buggy plugin can't tear down the whole render.
  """
  @spec applicable_views(URI.t()) :: [%{id: atom(), label: String.t(), icon: String.t(), module: module()}]
  def applicable_views(%URI{} = session_uri) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, mod} -> safe_applies_to(mod, session_uri) end)
    |> Enum.map(fn {_id, mod} ->
      %{id: mod.id(), label: mod.label(), icon: mod.icon(), module: mod}
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  T2-2b — caller-aware `applicable_views`: the views that apply to `session_uri`
  AND that `caller` is authorized to see (`SessionView.authorize_view/3`).

  This is the gated path (decision 2): every render entry uses the caller-aware
  arity so a cap-gated view (e.g. kanban-private) is dropped for a caller lacking
  its render cap, even in the same session as a view they CAN see. `applicable_views/1`
  is retained for callers with no caller dimension (it does NOT apply the cap gate).
  """
  @spec applicable_views(URI.t(), URI.t() | nil) :: [
          %{id: atom(), label: String.t(), icon: String.t(), module: module()}
        ]
  def applicable_views(%URI{} = session_uri, caller) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, mod} ->
      safe_applies_to(mod, session_uri) and safe_authorize_view(mod, caller, session_uri)
    end)
    |> Enum.map(fn {_id, mod} ->
      %{id: mod.id(), label: mod.label(), icon: mod.icon(), module: mod}
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp safe_applies_to(mod, session_uri) do
    try do
      mod.applies_to?(session_uri)
    catch
      _, _ -> false
    end
  end

  defp safe_authorize_view(mod, caller, session_uri) do
    Ezagent.UI.SessionView.authorize_view(mod, caller, session_uri)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  P2 — whether `view_module` declares a USABLE EXTERNAL render target.

  A view is an external renderer iff it exports BOTH `external_render?/0`
  AND `external_render/1` (both optional callbacks) AND `external_render?/0`
  returns `true`. Requiring `external_render/1` to ALSO be exported (codex
  P2 review HIGH) prevents publishing a half-declared view — one that says
  `external_render?/0 == true` but omits `external_render/1` — which would
  later crash the ExternalAdapter when it invokes the missing renderer.
  Internal-only views (neither callback) are `false`. The boolean probe is
  `function_exported?`-guarded + try/catch (same posture as
  `safe_applies_to/2`).
  """
  @spec external_render?(module()) :: boolean()
  def external_render?(view_module) when is_atom(view_module) do
    Code.ensure_loaded?(view_module) and
      function_exported?(view_module, :external_render?, 0) and
      function_exported?(view_module, :external_render, 1) and
      safe_external_render?(view_module)
  end

  defp safe_external_render?(mod) do
    mod.external_render?() == true
  catch
    _, _ -> false
  end

  @doc """
  P2 — all registered views that BOTH apply to `session_uri` AND declare an
  external render target. The single registration point the ExternalAdapter
  (P3) consults to discover a session's external render(s), instead of
  reaching into `Behavior.Surface` directly.

  Returns the same `%{id, label, icon, module}` shape as `applicable_views/1`,
  sorted by id.
  """
  @spec external_renderers(URI.t()) :: [
          %{id: atom(), label: String.t(), icon: String.t(), module: module()}
        ]
  def external_renderers(%URI{} = session_uri) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, mod} ->
      external_render?(mod) and safe_applies_to(mod, session_uri)
    end)
    |> Enum.map(fn {_id, mod} ->
      %{id: mod.id(), label: mod.label(), icon: mod.icon(), module: mod}
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  T2-2b — caller-aware external renderers: `external_renderers/1` additionally
  gated by `SessionView.authorize_view/3`, so the customer/anon external-render
  path only exposes views the caller holds the render cap for.
  """
  @spec external_renderers(URI.t(), URI.t() | nil) :: [
          %{id: atom(), label: String.t(), icon: String.t(), module: module()}
        ]
  def external_renderers(%URI{} = session_uri, caller) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, mod} ->
      external_render?(mod) and safe_applies_to(mod, session_uri) and
        safe_authorize_view(mod, caller, session_uri)
    end)
    |> Enum.map(fn {_id, mod} ->
      %{id: mod.id(), label: mod.label(), icon: mod.icon(), module: mod}
    end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Look up a view module by id (atom). Returns `{:ok, module} | :error`."
  @spec lookup(atom()) :: {:ok, module()} | :error
  def lookup(id) when is_atom(id) do
    case :ets.lookup(@table, id) do
      [{^id, mod}] -> {:ok, mod}
      [] -> :error
    end
  end

  @doc "List all registered view ids (for tests/debug)."
  @spec all_ids() :: [atom()]
  def all_ids do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {id, _} -> id end)
    |> Enum.sort()
  end
end
