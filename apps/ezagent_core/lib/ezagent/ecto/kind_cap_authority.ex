defmodule Ezagent.Ecto.KindCapAuthority do
  @moduledoc """
  Append-only durable custody record for one per-Kind authority generation.

  Runtime and plugin code have no delete API. Reincarnation retires an active
  row and appends a new generation; historical rows remain sealed.
  """

  use Ecto.Schema
  import Ecto.Query

  alias EzagentCore.Repo

  @primary_key false
  schema "kind_cap_authorities" do
    field :uri, :string, primary_key: true
    field :generation, :integer, primary_key: true
    field :kind_type, :string
    field :key_id, :string
    field :public_key, :binary
    field :private_key, :binary, redact: true
    field :anchor, :binary
    field :sealed, :boolean, default: true
    field :active, :boolean, default: true
    field :inserted_at, :utc_datetime_usec
  end

  @spec active(String.t()) :: %__MODULE__{} | nil
  def active(uri) when is_binary(uri) do
    from(row in __MODULE__, where: row.uri == ^uri and row.active == true)
    |> Repo.one()
  end

  @spec list(String.t()) :: [%__MODULE__{}]
  def list(uri) when is_binary(uri) do
    from(row in __MODULE__, where: row.uri == ^uri, order_by: [asc: row.generation])
    |> Repo.all()
  end

  @spec insert(map()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def insert(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint([:uri, :generation])
    |> Ecto.Changeset.unique_constraint(:uri,
      name: :kind_cap_authorities_one_active_per_uri
    )
    |> Repo.insert()
  end

  @spec retire_active(String.t()) :: :ok
  def retire_active(uri) when is_binary(uri) do
    from(row in __MODULE__, where: row.uri == ^uri and row.active == true)
    |> Repo.update_all(set: [active: false])

    :ok
  end
end
