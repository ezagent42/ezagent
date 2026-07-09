defmodule Ezagent.Routing.Trace do
  @moduledoc """
  Persistent routing decision trace for message journeys.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias EzagentCore.Repo

  @type t :: %__MODULE__{
          id: integer() | nil,
          message_id: String.t(),
          workspace_uri: String.t(),
          rule_id: String.t(),
          receivers: [String.t()],
          hop: non_neg_integer() | nil,
          drop_reason: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "routing_traces" do
    field :message_id, :string
    field :workspace_uri, :string
    field :rule_id, :string
    field :receivers, {:array, :string}, default: []
    field :hop, :integer
    field :drop_reason, :string
    field :inserted_at, :utc_datetime_usec
  end

  @doc "Record one routing decision."
  @spec record(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.update(:message_id, nil, &to_trace_string/1)
      |> Map.update(:workspace_uri, nil, &to_trace_string/1)
      |> Map.update(:rule_id, nil, &to_trace_string/1)
      |> Map.update(:drop_reason, nil, &to_trace_string/1)
      |> Map.update(:receivers, [], &Enum.map(&1, fn receiver -> to_trace_string(receiver) end))
      |> Map.put_new(:inserted_at, DateTime.utc_now())

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc "Return the recorded routing journey for a message."
  @spec journey(String.t()) :: [t()]
  def journey(message_id) when is_binary(message_id) do
    from(t in __MODULE__,
      where: t.message_id == ^message_id,
      order_by: [asc: t.inserted_at, asc: t.id]
    )
    |> Repo.all()
  end

  defp changeset(trace, attrs) do
    trace
    |> cast(attrs, [
      :message_id,
      :workspace_uri,
      :rule_id,
      :receivers,
      :hop,
      :drop_reason,
      :inserted_at
    ])
    |> validate_required([:message_id, :workspace_uri, :rule_id, :receivers, :inserted_at])
    |> validate_number(:hop, greater_than_or_equal_to: 0)
  end

  defp to_trace_string(nil), do: nil
  defp to_trace_string(%URI{} = uri), do: URI.to_string(uri)
  defp to_trace_string(value) when is_atom(value), do: Atom.to_string(value)
  defp to_trace_string(value) when is_integer(value), do: Integer.to_string(value)
  defp to_trace_string(value) when is_binary(value), do: value
end
