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

  alias Ezagent.{
    Capability,
    Cmd,
    Kind,
    KindRegistry,
    Lifecycle,
    ReadyGate,
    Router,
    SnapshotStore,
    SpawnRegistry
  }

  alias Ezagent.EntityCaps.UserStore

  @type caps :: [Capability.t()] | MapSet.t(Capability.t())

  @doc "Load the entity's current verified caps, preferring a live Identity slice."
  @spec load(URI.t() | String.t()) :: [Capability.t()]
  def load(uri) do
    uri = parse_uri(uri)

    if fenced?(uri), do: [], else: do_load(uri)
  end

  defp do_load(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} when pid == self() ->
        # `Cap.authorize/3` runs inside the target Kind. When the target is also
        # the authenticated holder, a live-first `Kind.get_slice/2` would call
        # the current GenServer synchronously and fail closed as
        # `:holder_revoked`. The marker-bearing snapshot / user projection is
        # the independently stored copy of the same Identity slice and avoids
        # that self-call without trusting the presented candidate caps.
        load_persisted(uri)

      _other ->
        case Kind.get_slice(uri, :identity) do
          {:ok, slice} when is_map(slice) -> slice |> caps_from_slice() |> verified(uri)
          {:error, :not_found} -> load_persisted(uri)
          _transient_or_invalid_live_read -> []
        end
    end
  end

  @doc "Load verified caps from the entity's physical durable store without calling a live Kind."
  @spec load_persisted(URI.t() | String.t()) :: [Capability.t()]
  def load_persisted(uri) do
    uri = parse_uri(uri)

    if fenced?(uri), do: [], else: do_load_persisted(uri)
  end

  defp do_load_persisted(uri) do
    caps =
      if user_uri?(uri) do
        UserStore.load(uri)
      else
        snapshot_caps(uri)
      end

    verified(caps, uri)
  end

  defp fenced?(uri), do: Ezagent.Identity.Offboarding.RevocationFence.fenced?(uri)

  @doc "Replace the entity's complete cap set in its selected physical store and live slice."
  @spec persist(URI.t() | String.t(), caps()) :: :ok | {:error, term()}
  def persist(uri, caps) do
    uri = parse_uri(uri)

    with :ok <- validate_issued_caps(caps, uri) do
      Lifecycle.with_entity_transition(uri, fn ->
        with :ok <- ensure_mutation_target(uri) do
          dispatch_mutation(uri, :persist_caps, %{caps: Enum.to_list(caps)})
        end
      end)
    end
  end

  @doc "Store a verified capability artifact for the named entity."
  @spec grant(URI.t() | String.t(), Capability.t()) :: :ok | {:error, term()}
  def grant(uri, %Capability{} = cap) do
    uri = parse_uri(uri)

    with :ok <- validate_issued_caps([cap], uri),
         {:ok, [_verified]} <- validate_caps([cap], uri) do
      Lifecycle.with_entity_transition(uri, fn ->
        with :ok <- ensure_mutation_target(uri) do
          dispatch_mutation(uri, :store_cap, %{cap: cap})
        end
      end)
    end
  end

  @doc "Remove the matching capability identity from the named entity."
  @spec revoke(URI.t() | String.t(), Capability.t()) :: :ok | {:error, term()}
  def revoke(uri, %Capability{} = cap) do
    uri = parse_uri(uri)

    Lifecycle.with_entity_transition(uri, fn ->
      with :ok <- ensure_mutation_target(uri) do
        dispatch_mutation(uri, :remove_cap, %{cap: cap})
      end
    end)
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

  @doc false
  @spec validate_issued_caps(caps(), URI.t() | String.t()) :: :ok | {:error, term()}
  def validate_issued_caps(caps, uri) when is_list(caps) or is_struct(caps, MapSet) do
    uri = parse_uri(uri)

    if Enum.all?(caps, &issued_for?(&1, uri)) do
      :ok
    else
      {:error, :invalid_cap_artifact}
    end
  end

  def validate_issued_caps(_caps, _uri), do: {:error, :invalid_cap_artifact}

  defp dispatch_mutation(uri, action, args) do
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
      },
      origin: :trusted_internal
    })
    |> normalize_dispatch_result()
  end

  defp ensure_mutation_target(uri) do
    with :ok <- ensure_live(uri),
         :ok <- ReadyGate.await(uri, Ezagent.Invocation.activate_budget_ms()) do
      :ok
    else
      {:error, :timeout} -> {:error, :activate_timeout}
      {:error, :not_created} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_live(uri) do
    if user_uri?(uri) do
      if UserStore.exists?(uri) do
        Ezagent.Entity.spawn_principal(uri)
      else
        {:error, :not_found}
      end
    else
      case Ezagent.KindRegistry.lookup(uri) do
        {:ok, _pid} ->
          :ok

        :error ->
          with {:ok, _snapshot} <- SnapshotStore.latest(uri) do
            case SpawnRegistry.ensure_live(uri) do
              {:ok, _status} -> :ok
              {:error, {:already_registered, _winner}} -> :ok
              {:error, _reason} = error -> error
            end
          else
            {:error, :not_found} -> {:error, :not_found}
            {:error, _reason} = error -> error
          end
      end
    end
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

      protected =
        uri
        |> raw_persisted_caps()
        |> Enum.filter(&(Capability.action_of(&1) == :self_license))

      merged =
        derived
        |> Enum.concat(protected)
        |> Enum.reduce(MapSet.new(caps), &replace_by_identity(&2, &1))

      {:ok, MapSet.to_list(merged)}
    else
      protected =
        uri
        |> raw_persisted_caps()
        |> Enum.filter(&(Capability.action_of(&1) == :self_license))

      merged = Enum.reduce(protected, MapSet.new(caps), &replace_by_identity(&2, &1))
      {:ok, MapSet.to_list(merged)}
    end
  end

  defp raw_persisted_caps(uri) do
    if user_uri?(uri), do: UserStore.load(uri), else: snapshot_caps(uri)
  end

  defp issued_for?(
         %Capability{signature: signature, key_id: key_id, grantee_uri: %URI{} = grantee},
         uri
       )
       when is_binary(signature) and byte_size(signature) > 0 and is_binary(key_id) and
              byte_size(key_id) > 0,
       do: Ezagent.URI.stable_key(grantee) == Ezagent.URI.stable_key(uri)

  defp issued_for?(_cap, _uri), do: false

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

  defp verified(caps, uri) do
    verified = caps |> verified_set(uri) |> MapSet.to_list()

    if Enum.any?(verified, &current_self_license?(&1, uri)), do: verified, else: []
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp current_self_license?(%Capability{} = cap, uri) do
    Capability.action_of(cap) == :self_license and
      Ezagent.Cap.Authority.verify_against_current(cap, uri, uri)
  end

  defp current_self_license?(_cap, _uri), do: false

  defp user_uri?(%URI{scheme: "entity"} = uri), do: Ezagent.URI.type?(uri, :user)
  defp user_uri?(_uri), do: false

  defp parse_uri(%URI{} = uri), do: Ezagent.URI.instance(uri)
  defp parse_uri(uri) when is_binary(uri), do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance()

  defp normalize_dispatch_result(:ok), do: :ok
  defp normalize_dispatch_result({:ok, _result}), do: :ok
  defp normalize_dispatch_result({:error, _reason} = error), do: error
  defp normalize_dispatch_result(other), do: {:error, {:unexpected_persist_result, other}}
end
