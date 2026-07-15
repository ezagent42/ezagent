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
          {:ok, {:no_match, current}}
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
                           {:ok, [Ezagent.Capability.t()]} | {:error, term()})) ::
          :ok | {:error, term()}
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
        with {:ok, result} <- fun.(decode_caps(row.caps_json)),
             {return_value, caps} <- normalize_update_result(result),
             encoded <- caps |> Enum.map(&Ezagent.Capability.to_map/1) |> Jason.encode!(),
             {:ok, _row} <-
               row |> Ecto.Changeset.change(caps_json: encoded) |> Repo.update() do
          return_value
        end
    end
  end

  defp decode_caps(nil), do: []
  defp decode_caps(""), do: []

  defp decode_caps(json) do
    case Jason.decode(json) do
      {:ok, caps} when is_list(caps) -> Enum.map(caps, &Ezagent.Capability.from_map/1)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp normalize_update_result({return_value, caps}) when is_list(caps),
    do: {return_value, caps}

  defp normalize_update_result(caps) when is_list(caps), do: {:ok, caps}
end
