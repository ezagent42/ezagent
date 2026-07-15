defmodule EzagentPluginHello.PublishedBoardRef do
  @moduledoc """
  Content-free reference from a published Hello website to a Kanban board.

  Kanban remains the sole board-data owner. This value carries stable identity
  and publication metadata only; copied tree/task/status payloads are rejected.
  """

  @enforce_keys [:board_uri, :source_session_uri, :receive_ref, :revision]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          board_uri: URI.t(),
          source_session_uri: URI.t(),
          receive_ref: String.t(),
          revision: pos_integer()
        }

  @forbidden_keys [:tree, :nodes, :tasks, :statuses, "tree", "nodes", "tasks", "statuses"]

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with nil <- Enum.find(@forbidden_keys, &Map.has_key?(attrs, &1)),
         {:ok, board_uri} <- parse_uri(attrs, :board_uri, "entity"),
         {:ok, source_session_uri} <- parse_uri(attrs, :source_session_uri, "session"),
         {:ok, receive_ref} <- non_empty_binary(attrs, :receive_ref),
         {:ok, revision} <- positive_integer(attrs, :revision) do
      {:ok,
       %__MODULE__{
         board_uri: board_uri,
         source_session_uri: source_session_uri,
         receive_ref: receive_ref,
         revision: revision
       }}
    else
      forbidden when forbidden in @forbidden_keys ->
        {:error, {:forbidden_board_payload, forbidden}}

      {:error, _} = error ->
        error
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :attrs}}

  @spec identity_key(t()) :: {String.t(), String.t()}
  def identity_key(%__MODULE__{} = ref) do
    {URI.to_string(ref.source_session_uri), URI.to_string(ref.board_uri)}
  end

  defp parse_uri(attrs, key, expected_scheme) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    case value do
      %URI{scheme: ^expected_scheme} = uri ->
        {:ok, uri}

      value when is_binary(value) ->
        case Ezagent.URI.parse(value) do
          {:ok, %URI{scheme: ^expected_scheme} = uri} -> {:ok, uri}
          _ -> {:error, {:invalid_uri, key}}
        end

      _ ->
        {:error, {:invalid_uri, key}}
    end
  end

  defp non_empty_binary(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, {:invalid_field, key}},
          else: {:ok, value}

      _ ->
        {:error, {:invalid_field, key}}
    end
  end

  defp positive_integer(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end
end
