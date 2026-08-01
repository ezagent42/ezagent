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

  @doc false
  @spec active(String.t()) :: %__MODULE__{} | nil
  def active(uri) when is_binary(uri) do
    from(row in __MODULE__, where: row.uri == ^uri and row.active == true)
    |> Repo.one()
  end

  @doc false
  # Take a row-level `FOR SHARE` lock on the URI's CURRENT active generation
  # WITHIN the caller's open transaction, then return it (`nil` when there is
  # no active row). `FOR SHARE` (not `FOR KEY SHARE`) is required: `regenesis`
  # retires the active row with `retire_active/1` — an `UPDATE ... SET active`
  # that takes a `FOR NO KEY UPDATE` lock, which `FOR KEY SHARE` does NOT
  # conflict with but `FOR SHARE` does. Holding this lock therefore blocks a
  # concurrent generation rotation until the caller commits, so a self-license
  # verified against this generation cannot be silently invalidated between the
  # verify and the caller's dependent write (#189 PR-2 verify/write race, codex
  # impl-review finding 1). MUST be called inside a `Repo.transaction/1` — a
  # `FOR SHARE` outside an explicit transaction is released instantly and locks
  # nothing.
  @spec lock_active(String.t()) :: %__MODULE__{} | nil
  def lock_active(uri) when is_binary(uri) do
    from(row in __MODULE__, where: row.uri == ^uri and row.active == true, lock: "FOR SHARE")
    |> Repo.one()
  end

  @doc false
  @spec active_public(String.t()) ::
          %{generation: pos_integer(), public_key: binary()} | nil
  def active_public(uri) when is_binary(uri) do
    from(row in __MODULE__,
      where: row.uri == ^uri and row.active == true,
      select: %{
        generation: row.generation,
        public_key: row.public_key
      }
    )
    |> Repo.one()
  end

  @doc false
  @spec list(String.t()) :: [%__MODULE__{}]
  def list(uri) when is_binary(uri) do
    from(row in __MODULE__, where: row.uri == ^uri, order_by: [asc: row.generation])
    |> Repo.all()
  end

  @doc false
  # #189 PR-3 FIX 3 — the DISTINCT set of every URI that has authority history
  # (any generation, active OR retired). The cutover backfill enumerates this to
  # adopt an absent-store-row authority-history URI as `revoked_unprovisioned`
  # (the durable ever-created witness that survives a store-row deletion).
  @spec all_uris() :: [String.t()]
  def all_uris do
    from(row in __MODULE__, select: row.uri, distinct: true)
    |> Repo.all()
  end

  @doc false
  @spec lock_all_active() :: [%__MODULE__{}]
  def lock_all_active do
    from(row in __MODULE__,
      where: row.active == true,
      order_by: [asc: row.uri],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  @doc false
  @spec replace_anchor(%__MODULE__{}, binary()) ::
          {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def replace_anchor(%__MODULE__{} = row, anchor) when is_binary(anchor) do
    row
    |> Ecto.Changeset.change(anchor: anchor)
    |> Repo.update()
  end

  @doc false
  @spec with_key_id(String.t()) :: %__MODULE__{} | nil
  def with_key_id(key_id) when is_binary(key_id) do
    from(row in __MODULE__, where: row.key_id == ^key_id)
    |> Repo.one()
  end

  @doc false
  @spec list_key_material() :: [{String.t(), binary()}]
  def list_key_material do
    from(row in __MODULE__, select: {row.key_id, row.public_key})
    |> Repo.all()
  end

  @doc false
  @spec insert(map()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def insert(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint([:uri, :generation],
      name: :kind_cap_authorities_pkey
    )
    |> Ecto.Changeset.unique_constraint([:uri, :generation],
      name: :kind_cap_authorities_uri_generation_index
    )
    |> Ecto.Changeset.unique_constraint(:uri,
      name: :kind_cap_authorities_one_active_per_uri
    )
    |> Repo.insert()
  end

  @doc false
  @spec retire_active(String.t()) :: :ok
  def retire_active(uri) when is_binary(uri) do
    from(row in __MODULE__, where: row.uri == ^uri and row.active == true)
    |> Repo.update_all(set: [active: false])

    :ok
  end
end
