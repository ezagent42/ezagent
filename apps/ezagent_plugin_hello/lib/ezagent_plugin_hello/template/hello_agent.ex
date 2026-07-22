defmodule EzagentPluginHello.Template.HelloAgent do
  @moduledoc """
  Template Class for the `"hello"` agent flavor — the host for hello's role agents
  (the orchestrator). Minimal, mirroring `Ezagent.PluginNative.Template.NativeAgent`:
  spawn on the unified `Ezagent.Entity.Agent` + record the flavor attribute.

  The role-create path (`Workspace.create_agent flavor: "hello", role: …`) spawns
  directly and does NOT call `instantiate/3` — but a flavor declaration REQUIRES a
  Template Class, and this is also the seam if a hello agent is ever created via the
  template path. It stores `flavor: "hello"` so `AgentFlavorResolver` resolves the
  right AgentBridge adapter.
  """

  @behaviour Ezagent.Kind.Template

  @impl Ezagent.Kind.Template
  def template_name, do: "hello.agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl), do: :ok
  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def config_schema, do: []

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => agent_uri_str}, _workspace_uri)
      when is_binary(agent_uri_str) do
    agent_uri = Ezagent.URI.new!(agent_uri_str)
    :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "hello")

    # derivation-edge: template-post-obligation TemplateSpawn records fresh workers
    case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri}) do
      {:ok, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
      {:error, {:already_started, _pid}} -> {:ok, [agent_uri], %{fresh?: false}}
      {:error, reason} -> {:error, reason}
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}
end
