defmodule Ezagent.PluginLoom.Template.LoomWorker do
  @moduledoc """
  Loom worker Template Class (loom v0.2, G-E) — pure-spawn, no PTY.

  Mirrors `Ezagent.PluginLoom.Template.LoomAgent`: satisfies the flavor
  declaration the `:ezagent_plugin_check` gate requires, and is the
  fallback creation path for `loomworker_*` agents.

  ## Template data shape

      %{
        "class" => "loom.worker",
        "agent_uri" => "entity://agent/<workspace>/loomworker_<name>",
        # optional per-slot theme injected by the SessionTemplate (G-F):
        "system_prompt" => "...",   # overrides the generic worker prompt
        "role" => "政策侧" | "企业侧" | ...
      }

  ## Idempotency

  `SpawnRegistry.spawn_detailed/1` returns `:already_started` for a live
  Kind; re-running `instantiate/3` is then a no-op. The 3-element
  `{:ok, uris, %{fresh?: _}}` return reports whether THIS call started
  the worker (reconciler contract).
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "loom.worker"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "loom.worker"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "loomworker" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "loomworker"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/loomworker_<name>`"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/loomworker_<name>`"}}

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
          "loom.worker: SpawnRegistry.spawn_detailed failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
        )

        {:error, {:agent_spawn_failed, reason}}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri),
    do: {:error, {:invalid_template, tmpl}}
end
