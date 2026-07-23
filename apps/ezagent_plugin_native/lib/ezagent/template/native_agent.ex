defmodule Ezagent.PluginNative.Template do
  @moduledoc """
  Template Class `native.agent` — declares a `native`-flavor agent in a
  Workspace (role-foundation RF-8).

  The `native` flavor is the generic, no-engine/no-sidecar host for role
  agents. The Template Class is deliberately minimal: it carries NO
  flavor-specific config (no provider/api_url/model/PTY) because native
  declares nothing role-specific — a native agent's behaviors + caps + sandbox
  content come from its ROLE recipe at create (RF-5a), not from this template.

  - `template_name/0` — `"native.agent"`.
  - `config_schema/0` — `[]` (no flavor config; the role supplies everything).
  - `instantiate/3` — spawns the UNIFIED `Ezagent.Entity.Agent` Kind with no
    explicit `:behaviors` set, so the instance captures the base Agent behavior
    set (`Entity.Agent.nil_capture_behavior_set/0`); the role layers its
    behaviors on per-instance via RF-5a. No external engine is started.
  """

  @behaviour Ezagent.Kind.Template

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "native.agent"

  @impl Ezagent.Kind.Template
  def config_schema, do: []

  @impl Ezagent.Kind.Template
  def validate(%{"class" => "native.agent"} = tmpl),
    do: Ezagent.Kind.Template.check_agent_uri(tmpl)

  def validate(%{"class" => other}), do: {:error, {:wrong_class, other}}
  def validate(_), do: {:error, :missing_class_field}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str} = _tmpl, _workspace_uri) do
    instantiate_with_opts(agent_uri_str, [])
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str}, _workspace_uri,
        launch_context: launch_context
      ) do
    instantiate_with_opts(agent_uri_str, launch_context: launch_context)
  end

  def instantiate(_tmpl_name, _tmpl, _workspace_uri, _opts), do: {:error, :invalid_launch_options}

  defp instantiate_with_opts(agent_uri_str, opts) do
    agent_uri = Ezagent.URI.new!(agent_uri_str)

    # native is a STORED flavor attribute (read at load via UriQuery), NOT a
    # name-segment prefix — symmetric to curl/np.
    :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "native")

    # No explicit `:behaviors` → nil `:kind_base` → the base Agent behavior
    # set. No external engine/sidecar. RF-5a layers the role's behaviors on
    # per-instance via the recipe.
    # derivation-edge: template-post-obligation TemplateSpawn records fresh workers
    case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri}, opts) do
      {:ok, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
      {:error, {:already_started, _pid}} -> {:ok, [agent_uri], %{fresh?: false}}
      {:error, reason} -> {:error, reason}
    end
  end
end
