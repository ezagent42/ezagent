defmodule Ezagent.EntityCaps.SnapshotStore do
  @moduledoc false

  import Ecto.Query

  alias Ezagent.Ecto.KindSnapshot
  alias EzagentCore.Repo

  @doc false
  @spec load(URI.t()) :: {:ok, [Ezagent.Capability.t()]} | :not_found | {:error, term()}
  def load(%URI{} = uri) do
    case Repo.get(KindSnapshot, URI.to_string(Ezagent.URI.instance(uri))) do
      nil -> :not_found
      row -> decode_caps(row)
    end
  end

  @doc false
  @spec heal_exact(URI.t(), Ezagent.Capability.t(), Ezagent.Capability.t()) ::
          :replaced | :no_match | {:error, term()}
  def heal_exact(
        %URI{} = uri,
        %Ezagent.Capability{} = expected,
        %Ezagent.Capability{} = replacement
      ) do
    if Ezagent.Cap.signed_and_valid?(replacement, uri) do
      canonical = uri |> Ezagent.URI.instance() |> URI.to_string()

      case Repo.transaction(fn -> heal_locked(canonical, expected, replacement) end) do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_cap_artifact}
    end
  end

  defp heal_locked(canonical, expected, replacement) do
    row =
      from(snapshot in KindSnapshot,
        where: snapshot.uri == ^canonical,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case row do
      nil ->
        :no_match

      row ->
        with {:ok, state} <- KindSnapshot.decode_state(row),
             {:ok, caps, put_caps} <- caps_lens(state),
             {:ok, healed} <- replace_exact(caps, expected, replacement) do
          persist(row, put_caps.(healed))
        else
          :no_match -> :no_match
          {:error, :identity_caps_missing} -> :no_match
          {:error, _reason} = error -> error
        end
    end
  end

  defp decode_caps(row) do
    with {:ok, state} <- KindSnapshot.decode_state(row),
         {:ok, caps, _put_caps} <- caps_lens(state) do
      {:ok, caps}
    end
  end

  defp replace_exact(caps, expected, replacement) do
    expected_key = Ezagent.Capability.identity_key(expected)

    same_identity =
      Enum.filter(caps, fn cap ->
        match?(%Ezagent.Capability{}, cap) and
          Ezagent.Capability.identity_key(cap) == expected_key
      end)

    if same_identity == [expected] do
      {:ok, Enum.map(caps, fn cap -> if cap === expected, do: replacement, else: cap end)}
    else
      :no_match
    end
  end

  defp persist(row, state) do
    binary =
      state
      |> Ezagent.Kind.Snapshot.strip_transients()
      |> :erlang.term_to_binary()

    row
    |> Ecto.Changeset.change(
      state_binary: binary,
      version: row.version + 1,
      updated_at: DateTime.utc_now()
    )
    |> Repo.update()
    |> case do
      {:ok, _row} -> :replaced
      {:error, reason} -> {:error, reason}
    end
  end

  defp caps_lens(state) when is_map(state) do
    with {:ok, identity_key, identity} <- fetch_with_key(state, :identity),
         true <- is_map(identity),
         {:ok, state_key, inner} <- inner_state(identity),
         {:ok, caps_key, caps_value} <- fetch_with_key(inner, :caps),
         {:ok, caps, restore} <- normalize_caps(caps_value) do
      put_caps = fn healed ->
        updated_inner = Map.put(inner, caps_key, restore.(healed))

        updated_identity =
          case state_key do
            nil -> updated_inner
            key -> Map.put(identity, key, updated_inner)
          end

        Map.put(state, identity_key, updated_identity)
      end

      {:ok, caps, put_caps}
    else
      :error -> {:error, :identity_caps_missing}
      {:error, _reason} = error -> error
      false -> {:error, :invalid_identity_slice}
    end
  end

  defp caps_lens(_state), do: {:error, :invalid_snapshot_state}

  defp inner_state(identity) do
    case fetch_with_key(identity, :state) do
      {:ok, key, nested} when is_map(nested) -> {:ok, key, nested}
      {:ok, _key, _nested} -> {:error, :invalid_identity_state}
      :error -> {:ok, nil, identity}
    end
  end

  defp normalize_caps(%MapSet{} = caps),
    do: {:ok, MapSet.to_list(caps), fn healed -> MapSet.new(healed) end}

  defp normalize_caps(caps) when is_list(caps), do: {:ok, caps, & &1}
  defp normalize_caps(_caps), do: {:error, :invalid_identity_caps}

  defp fetch_with_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, key, Map.fetch!(map, key)}

      Map.has_key?(map, Atom.to_string(key)) ->
        string_key = Atom.to_string(key)
        {:ok, string_key, Map.fetch!(map, string_key)}

      true ->
        :error
    end
  end
end
