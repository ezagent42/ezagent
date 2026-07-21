defmodule Ezagent.Identity.Offboarding.RevocationFence do
  @moduledoc """
  Durable pending-revocation fence.

  Enrollment is the cascade's first commit. An uncleared row makes the
  principal inert at every authority-use gate before that principal's own
  generation bump lands. Rows are cleared, never deleted, so interrupted work
  remains discoverable and re-enrollment is idempotent.
  """

  use Ecto.Schema

  import Ecto.Query

  alias EzagentCore.Repo

  @primary_key {:principal_uri, :string, autogenerate: false}
  schema "revocation_fences" do
    field(:enrolled_at, :utc_datetime_usec)
    field(:cleared_at, :utc_datetime_usec)
  end

  @spec enroll([URI.t() | String.t()]) :: :ok | {:error, term()}
  def enroll(uris) when is_list(uris) do
    now = DateTime.utc_now()

    rows =
      uris
      |> Enum.map(&uri_string/1)
      |> Enum.uniq()
      |> Enum.map(&%{principal_uri: &1, enrolled_at: now, cleared_at: nil})

    case rows do
      [] ->
        :ok

      _ ->
        Repo.insert_all(__MODULE__, rows,
          on_conflict: [set: [enrolled_at: now, cleared_at: nil]],
          conflict_target: [:principal_uri]
        )

        :ok
    end
  rescue
    error -> {:error, error}
  end

  @spec fenced?(URI.t() | String.t()) :: boolean()
  def fenced?(uri) do
    principal_uri = uri_string(uri)

    Repo.exists?(
      from(fence in __MODULE__,
        where: fence.principal_uri == ^principal_uri and is_nil(fence.cleared_at)
      )
    )
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  @spec clear(URI.t() | String.t()) :: :ok | {:error, term()}
  def clear(uri) do
    principal_uri = uri_string(uri)

    from(fence in __MODULE__,
      where: fence.principal_uri == ^principal_uri and is_nil(fence.cleared_at)
    )
    |> Repo.update_all(set: [cleared_at: DateTime.utc_now()])

    :ok
  rescue
    error -> {:error, error}
  end

  @spec pending() :: [URI.t()]
  def pending do
    Repo.all(
      from(fence in __MODULE__,
        where: is_nil(fence.cleared_at),
        order_by: [asc: fence.enrolled_at, asc: fence.principal_uri],
        select: fence.principal_uri
      )
    )
    |> Enum.map(&Ezagent.URI.new!/1)
  end

  defp uri_string(%URI{} = uri), do: Ezagent.URI.stable_key(uri)

  defp uri_string(uri) when is_binary(uri),
    do: uri |> Ezagent.URI.new!() |> Ezagent.URI.stable_key()
end
