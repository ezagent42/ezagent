defmodule Ezagent.Provenance.DerivationEdges do
  @moduledoc """
  Durable append-only provenance edges used by generation-revocation cascades.

  A child may have one immutable parent per edge kind and multiple edge kinds.
  `descendants/1` follows every kind to a cycle-safe fixpoint; it deliberately
  has no depth cutoff.
  """

  use Ecto.Schema

  import Ecto.Query

  alias EzagentCore.Repo

  schema "derivation_edges" do
    field :child_uri, :string
    field :parent_uri, :string
    field :edge_kind, :string
    field :attempt_id, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type edge_kind :: atom() | String.t()

  @spec new_attempt_id() :: Ecto.UUID.t()
  def new_attempt_id, do: Ecto.UUID.generate()

  @spec record_derivation_edge(
          URI.t() | String.t(),
          URI.t() | String.t(),
          edge_kind(),
          String.t()
        ) :: :ok | {:error, term()}
  def record_derivation_edge(child_uri, parent_uri, edge_kind, attempt_id)
      when (is_atom(edge_kind) or is_binary(edge_kind)) and is_binary(attempt_id) and
             attempt_id != "" do
    attrs = %{
      child_uri: uri_string(child_uri),
      parent_uri: uri_string(parent_uri),
      edge_kind: to_string(edge_kind),
      attempt_id: attempt_id
    }

    case existing(attrs.child_uri, attrs.edge_kind) do
      %__MODULE__{} = edge ->
        if exact_fact?(edge, attrs), do: :ok, else: {:error, :derivation_edge_conflict}

      nil ->
        insert_fact(attrs)
    end
  end

  @spec descendants(URI.t() | String.t()) :: [URI.t()]
  def descendants(root_uri) do
    root = uri_string(root_uri)

    [root]
    |> closure(MapSet.new([root]), MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(&Ezagent.URI.new!/1)
  end

  defp closure([], _seen, descendants), do: descendants

  defp closure(frontier, seen, descendants) when is_list(frontier) do
    children =
      Repo.all(
        from edge in __MODULE__,
          where: edge.parent_uri in ^frontier,
          select: edge.child_uri,
          distinct: true
      )

    unseen = Enum.reject(children, &MapSet.member?(seen, &1))
    next_seen = Enum.reduce(unseen, seen, &MapSet.put(&2, &1))
    next_descendants = Enum.reduce(unseen, descendants, &MapSet.put(&2, &1))
    closure(unseen, next_seen, next_descendants)
  end

  defp existing(child_uri, edge_kind) do
    Repo.get_by(__MODULE__, child_uri: child_uri, edge_kind: edge_kind)
  end

  defp insert_fact(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint([:child_uri, :edge_kind],
      name: :derivation_edges_child_uri_edge_kind_index
    )
    |> Repo.insert()
    |> case do
      {:ok, _edge} ->
        :ok

      {:error, %Ecto.Changeset{errors: [child_uri: {_message, _meta}]}} ->
        case existing(attrs.child_uri, attrs.edge_kind) do
          %__MODULE__{} = edge when edge.parent_uri == attrs.parent_uri -> :ok
          _ -> {:error, :derivation_edge_conflict}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp exact_fact?(edge, attrs) do
    edge.child_uri == attrs.child_uri and edge.parent_uri == attrs.parent_uri and
      edge.edge_kind == attrs.edge_kind
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: URI.to_string(Ezagent.URI.new!(uri))
end
