defmodule Ezagent.PluginLoom.Template.LoomStitchWorker do
  @moduledoc """
  Loom stitchworker Template Class — pure-spawn, mirrors
  `Ezagent.PluginLoom.Template.LoomV0Worker`. 满足 `:ezagent_plugin_check` gate 对
  `loomstitch` flavor 的声明要求。2026-06-10。

      %{ "class" => "loom.stitchworker",
         "agent_uri" => "entity://agent/<workspace>/loomstitch_<name>" }
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "loom.stitchworker"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "loom.stitchworker"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "loomstitch" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "loomstitch"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/loomstitch_<name>`"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/loomstitch_<name>`"}}

      _ ->
        {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
    agent_uri = URI.parse(uri_str)

    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, _pid} ->
        {:ok, [agent_uri], %{fresh?: true}}

      {:ok, :already_started, _pid} ->
        {:ok, [agent_uri], %{fresh?: false}}

      {:error, reason} ->
        Logger.warning(
          "loom.stitchworker: SpawnRegistry.spawn_detailed failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
        )

        {:error, {:agent_spawn_failed, reason}}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri),
    do: {:error, {:invalid_template, tmpl}}
end
