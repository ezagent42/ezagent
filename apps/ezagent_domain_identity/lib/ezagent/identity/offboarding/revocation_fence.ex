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

  @doc "Durably enroll principals before any generation bump begins."
  @spec enroll([URI.t() | String.t()]) :: :ok | {:error, term()}
  def enroll(uris) when is_list(uris) do
    # #1627 B1-hybrid: the genesis admin (authority root) is structurally
    # un-killable — an offboarding fence on it is a SOFT kill (it blocks the
    # root authority rotation would brick bootstrap. Reject enrolling the root.
    if Enum.any?(uris, &admin_uri?/1) do
      {:error, :root_authority_immutable}
    else
      do_enroll(uris)
    end
  end

  defp admin_uri?(uri) do
    Ezagent.URI.stable_key(uri_to_instance(uri)) ==
      Ezagent.URI.stable_key(Ezagent.Entity.User.admin_uri())
  rescue
    _ -> false
  end

  defp uri_to_instance(%URI{} = uri), do: Ezagent.URI.instance(uri)

  defp uri_to_instance(uri) when is_binary(uri),
    do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance()

  defp do_enroll(uris) do
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

  @doc "Return true when authority use must fail closed for the principal."
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

  @doc "Clear one fence only after that principal's durable invalidation commits."
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

  @doc "List principals whose revocation fence remains uncleared."
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
