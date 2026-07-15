defmodule Ezagent.EntityCaps.UserStore do
  @moduledoc false

  import Ecto.Query

  alias EzagentCore.Repo

  @doc false
  @spec exists?(URI.t()) :: boolean()
  def exists?(%URI{} = uri), do: not is_nil(Ezagent.Users.get_by_uri(uri))

  @doc false
  @spec load(URI.t()) :: [Ezagent.Capability.t()]
  def load(%URI{} = uri) do
    case Ezagent.Users.get_by_uri(uri) do
      %{caps: caps} when is_list(caps) -> caps
      _ -> []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc false
  @spec persist(URI.t(), [Ezagent.Capability.t()]) :: :ok | {:error, term()}
  def persist(%URI{} = uri, caps) when is_list(caps) do
    __MODULE__.update(uri, fn _current -> {:ok, caps} end)
  end

  @doc false
  @spec persist_if_present(URI.t() | term(), Enumerable.t()) :: :ok | {:error, term()}
  def persist_if_present(%URI{} = uri, caps) do
    if Ezagent.URI.type?(uri, :user) and exists?(uri) do
      persist(uri, Enum.to_list(caps))
    else
      :ok
    end
  end

  def persist_if_present(_uri, _caps), do: :ok

  @doc false
  @spec heal_exact(URI.t(), Ezagent.Capability.t(), Ezagent.Capability.t()) ::
          :replaced | :no_match | {:error, term()}
  def heal_exact(
        %URI{} = uri,
        %Ezagent.Capability{} = expected,
        %Ezagent.Capability{} = replacement
      ) do
    if Ezagent.Cap.signed_and_valid?(replacement, uri) do
      __MODULE__.update(uri, fn current ->
        same_identity =
          Enum.filter(current, fn cap ->
            Ezagent.Capability.identity_key(cap) == Ezagent.Capability.identity_key(expected)
          end)

        if same_identity == [expected] do
          healed =
            Enum.map(current, fn cap -> if cap === expected, do: replacement, else: cap end)

          {:ok, {:replaced, healed}}
        else
          {:ok, {:no_write, :no_match}}
        end
      end)
      |> case do
        :replaced -> :replaced
        :no_match -> :no_match
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_cap_artifact}
    end
  end

  @doc false
  @spec update(URI.t(), ([Ezagent.Capability.t()] ->
                           {:ok, [Ezagent.Capability.t()]}
                           | {:ok, {term(), [Ezagent.Capability.t()]}}
                           | {:ok, {:no_write, term()}}
                           | {:error, term()})) ::
          term() | {:error, term()}
  def update(%URI{} = uri, fun) when is_function(fun, 1) do
    case Repo.transaction(fn -> update_locked(uri, fun) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_locked(uri, fun) do
    row =
      from(user in Ezagent.Users,
        where: user.uri == ^URI.to_string(uri),
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case row do
      nil ->
        {:error, :not_found}

      row ->
        with {:ok, current} <- decode_caps(row.caps_json),
             {:ok, result} <- fun.(current) do
          case result do
            {:no_write, return_value} ->
              return_value

            result ->
              {return_value, caps} = normalize_update_result(result)
              encoded = caps |> Enum.map(&Ezagent.Capability.to_map/1) |> Jason.encode!()

              case row |> Ecto.Changeset.change(caps_json: encoded) |> Repo.update() do
                {:ok, _row} -> return_value
                {:error, reason} -> {:error, reason}
              end
          end
        end
    end
  end

  defp decode_caps(nil), do: {:ok, []}
  defp decode_caps(""), do: {:ok, []}

  defp decode_caps(json) do
    case Jason.decode(json) do
      {:ok, caps} when is_list(caps) -> decode_cap_entries(caps)
      {:ok, other} -> {:error, {:invalid_caps_json, {:not_a_list, other}}}
      {:error, reason} -> {:error, {:invalid_caps_json, reason}}
    end
  end

  defp decode_cap_entries(caps) do
    caps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {serialized, index}, {:ok, decoded} ->
      try do
        {:cont, {:ok, [Ezagent.Capability.from_map(serialized) | decoded]}}
      rescue
        error ->
          {:halt,
           {:error, {:invalid_caps_json_entry, index, error.__struct__, Exception.message(error)}}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_update_result({return_value, caps}) when is_list(caps),
    do: {return_value, caps}

  defp normalize_update_result(caps) when is_list(caps), do: {:ok, caps}
end
