defmodule Ezagent.Socialware.ConfigStore do
  @moduledoc """
  Immutable config objects plus high-layer cascade pointers for SW-UPD.

  A config update writes a new object, then repoints a high layer to the new id.
  Rollback is the same repoint operation aimed at a prior retained object.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Ezagent.Socialware.{ConfigObject, ConfigPointer}
  alias EzagentCore.Repo

  @layers ~w(workspace user session)

  @type write_result :: %{
          required(:config_id) => String.t(),
          required(:object) => ConfigObject.t(),
          required(:pointer) => ConfigPointer.t(),
          required(:previous_config_id) => String.t() | nil
        }

  @spec write_config(map()) :: {:ok, ConfigObject.t()} | {:error, Ecto.Changeset.t()}
  def write_config(attrs) when is_map(attrs) do
    attrs
    |> object_attrs()
    |> ConfigObject.changeset()
    |> Repo.insert()
  end

  @spec write_and_point(map()) :: {:ok, write_result()} | {:error, term()}
  def write_and_point(attrs) when is_map(attrs) do
    object_attrs = object_attrs(attrs)

    Multi.new()
    |> Multi.insert(:object, ConfigObject.changeset(object_attrs))
    |> Multi.run(:pointer, fn _repo, %{object: object} ->
      put_pointer(Map.put(attrs, :config_id, object.id))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{object: object, pointer: %{pointer: pointer, previous_config_id: previous}}} ->
        {:ok,
         %{config_id: object.id, object: object, pointer: pointer, previous_config_id: previous}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @spec put_pointer(map()) ::
          {:ok, %{pointer: ConfigPointer.t(), previous_config_id: String.t() | nil}}
          | {:error, term()}
  def put_pointer(attrs) when is_map(attrs) do
    attrs = pointer_attrs(attrs)

    with %ConfigObject{} <-
           Repo.get(ConfigObject, Map.fetch!(attrs, :config_id)) || {:error, :config_not_found} do
      previous =
        attrs.layer
        |> ConfigPointer.id(attrs.workspace_uri, attrs.subject_uri, attrs.key)
        |> then(&Repo.get(ConfigPointer, &1))

      previous_config_id = if previous, do: previous.config_id
      attrs = Map.put(attrs, :previous_config_id, previous_config_id)

      attrs
      |> ConfigPointer.changeset()
      |> Repo.insert(
        on_conflict:
          {:replace, [:config_id, :previous_config_id, :pointed_by, :source_turn_id, :updated_at]},
        conflict_target: :id
      )
      |> case do
        {:ok, pointer} -> {:ok, %{pointer: pointer, previous_config_id: previous_config_id}}
        {:error, _changeset} = error -> error
      end
    end
  end

  @spec resolve(atom() | String.t(), URI.t() | String.t(), URI.t() | String.t(), String.t()) ::
          {:ok, ConfigObject.t()} | :none
  def resolve(layer, workspace_uri, subject_uri, key) do
    layer = normalize_layer!(layer)
    workspace = uri_string!(workspace_uri)
    subject = uri_string!(subject_uri)

    pointer =
      Repo.one(
        from(p in ConfigPointer,
          where:
            p.layer == ^layer and p.workspace_uri == ^workspace and p.subject_uri == ^subject and
              p.key == ^key
        )
      )

    case pointer do
      %ConfigPointer{config_id: config_id} -> {:ok, get!(config_id)}
      nil -> :none
    end
  end

  @spec resolve!(atom() | String.t(), URI.t() | String.t(), URI.t() | String.t(), String.t()) ::
          ConfigObject.t()
  def resolve!(layer, workspace_uri, subject_uri, key) do
    case resolve(layer, workspace_uri, subject_uri, key) do
      {:ok, object} -> object
      :none -> raise KeyError, key: {layer, workspace_uri, subject_uri, key}, term: __MODULE__
    end
  end

  @spec get!(String.t()) :: ConfigObject.t()
  def get!(config_id), do: Repo.get!(ConfigObject, config_id)

  @doc """
  Fetch an immutable config object by id.

  Returns `{:ok, object}` or `:none` (no such object). Used by
  `Ezagent.Socialware.ConfigProjection.resolve_config_dir/1` to materialize the
  SPECIFIC immutable object an object-keyed cascade-layer URI names.
  """
  @spec fetch_object(String.t()) :: {:ok, ConfigObject.t()} | :none
  def fetch_object(object_id) when is_binary(object_id) do
    case Repo.get(ConfigObject, object_id) do
      %ConfigObject{} = object -> {:ok, object}
      nil -> :none
    end
  end

  @spec merge_delta(
          atom() | String.t(),
          URI.t() | String.t(),
          URI.t() | String.t(),
          String.t(),
          map()
        ) ::
          map()
  def merge_delta(layer, workspace_uri, subject_uri, key, patch) when is_map(patch) do
    base =
      case resolve(layer, workspace_uri, subject_uri, key) do
        {:ok, object} -> object.body
        :none -> %{}
      end

    Map.merge(base, stringify_keys(patch))
  end

  defp object_attrs(attrs) do
    %{
      id: Map.get(attrs, :id) || Ecto.UUID.generate(),
      workspace_uri: attrs |> Map.fetch!(:workspace_uri) |> uri_string!(),
      subject_uri: attrs |> Map.fetch!(:subject_uri) |> uri_string!(),
      key: Map.fetch!(attrs, :key),
      body: attrs |> Map.fetch!(:body) |> stringify_keys(),
      created_by: attrs |> Map.fetch!(:actor_uri) |> uri_string!(),
      source_turn_id: Map.fetch!(attrs, :source_turn_id)
    }
  end

  defp pointer_attrs(attrs) do
    layer = attrs |> Map.fetch!(:layer) |> normalize_layer!()
    workspace_uri = attrs |> Map.fetch!(:workspace_uri) |> uri_string!()
    subject_uri = attrs |> Map.fetch!(:subject_uri) |> uri_string!()
    key = Map.fetch!(attrs, :key)

    %{
      id: ConfigPointer.id(layer, workspace_uri, subject_uri, key),
      layer: layer,
      workspace_uri: workspace_uri,
      subject_uri: subject_uri,
      key: key,
      config_id: Map.fetch!(attrs, :config_id),
      pointed_by: attrs |> Map.fetch!(:actor_uri) |> uri_string!(),
      source_turn_id: Map.fetch!(attrs, :source_turn_id)
    }
  end

  defp normalize_layer!(layer) when is_atom(layer),
    do: layer |> Atom.to_string() |> normalize_layer!()

  defp normalize_layer!(layer) when is_binary(layer) and layer in @layers, do: layer

  defp normalize_layer!(other),
    do: raise(ArgumentError, "invalid socialware config layer: #{inspect(other)}")

  defp uri_string!(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string!(uri) when is_binary(uri) and uri != "", do: uri

  defp uri_string!(other),
    do: raise(ArgumentError, "expected URI or URI string, got: #{inspect(other)}")

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {string_key!(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value

  defp string_key!(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key!(key) when is_binary(key), do: key
  defp string_key!(key), do: raise(ArgumentError, "invalid config key: #{inspect(key)}")
end
