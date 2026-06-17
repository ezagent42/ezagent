defmodule Ezagent.PluginLoom.Template.LoomAgent do
  @moduledoc """
  Loom agent Template Class — a pure-spawn flavor (no PTY, no cwd).

  ## Why this module exists

  `Ezagent.AgentFlavorRegistry` requires every flavor declaration to
  name a `template_class` that implements `Ezagent.Kind.Template`, and
  the `:ezagent_plugin_check` gate verifies it. So the `loom` flavor
  ships this minimal class.

  In practice the workspace/LV/CLI `create_agent` path
  (`Ezagent.Behavior.Workspace.:create_agent`) routes any flavor that
  is NOT `cc`/`echo` through its `_other_flavor` clause — a direct
  `Ezagent.SpawnRegistry.spawn/1` — so this Template Class is the
  fallback creation path (e.g. a workspace `session_templates` entry),
  not the primary one for the New-agent form. Either path materializes
  the same Loom Kind.

  ## Template data shape

      %{
        "class" => "loom.agent",
        "agent_uri" => "entity://agent/<workspace>/loom_<name>"
      }

  ## Idempotency

  `SpawnRegistry.spawn_detailed/1` returns `:already_started` for a
  Kind that is already alive; re-running `instantiate/3` is then a
  no-op. The 3-element `{:ok, uris, %{fresh?: _}}` return reports
  whether THIS call started the worker.
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "loom.agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "loom.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  # Entity URIs are 3-segment `/<workspace>/<entity_name>` (SPEC v3 §3);
  # flavor lives in the entity_name prefix as `<flavor>_<rest>`.
  # loom.agent requires flavor=loom.
  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{scheme: "entity", path: "/" <> rest}} when rest != "" ->
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "loom" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "loom"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/loom_<name>`"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/loom_<name>`"}}

      _ ->
        {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
    agent_uri = Ezagent.URI.new!(uri_str)

    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, _pid} ->
        {:ok, [agent_uri], %{fresh?: true}}

      {:ok, :already_started, _pid} ->
        {:ok, [agent_uri], %{fresh?: false}}

      {:error, reason} ->
        Logger.warning(
          "loom.agent: SpawnRegistry.spawn_detailed failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)}"
        )

        {:error, {:agent_spawn_failed, reason}}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri),
    do: {:error, {:invalid_template, tmpl}}
end
