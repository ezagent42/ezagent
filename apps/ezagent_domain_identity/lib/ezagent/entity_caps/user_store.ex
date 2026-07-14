defmodule Ezagent.EntityCaps.UserStore do
  @moduledoc false

  import Ecto.Query

  alias EzagentCore.Repo

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

  @spec persist(URI.t(), [Ezagent.Capability.t()]) :: :ok | {:error, term()}
  def persist(%URI{} = uri, caps) when is_list(caps) do
    __MODULE__.update(uri, fn _current -> {:ok, caps} end)
  end

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
        with {:ok, caps} <- fun.(decode_caps(row.caps_json)),
             encoded <- caps |> Enum.map(&Ezagent.Capability.to_map/1) |> Jason.encode!(),
             {:ok, _row} <-
               row |> Ecto.Changeset.change(caps_json: encoded) |> Repo.update() do
          :ok
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
end
