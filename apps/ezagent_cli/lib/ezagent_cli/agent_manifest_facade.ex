defmodule EzagentCli.AgentManifestFacade do
  @moduledoc """
  CLI facade for spawning an agent from an `Ezagent.AgentManifest`.

  This is a facade because manifest spawn creates a new Agent Kind through the
  existing template spawn path; there is no pre-existing Agent instance to
  dispatch a Behavior action against.
  """

  @doc """
  Load a manifest file and spawn its agent through
  `Ezagent.Entity.Agent.spawn_from_manifest/6`.
  """
  @spec spawn_manifest_facade(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def spawn_manifest_facade(parsed, opts \\ [])

  def spawn_manifest_facade(parsed, opts) when is_map(parsed) and is_list(opts) do
    options = Map.get(parsed, :options, %{})

    with {:ok, manifest_path} <- fetch_string(options, :manifest),
         {:ok, manifest_body} <- File.read(manifest_path),
         {:ok, manifest} <- Ezagent.AgentManifest.load(manifest_body),
         {:ok, slots} <- decode_slots(Map.get(options, :slots)),
         {:ok, agent_uri} <- parse_agent_uri(Map.get(options, :agent)),
         {:ok, spawned_by} <- caller_uri(),
         {:ok, workspace_uri} <- agent_workspace_uri(agent_uri),
         {:ok, result} <-
           Ezagent.Entity.Agent.spawn_from_manifest(
             manifest,
             slots,
             agent_uri,
             spawned_by,
             workspace_uri,
             spawn_opts(opts)
           ) do
      {:ok, render_result(agent_uri, result)}
    end
  end

  def spawn_manifest_facade(_parsed, _opts), do: {:error, :invalid_spawn_manifest_args}

  defp spawn_opts(opts) do
    case Keyword.fetch(opts, :spawn_fun) do
      {:ok, spawn_fun} -> [spawn_fun: spawn_fun]
      :error -> []
    end
  end

  defp fetch_string(options, key) do
    case Map.get(options, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end

  defp decode_slots(nil), do: {:ok, %{}}
  defp decode_slots(""), do: {:ok, %{}}

  defp decode_slots(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = slots} -> {:ok, slots}
      {:ok, other} -> {:error, {:invalid_slots_json, other}}
      {:error, reason} -> {:error, {:invalid_slots_json, reason}}
    end
  end

  defp decode_slots(_other), do: {:error, :invalid_slots_arg}

  defp parse_agent_uri(%URI{} = uri) do
    if Ezagent.URI.type?(uri, :agent) do
      {:ok, uri}
    else
      {:error, {:invalid_agent_uri, URI.to_string(uri)}}
    end
  end

  defp parse_agent_uri(value) when is_binary(value) and value != "" do
    value
    |> Ezagent.URI.new!()
    |> parse_agent_uri()
  rescue
    ArgumentError -> {:error, {:bad_agent_uri, value}}
  end

  defp parse_agent_uri(_value), do: {:error, {:missing_option, :agent}}

  defp caller_uri do
    case Process.get(:ezagent_cli_caller_override) do
      {%URI{} = uri, _caps} -> {:ok, uri}
      _ -> {:error, :no_identity}
    end
  end

  defp agent_workspace_uri(%URI{} = agent_uri) do
    case Ezagent.URI.workspace_name(agent_uri) do
      {:ok, workspace} -> {:ok, Ezagent.URI.workspace(workspace)}
      :error -> {:error, {:invalid_agent_workspace, URI.to_string(agent_uri)}}
    end
  end

  defp render_result(%URI{} = agent_uri, result) when is_map(result) do
    %{
      agent_uri: URI.to_string(agent_uri),
      chosen_flavor: Map.get(result, :chosen_flavor),
      fresh?: Map.get(result, :fresh?),
      workers: stringify_uris(Map.get(result, :workers, []))
    }
  end

  defp stringify_uris(uris) when is_list(uris), do: Enum.map(uris, &stringify_uri/1)
  defp stringify_uris(_), do: []

  defp stringify_uri(%URI{} = uri), do: URI.to_string(uri)
  defp stringify_uri(other), do: to_string(other)
end
