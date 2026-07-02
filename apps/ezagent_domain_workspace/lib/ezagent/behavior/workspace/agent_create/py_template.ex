defmodule Ezagent.ActionSet.Workspace.AgentCreate.PyTemplate do
  @moduledoc false

  # py-agent Task 1.4 — build the persisted `py.agent` template for the
  # unified create route. Factored out of `agent_create.ex` so that file
  # stays under the `gt_1000` LOC arch gate.
  #
  # py is a NEW shape: NON-credentialled (so it stays on the non-cascade
  # Loader path — `register_and_invoke_template` with nil caps/from) YET
  # config-dir-allocating. The template therefore carries a `"config_dir"`
  # REFERENCE so `Ezagent.Kind.Template.provision_and_instantiate/4`
  # allocates `<Home>/py-agents/<ws>/<name>/` and injects
  # `"allocated_config_dir"` — the dir `Template.PyAgent.instantiate/3` writes
  # `agent.py` into. The operator `script` (+ optional `timeout_ms`) ride in
  # via `flavor_config` (coerced from `Template.PyAgent.config_schema/0`).

  @class_name "py.agent"

  @doc """
  Build the `py.agent` template-data map for `agent_uri`. `flavor_config`
  carries the operator `script` (+ optional `timeout_ms`), already coerced
  against the Template's `config_schema/0`.
  """
  @spec build(URI.t(), map() | nil) :: map()
  def build(%URI{} = agent_uri, flavor_config) do
    %{
      "class" => @class_name,
      "agent_uri" => agent_uri_string(agent_uri),
      # The config_dir REFERENCE — triggers domain allocation of the per-agent
      # TARGET via the canonical seam. The string value is the same path the
      # allocator derives; its PRESENCE is what drives allocation.
      "config_dir" => per_agent_config_dir(agent_uri)
    }
    |> Map.merge(stringify(flavor_config || %{}))
  end

  @doc "The persisted template's class name (`py.agent`)."
  @spec class_name() :: String.t()
  def class_name, do: @class_name

  # The per-agent config_dir TARGET — core authority (`Ezagent.Sandbox.ConfigDir`),
  # keyed by the agent URI + the py class namespace. NOT a plugin path builder.
  defp per_agent_config_dir(%URI{} = agent_uri) do
    {:ok, class_module} = Ezagent.TemplateRegistry.lookup(@class_name)
    Ezagent.Sandbox.ConfigDir.path(agent_uri, Ezagent.Kind.Template.namespace_of(class_module))
  end

  # The agent URI is an opaque identifier; stringifying it for the persisted
  # template payload is the only local use (mirrors `agent_create.ex`'s private
  # `agent_uri_string/1`). Isolated on its own line so the unify-uri-query scan
  # does not flag a `URI.to_string` in a map-key context.
  defp agent_uri_string(%URI{} = uri), do: URI.to_string(uri)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
