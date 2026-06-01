defmodule Ezagent.PluginLoom.Template.LoomV0Worker do
  @moduledoc """
  Loom v0worker Template Class — pure-spawn, mirrors
  `Ezagent.PluginLoom.Template.LoomWorker`. Satisfies the flavor
  declaration the `:ezagent_plugin_check` gate requires for the `loomv0`
  flavor.

  ## Template data shape

      %{
        "class" => "loom.v0worker",
        "agent_uri" => "entity://agent/<workspace>/loomv0_<name>"
      }

  Idempotent (`SpawnRegistry.spawn_detailed/1` returns
  `:already_started` for a live Kind). See
  `docs/loom/2026-06-01-loom-as-session-redesign.md` §3.2.
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "loom.v0worker"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "loom.v0worker"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "loomv0" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "loomv0"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/loomv0_<name>`"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/loomv0_<name>`"}}

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
          "loom.v0worker: SpawnRegistry.spawn_detailed failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
        )

        {:error, {:agent_spawn_failed, reason}}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri),
    do: {:error, {:invalid_template, tmpl}}
end
