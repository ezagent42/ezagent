defmodule Ezagent.Session.Config.Catalog do
  @moduledoc "Domain-owned Session-Config operation names, schemas, and dispatch metadata."

  alias Ezagent.Session.Config.{CoreSchemas, ExtensionRegistry, Operation}

  @workspace_operations ~w(list_templates)
  @template_write_operations ~w(update_template save_template_as migrate_session)

  @spec core_operations() :: [Operation.t()]
  @doc "Return the closed core Session-Config operation set."
  def core_operations do
    Enum.map(CoreSchemas.schemas(), fn schema ->
      name = schema["name"]
      {scope, gate} = scope_and_gate(name)

      %Operation{
        name: name,
        description: schema["description"],
        input_schema: schema["inputSchema"],
        target_scope: scope,
        admission_gate: gate,
        execute: {:core, name}
      }
    end)
  end

  @spec operations() :: [Operation.t()]
  @doc "Return core operations followed by the frozen extension set."
  def operations, do: core_operations() ++ ExtensionRegistry.operations()

  @spec operation(String.t()) :: Operation.t() | nil
  @doc "Look up an assembled operation by its wire name."
  def operation(name) when is_binary(name), do: Enum.find(operations(), &(&1.name == name))

  @spec schemas() :: [map()]
  @doc "Project the assembled operation set to transport-neutral schemas."
  def schemas, do: Enum.map(operations(), &Operation.schema/1)

  @doc "Return core operation names as their existing atoms."
  @spec core_names() :: [atom()]
  def core_names, do: Enum.map(core_operations(), &String.to_existing_atom(&1.name))

  defp scope_and_gate(name) when name in @workspace_operations, do: {:workspace, :workspace_caps}

  defp scope_and_gate(name) when name in @template_write_operations,
    do: {:session, :template_write}

  defp scope_and_gate(_name), do: {:session, :session_membership}
end
