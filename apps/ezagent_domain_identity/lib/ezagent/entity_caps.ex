defmodule Ezagent.EntityCaps do
  @moduledoc """
  Storage facade for an entity's inbound capability set.

  The physical stores remain intentionally split: User caps are durable in
  `users.caps_json`; every other entity uses its snapshot-backed `:identity`
  slice. Callers use this module so that split cannot leak into authorization,
  UI, or orchestration code.

  `load/1` is receiver-aware and live-first. It reads a live Identity slice when
  one exists, then falls back to the durable store selected by the entity type.
  `load_persisted/1` deliberately skips the live process for non-blocking reads
  from inside another Kind callback.

  The mutation functions are storage operations, not authorization decisions.
  User-initiated grants and revokes must still enter through
  `Ezagent.Identity.Grant`; `grant/2` accepts only an artifact that verifies for
  the named receiver, and `revoke/2` can only remove authority.

  Return shapes are stable:

  * `load/1` and `load_persisted/1` return a verified capability list; a missing
    row or snapshot is `[]`.
  * `persist/2`, `grant/2`, and `revoke/2` return `:ok` or `{:error, reason}`.
  """

  import Ecto.Query

  alias Ezagent.{Capability, Cmd, Kind, KindRegistry, Router, SnapshotStore}
  alias Ezagent.EntityCaps.UserStore

  @type caps :: [Capability.t()] | MapSet.t(Capability.t())

  @doc "Load the entity's current verified caps, preferring a live Identity slice."
  @spec load(URI.t() | String.t()) :: [Capability.t()]
  def load(uri) do
    uri = parse_uri(uri)

    case Kind.get_slice(uri, :identity) do
      {:ok, slice} when is_map(slice) -> slice |> caps_from_slice() |> verified(uri)
      {:error, :not_found} -> load_persisted(uri)
      _transient_or_invalid_live_read -> []
    end
  end

  @doc "Load verified caps from the entity's physical durable store without calling a live Kind."
  @spec load_persisted(URI.t() | String.t()) :: [Capability.t()]
  def load_persisted(uri) do
    uri = parse_uri(uri)

    caps =
      if user_uri?(uri) do
        UserStore.load(uri)
      else
        snapshot_caps(uri)
      end

    verified(caps, uri)
  end

  @doc "Replace the entity's complete cap set in its selected physical store and live slice."
  @spec persist(URI.t() | String.t(), caps()) :: :ok | {:error, term()}
  def persist(uri, caps) do
    uri = parse_uri(uri)
    live = live?(uri)

    with {:ok, persistable_caps} <- prepare_for_storage(caps, uri, live) do
      if live do
        persist_live(uri, persistable_caps)
      else
        persist_cold(uri, persistable_caps)
      end
    end
  end

  @doc "Store a verified capability artifact for the named entity."
  @spec grant(URI.t() | String.t(), Capability.t()) :: :ok | {:error, term()}
  def grant(uri, %Capability{} = cap) do
    uri = parse_uri(uri)

    with {:ok, [_verified]} <- validate_caps([cap], uri) do
      if live?(uri) do
        dispatch_live_mutation(uri, :store_cap, %{cap: cap})
      else
        update_cold(uri, fn current -> {:ok, replace_by_identity(current, cap)} end)
      end
    end
  end

  @doc "Remove the matching capability identity from the named entity."
  @spec revoke(URI.t() | String.t(), Capability.t()) :: :ok | {:error, term()}
  def revoke(uri, %Capability{} = cap) do
    uri = parse_uri(uri)

    if live?(uri) do
      dispatch_live_mutation(uri, :remove_cap, %{cap: cap})
    else
      update_cold(uri, fn current -> Capability.revoke(MapSet.new(current), cap) end)
    end
  end

  @doc false
  @spec verified_set(Enumerable.t(), URI.t() | String.t()) :: MapSet.t(Capability.t())
  def verified_set(caps, uri), do: Ezagent.Cap.verified_set(caps, parse_uri(uri))

  @doc false
  @spec prepare_for_storage(caps(), URI.t() | String.t(), boolean()) ::
          {:ok, [Capability.t()]} | {:error, term()}
  def prepare_for_storage(caps, uri, live?) when is_boolean(live?) do
    uri = parse_uri(uri)

    with {:ok, verified_caps} <- validate_caps(caps, uri),
         {:ok, persistable_caps} <- preserve_derived_caps(uri, verified_caps, live?) do
      {:ok, persistable_caps}
    end
  end

  defp persist_live(uri, caps) do
    dispatch_live_mutation(uri, :persist_caps, %{caps: caps})
  end

  defp dispatch_live_mutation(uri, action, args) do
    target = Ezagent.URI.with_action(Ezagent.URI.instance(uri), :identity, action)

    Router.dispatch(%Cmd{
      target: target,
      action: action,
      args: args,
      ctx: %{
        caller: :vm_internal,
        caps: MapSet.new(),
        mode: :call,
        reply: {:caller_inbox, self()}
      }
    })
    |> normalize_dispatch_result()
  end

  defp persist_cold(uri, caps) do
    if user_uri?(uri) do
      UserStore.persist(uri, caps)
    else
      persist_snapshot(uri, caps)
    end
  end

  defp persist_snapshot(uri, caps) do
    case EzagentCore.Repo.transaction(fn -> persist_snapshot_transaction(uri, caps) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_snapshot_transaction(uri, caps) do
    uri_string = URI.to_string(uri)

    case locked_snapshot(uri_string) do
      nil ->
        {:error, :not_found}

      row ->
        with {:ok, state} <- Ezagent.Ecto.KindSnapshot.decode_state(row),
             {:ok, _result} <-
               SnapshotStore.write(uri, put_identity_caps(state, caps),
                 kind_type: row.kind_type,
                 version: (row.version || 0) + 1
               ) do
          :ok
        else
          :error -> {:error, :invalid_snapshot}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp update_cold(uri, mutation) do
    if user_uri?(uri) do
      UserStore.update(uri, fn current -> prepare_mutation(uri, current, mutation) end)
    else
      update_snapshot(uri, mutation)
    end
  end

  defp update_snapshot(uri, mutation) do
    case EzagentCore.Repo.transaction(fn -> update_snapshot_locked(uri, mutation) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_snapshot_locked(uri, mutation) do
    case locked_snapshot(URI.to_string(uri)) do
      nil ->
        {:error, :not_found}

      row ->
        with {:ok, state} <- Ezagent.Ecto.KindSnapshot.decode_state(row),
             current <-
               state
               |> Map.get(:identity, %{})
               |> Kind.normalize_slice_view()
               |> caps_from_slice(),
             {:ok, caps} <- prepare_mutation(uri, current, mutation),
             {:ok, _result} <-
               SnapshotStore.write(uri, put_identity_caps(state, caps),
                 kind_type: row.kind_type,
                 version: (row.version || 0) + 1
               ) do
          :ok
        else
          :error -> {:error, :invalid_snapshot}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp prepare_mutation(uri, current, mutation) do
    with {:ok, mutated} <- mutation.(current),
         {:ok, persistable} <- prepare_for_storage(mutated, uri, false) do
      {:ok, persistable}
    end
  end

  defp locked_snapshot(uri_string) do
    from(snapshot in Ezagent.Ecto.KindSnapshot,
      where: snapshot.uri == ^uri_string,
      lock: "FOR UPDATE"
    )
    |> EzagentCore.Repo.one()
  end

  defp snapshot_caps(uri) do
    case SnapshotStore.latest(uri) do
      {:ok, %{state: state}} when is_map(state) ->
        state
        |> Map.get(:identity, %{})
        |> Kind.normalize_slice_view()
        |> caps_from_slice()

      _ ->
        []
    end
  end

  defp put_identity_caps(state, caps) do
    identity = Map.get(state, :identity, %{state: %{}})

    updated =
      case identity do
        %{state: persistent} when is_map(persistent) ->
          Map.put(identity, :state, Map.put(persistent, :caps, MapSet.new(caps)))

        flat when is_map(flat) ->
          Map.put(flat, :caps, MapSet.new(caps))

        _ ->
          %{state: %{caps: MapSet.new(caps)}}
      end

    Map.put(state, :identity, updated)
  end

  defp validate_caps(caps, uri) when is_list(caps) or is_struct(caps, MapSet) do
    caps = Enum.to_list(caps)
    verified = verified_set(caps, uri)

    if Enum.all?(caps, &match?(%Capability{}, &1)) and
         MapSet.size(verified) == length(caps) do
      {:ok, caps |> dedupe_by_identity() |> MapSet.to_list()}
    else
      {:error, :invalid_cap_artifact}
    end
  end

  defp validate_caps(_caps, _uri), do: {:error, :invalid_cap_artifact}

  defp preserve_derived_caps(uri, caps, live) do
    if live or not user_uri?(uri) do
      {:ok, %{caps: derived}} = Ezagent.ActionSet.Identity.create(%{uri: uri, initial_caps: []})
      merged = Enum.reduce(derived, MapSet.new(caps), &replace_by_identity(&2, &1))
      {:ok, MapSet.to_list(merged)}
    else
      {:ok, caps}
    end
  end

  defp dedupe_by_identity(caps) do
    Enum.reduce(caps, %{}, fn cap, acc ->
      Map.put(acc, Capability.identity_key(cap), cap)
    end)
    |> Map.values()
    |> MapSet.new()
  end

  defp replace_by_identity(caps, cap) do
    caps
    |> Enum.reject(&(Capability.identity_key(&1) == Capability.identity_key(cap)))
    |> MapSet.new()
    |> MapSet.put(cap)
  end

  defp caps_from_slice(slice) do
    case Map.get(slice, :caps) do
      %MapSet{} = caps -> MapSet.to_list(caps)
      caps when is_list(caps) -> caps
      _ -> []
    end
  end

  defp verified(caps, uri), do: caps |> verified_set(uri) |> MapSet.to_list()

  defp live?(uri), do: match?({:ok, _pid}, KindRegistry.lookup(uri))

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_uri), do: false

  defp parse_uri(%URI{} = uri), do: Ezagent.URI.instance(uri)
  defp parse_uri(uri) when is_binary(uri), do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance()

  defp normalize_dispatch_result(:ok), do: :ok
  defp normalize_dispatch_result({:ok, _result}), do: :ok
  defp normalize_dispatch_result({:error, _reason} = error), do: error
  defp normalize_dispatch_result(other), do: {:error, {:unexpected_persist_result, other}}
end
