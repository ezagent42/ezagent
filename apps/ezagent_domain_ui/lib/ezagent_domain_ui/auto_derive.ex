defmodule EzagentDomainUi.AutoDerive do
  @moduledoc """
  Phase 6 PR 10 — derive listing / detail metadata from Kind +
  Behavior introspection so UI pages don't need to be hand-written
  per Kind.

  Two outputs:

    * `list_instances(kind_atom)` — walks the public `Ezagent.Kind`
      operator plane (`list_instances/0`) for live Kinds whose
      `type_name == kind_atom`. Returns `[%{uri, kind_module,
      slice_keys}]` — V5 A1c: NO pid; the pid never leaves the actor
      seam.

    * `instance_detail(uri)` — looks up a live Kind, captures its
      framework runtime-view slice map, and zips it with the registered
      Behaviors so the UI can render slice → behavior pairs.

  Neither function knows anything about Sessions / Agents / etc —
  they work for any Kind that registers with the standard module
  callbacks (`type_name/0`, `behaviors/0`, `state_slice` on its
  Behavior).
  """

  alias Ezagent.BehaviorRegistry

  @type instance_summary :: %{
          uri: URI.t(),
          kind_module: module() | nil,
          slice_keys: [atom()]
        }

  @doc """
  Return all live instances of `kind_atom` in the running BEAM.

  Enumerates the public `Ezagent.Kind.list_instances/0` operator plane
  and filters by `type_name`. Order is by URI string (stable across
  reads).
  """
  @spec list_instances(atom()) :: [instance_summary()]
  def list_instances(kind_atom) when is_atom(kind_atom) do
    Ezagent.Kind.list_instances()
    |> Enum.map(fn {uri_raw, _status} -> summarize(parse_uri(uri_raw)) end)
    |> Enum.filter(&match_kind?(&1, kind_atom))
    |> Enum.sort_by(&URI.to_string(&1.uri))
  end

  defp parse_uri(%URI{} = u), do: u
  defp parse_uri(s) when is_binary(s), do: Ezagent.URI.new!(s)

  @doc """
  Fetch detail for a single live instance.

  Returns `{:ok, %{uri, kind_module, slices: %{key => value},
  behaviors: [{behavior_module, [action, ...]}]}}` — V5 A1c: NO pid —
  or `{:error, :not_found}`.
  """
  @spec instance_detail(URI.t()) :: {:ok, map()} | {:error, atom()}
  def instance_detail(%URI{} = uri) do
    if Ezagent.Kind.alive_locally?(uri) do
      case safe_state(uri) do
        {:ok, state} -> {:ok, build_detail(uri, state)}
        {:error, _} = err -> err
      end
    else
      {:error, :not_found}
    end
  end

  # --- Internals -----------------------------------------------------

  defp summarize(uri) do
    {kind_module, slice_keys} =
      case safe_state(uri) do
        {:ok, state} ->
          {Map.get(state, :kind), state |> Map.get(:state, %{}) |> Map.keys()}

        _ ->
          {nil, []}
      end

    %{uri: uri, kind_module: kind_module, slice_keys: slice_keys}
  end

  defp match_kind?(%{kind_module: nil}, _kind_atom), do: false

  defp match_kind?(%{kind_module: km}, kind_atom) do
    safe_type_name(km) == kind_atom
  end

  defp safe_state(uri) do
    Ezagent.Kind.runtime_view(uri)
  end

  defp build_detail(uri, state) do
    kind_module = Map.get(state, :kind)

    behaviors =
      if kind_module && function_exported?(kind_module, :behaviors, 0) do
        Enum.map(kind_module.behaviors(), fn bm ->
          actions =
            if function_exported?(bm, :actions, 0), do: bm.actions(), else: []

          %{module: inspect(bm), actions: actions}
        end)
      else
        derive_behaviors_from_registry(kind_module)
      end

    %{
      uri: uri,
      kind_module: inspect(kind_module),
      slices: Map.get(state, :state, %{}),
      behaviors: behaviors
    }
  end

  defp derive_behaviors_from_registry(nil), do: []

  defp derive_behaviors_from_registry(kind_module) do
    BehaviorRegistry.list_all()
    |> Enum.filter(fn {{km, _action}, _bm} -> km == kind_module end)
    |> Enum.group_by(fn {{_km, _action}, bm} -> bm end, fn {{_km, action}, _bm} -> action end)
    |> Enum.map(fn {bm, actions} ->
      %{module: inspect(bm), actions: Enum.sort(actions)}
    end)
  end

  defp safe_type_name(km) do
    if Code.ensure_loaded?(km) and function_exported?(km, :type_name, 0) do
      try do
        km.type_name()
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
    end
  end
end
