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

  @doc "Create an idempotency identifier for one principal-creation attempt."
  @spec new_attempt_id() :: Ecto.UUID.t()
  def new_attempt_id, do: Ecto.UUID.generate()

  @doc "Append one immutable child-to-parent provenance fact."
  @spec record_derivation_edge(
          URI.t() | String.t(),
          URI.t() | String.t(),
          edge_kind(),
          String.t()
        ) :: :ok | {:error, term()}
  def record_derivation_edge(child_uri, parent_uri, edge_kind, attempt_id)
      when (is_atom(edge_kind) or is_binary(edge_kind)) and is_binary(attempt_id) and
             attempt_id != "" do
    case record_derivation_edge_with_status(child_uri, parent_uri, edge_kind, attempt_id) do
      {:ok, _status} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec record_derivation_edge_with_status(
          URI.t() | String.t(),
          URI.t() | String.t(),
          edge_kind(),
          String.t()
        ) :: {:ok, :inserted | :exists} | {:error, term()}
  def record_derivation_edge_with_status(child_uri, parent_uri, edge_kind, attempt_id)
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
        if exact_fact?(edge, attrs),
          do: {:ok, :exists},
          else: {:error, :derivation_edge_conflict}

      nil ->
        insert_fact(attrs)
    end
  end

  @doc "Return the cycle-safe transitive closure over every recorded edge kind."
  @spec descendants(URI.t() | String.t()) :: [URI.t()]
  def descendants(root_uri) do
    root = uri_string(root_uri)

    [root]
    |> closure(MapSet.new([root]), MapSet.new(), :all)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(&Ezagent.URI.new!/1)
  end

  @doc false
  @spec ownership_descendants(URI.t() | String.t()) :: [URI.t()]
  def ownership_descendants(root_uri) do
    root = uri_string(root_uri)

    [root]
    |> ownership_closure(MapSet.new([root]), MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map(&Ezagent.URI.new!/1)
  end

  defp ownership_closure([], _seen, descendants), do: descendants

  defp ownership_closure(frontier, seen, descendants) do
    children = ownership_children(frontier)
    unseen = Enum.reject(children, &MapSet.member?(seen, &1))
    next_seen = Enum.reduce(unseen, seen, &MapSet.put(&2, &1))
    next_descendants = Enum.reduce(unseen, descendants, &MapSet.put(&2, &1))
    traversable = Enum.filter(unseen, &ownership_traversable?/1)
    ownership_closure(traversable, next_seen, next_descendants)
  end

  # A derived user owns their own later work; deleting that user's creator must
  # not jump through the user and revoke it. Likewise, a workspace ownership
  # edge transfers the workspace record, not every agent merely hosted there.
  defp ownership_traversable?(uri_string) do
    case Ezagent.URI.new!(uri_string) do
      %URI{scheme: "entity"} = uri -> Ezagent.URI.type?(uri, :agent)
      %URI{scheme: scheme} when scheme in ["session", "template"] -> true
      _ -> false
    end
  end

  defp ownership_children(frontier) do
    direct = ["created_by", "spawned_by", "creation_root"]

    candidate_edges =
      Repo.all(
        from edge in __MODULE__,
          where:
            edge.parent_uri in ^frontier and
              (edge.edge_kind in ^direct or like(edge.edge_kind, "ownership_transfer:%"))
      )

    candidate_children = candidate_edges |> Enum.map(& &1.child_uri) |> Enum.uniq()
    latest_transfers = latest_transfer_ids(candidate_children)

    candidate_edges
    |> Enum.filter(&current_ownership_edge?(&1, latest_transfers))
    |> Enum.map(& &1.child_uri)
    |> Enum.uniq()
  end

  defp latest_transfer_ids([]), do: %{}

  defp latest_transfer_ids(candidate_children) do
    Repo.all(
      from edge in __MODULE__,
        where:
          edge.child_uri in ^candidate_children and
            like(edge.edge_kind, "ownership_transfer:%"),
        select: {edge.child_uri, edge.id}
    )
    |> Enum.reduce(%{}, fn {child_uri, id}, acc ->
      Map.update(acc, child_uri, id, &max(&1, id))
    end)
  end

  defp current_ownership_edge?(%__MODULE__{edge_kind: "created_by", child_uri: child}, latest),
    do: not Map.has_key?(latest, child)

  defp current_ownership_edge?(%__MODULE__{edge_kind: kind, child_uri: child, id: id}, latest) do
    cond do
      kind in ["spawned_by", "creation_root"] -> true
      String.starts_with?(kind, "ownership_transfer:") -> Map.get(latest, child) == id
      true -> false
    end
  end

  defp closure([], _seen, descendants, _edge_kinds), do: descendants

  defp closure(frontier, seen, descendants, edge_kinds) when is_list(frontier) do
    children =
      edge_kinds
      |> child_query(frontier)
      |> Repo.all()

    unseen = Enum.reject(children, &MapSet.member?(seen, &1))
    next_seen = Enum.reduce(unseen, seen, &MapSet.put(&2, &1))
    next_descendants = Enum.reduce(unseen, descendants, &MapSet.put(&2, &1))
    closure(unseen, next_seen, next_descendants, edge_kinds)
  end

  defp child_query(:all, frontier) do
    from edge in __MODULE__,
      where: edge.parent_uri in ^frontier,
      select: edge.child_uri,
      distinct: true
  end

  defp existing(child_uri, edge_kind) do
    Repo.get_by(__MODULE__, child_uri: child_uri, edge_kind: edge_kind)
  end

  defp insert_fact(attrs) do
    insert_opts = if Repo.in_transaction?(), do: [mode: :savepoint], else: []

    %__MODULE__{}
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint([:child_uri, :edge_kind],
      name: :derivation_edges_child_uri_edge_kind_index
    )
    |> Repo.insert(insert_opts)
    |> case do
      {:ok, _edge} ->
        {:ok, :inserted}

      {:error, %Ecto.Changeset{errors: [child_uri: {_message, _meta}]}} ->
        case existing(attrs.child_uri, attrs.edge_kind) do
          %__MODULE__{} = edge when edge.parent_uri == attrs.parent_uri -> {:ok, :exists}
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
