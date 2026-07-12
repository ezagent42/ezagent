defmodule Ezagent.Session.Config.Operation do
  @moduledoc "Canonical executable Session-Config operation descriptor."

  @enforce_keys [
    :name,
    :description,
    :input_schema,
    :target_scope,
    :admission_gate,
    :execute
  ]
  defstruct @enforce_keys

  @type target_scope :: :session | :workspace
  @type admission_gate ::
          :session_membership | :workspace_caps | :template_write | :operation_caps
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          target_scope: target_scope(),
          admission_gate: admission_gate(),
          execute: term()
        }

  @spec schema(t()) :: map()
  @doc "Project an operation descriptor to its transport-neutral wire schema."
  def schema(%__MODULE__{} = operation) do
    %{
      "name" => operation.name,
      "description" => operation.description,
      "inputSchema" => operation.input_schema
    }
  end
end
