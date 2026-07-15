defmodule Ezagent.Identity.CapQuarantine do
  @moduledoc """
  Durable worklist for capability artifacts whose authority cannot be resolved.

  Rows are idempotent per holder and logical capability identity. Resolution
  tombstones a row instead of deleting it so operators retain its history while
  strict audits count only the currently open worklist.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Ezagent.Capability
  alias EzagentCore.Repo

  schema "cap_quarantine" do
    field(:workspace_uri, :string)
    field(:holder_uri, :string)
    field(:cap_identity, :string)
    field(:granted_by, :string)
    field(:class, :string)
    field(:reason, :string)
    field(:status, Ecto.Enum, values: [:open, :resolved], default: :open)
    field(:first_seen_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec record(URI.t(), Capability.t(), atom(), term()) :: :ok | {:error, term()}
  def record(%URI{} = holder_uri, %Capability{} = cap, class, reason) when is_atom(class) do
    now = DateTime.utc_now()

    attrs = %{
      workspace_uri: holder_uri |> Capability.workspace_of() |> URI.to_string(),
      holder_uri: URI.to_string(Ezagent.URI.instance(holder_uri)),
      cap_identity: identity_hash(cap),
      granted_by: uri_string(cap.granted_by),
      class: Atom.to_string(class),
      reason: inspect(reason),
      status: :open,
      first_seen_at: now,
      last_seen_at: now,
      closed_at: nil
    }

    %__MODULE__{}
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint([:holder_uri, :cap_identity],
      name: :cap_quarantine_holder_identity_index
    )
    |> Repo.insert(
      on_conflict: [
        set: [
          workspace_uri: attrs.workspace_uri,
          granted_by: attrs.granted_by,
          class: attrs.class,
          reason: attrs.reason,
          status: :open,
          last_seen_at: now,
          closed_at: nil,
          updated_at: now
        ]
      ],
      conflict_target: [:holder_uri, :cap_identity]
    )
    |> case do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec close(URI.t(), Capability.t()) :: :ok
  def close(%URI{} = holder_uri, %Capability{} = cap) do
    now = DateTime.utc_now()

    from(row in __MODULE__,
      where:
        row.holder_uri == ^URI.to_string(Ezagent.URI.instance(holder_uri)) and
          row.cap_identity == ^identity_hash(cap) and row.status == :open
    )
    |> Repo.update_all(set: [status: :resolved, closed_at: now, updated_at: now])

    :ok
  end

  @doc false
  @spec list_open() :: [t()]
  def list_open do
    from(row in __MODULE__, where: row.status == :open, order_by: [asc: row.id])
    |> Repo.all()
  end

  @doc false
  @spec list_open(URI.t()) :: [t()]
  def list_open(%URI{} = holder_uri) do
    canonical = URI.to_string(Ezagent.URI.instance(holder_uri))

    from(row in __MODULE__,
      where: row.status == :open and row.holder_uri == ^canonical,
      order_by: [asc: row.id]
    )
    |> Repo.all()
  end

  @doc false
  @spec identity_hash(Capability.t()) :: String.t()
  def identity_hash(%Capability{} = cap) do
    cap
    |> Capability.identity_key()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(Ezagent.URI.instance(uri))
  defp uri_string(other), do: inspect(other)
end
