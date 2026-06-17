defmodule Ezagent.PluginLoom.Template.LoomSalespersonSubWorker do
  @moduledoc """
  Salesperson sub-worker Template Class (2026-06-12) — pure-spawn, no PTY.

  Mirrors `Ezagent.PluginLoom.Template.LoomWorker`: satisfies the flavor
  declaration the `:ezagent_plugin_check` gate requires and is the fallback
  creation path for `loomsalespersonsub_*` agents. Spawned in bulk by
  `EzagentPluginLoom.Team.ensure_team/2`.
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "loom.salespersonsub"

  @impl Ezagent.Kind.Template
  def validate(%{"class" => "loom.salespersonsub", "agent_uri" => uri}) when is_binary(uri) and uri != "",
    do: :ok

  def validate(%{"class" => "loom.salespersonsub"}), do: {:error, :missing_agent_uri}
  def validate(%{"class" => other}), do: {:error, {:wrong_class, other}}
  def validate(_), do: {:error, :missing_class_field}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
    agent_uri = URI.parse(uri_str)

    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
      {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
      {:error, reason} ->
        Logger.warning(
          "loom.salespersonsub: spawn_detailed failed for #{URI.to_string(agent_uri)}: #{inspect(reason)}"
        )

        {:error, {:agent_spawn_failed, reason}}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}
end
