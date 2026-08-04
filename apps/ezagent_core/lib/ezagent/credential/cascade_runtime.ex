defmodule Ezagent.Credential.CascadeRuntime do
  @moduledoc """
  Runtime helpers for rebuilding cascade inputs at subprocess start.

  `respawn_template_data` persists durable URI inputs, not the runtime `cascade`
  functions. This module turns those inputs back into the `%{layer_dirs,
  source_dir_for}` structure consumed by file-flavor materializers by resolving
  current config dirs through `Ezagent.UriQuery`.
  """

  alias Ezagent.Credential.Resolver

  @doc """
  Rebuild `respawn_data["cascade"]` from `respawn_data["cascade_resolution"]`.

  Missing cascade resolution is a no-op for pre-cascade agents. When resolution is
  present, stale persisted `cascade` data is discarded and rebuilt from current
  URI attributes.
  """
  @spec rehydrate_respawn_data(URI.t(), map()) :: {:ok, map()} | {:error, term()}
  def rehydrate_respawn_data(%URI{} = agent_uri, respawn_data) when is_map(respawn_data) do
    case field(respawn_data, :cascade_resolution) do
      nil ->
        {:ok, respawn_data}

      resolution when is_map(resolution) ->
        with {:ok, inputs} <- resolver_inputs(agent_uri, respawn_data, resolution),
             {:ok, resolved} <- Resolver.resolve_layers(inputs),
             :ok <- check_approved_source(resolution, resolved.secret_source),
             {:ok, layer_dirs} <- layer_dirs(resolved.config_layers) do
          cascade = %{
            layer_dirs: layer_dirs,
            source_dir_for: &source_dir_for/1
          }

          {:ok, respawn_data |> Map.drop(["cascade", :cascade]) |> Map.put("cascade", cascade)}
        end

      other ->
        {:error, {:invalid_cascade_resolution, other}}
    end
  end

  def rehydrate_respawn_data(_agent_uri, respawn_data), do: {:ok, respawn_data}

  defp resolver_inputs(agent_uri, respawn_data, resolution) do
    with {:ok, owner_uri} <- required_uri(resolution, :owner_uri),
         {:ok, workspace_uri} <- optional_uri(resolution, :workspace_uri),
         {:ok, session_uri} <- optional_uri(resolution, :session_uri),
         {:ok, explicit_source} <- optional_uri(resolution, :explicit_source),
         {:ok, approved_source} <- optional_uri(resolution, :credential_source_uri),
         {:ok, workspace_layer_uri} <- optional_uri(resolution, :workspace_layer_uri),
         {:ok, user_layer_uri} <- optional_uri(resolution, :user_layer_uri),
         {:ok, session_layer_uri} <- optional_uri(resolution, :session_layer_uri) do
      {:ok,
       %{
         agent_uri: agent_uri,
         owner_uri: owner_uri,
         workspace_uri: workspace_uri,
         session_uri: session_uri,
         explicit_source: explicit_source || approved_source,
         workspace_layer_uri: workspace_layer_uri,
         user_layer_uri: user_layer_uri,
         session_layer_uri: session_layer_uri,
         flavor: field(respawn_data, :flavor),
         credential_source_policy: field(resolution, :credential_source_policy),
         credential_required?: field(resolution, :credential_required?) != false
       }}
    end
  end

  defp layer_dirs(config_layers) do
    Enum.reduce_while(config_layers, {:ok, []}, fn
      %{source: %URI{} = uri} = layer, {:ok, acc} ->
        case Ezagent.UriQuery.resolve(:config_dir, uri) do
          {:ok, dir} when is_binary(dir) and dir != "" ->
            {:cont, {:ok, acc ++ [layer_dir(dir, layer)]}}

          :none ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, {:cascade_config_dir_failed, uri, reason}}}
        end

      _layer, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
  end

  defp layer_dir(dir, layer) do
    %{
      dir: dir,
      protected: Map.get(layer, :protected, []),
      mandatory: Map.get(layer, :mandatory, [])
    }
  end

  defp source_dir_for(%URI{} = source), do: config_dir_for_source(source)

  defp source_dir_for(source) when is_binary(source) do
    source
    |> Ezagent.URI.new!()
    |> config_dir_for_source()
  end

  defp config_dir_for_source(%URI{} = source) do
    case Ezagent.UriQuery.resolve(:config_dir, source) do
      {:ok, dir} when is_binary(dir) and dir != "" -> {:ok, dir}
      :none -> {:error, {:source_config_dir_absent, source}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_approved_source(resolution, selected) do
    case optional_uri(resolution, :credential_source_uri) do
      {:ok, nil} ->
        :ok

      {:ok, %URI{} = approved} when is_nil(selected) ->
        {:error, {:approved_credential_source_not_selected, approved, nil}}

      {:ok, %URI{} = approved} ->
        if URI.to_string(approved) == URI.to_string(selected) do
          :ok
        else
          {:error, {:approved_credential_source_changed, approved, selected}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_uri(map, key) do
    case optional_uri(map, key) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:ok, nil} -> {:error, {:missing_cascade_resolution_uri, key}}
      {:error, _} = err -> err
    end
  end

  defp optional_uri(map, key) do
    case field(map, key) do
      %URI{} = uri -> {:ok, uri}
      value when is_binary(value) and value != "" -> {:ok, Ezagent.URI.new!(value)}
      nil -> {:ok, nil}
      other -> {:error, {:invalid_cascade_resolution_uri, key, other}}
    end
  end

  defp field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
