defmodule Ezagent.Session.Config.Extension do
  @moduledoc "Duck-typed plugin contribution contract for Session-Config operations."

  alias Ezagent.Session.Config.Operation

  @spec normalize!(Operation.t() | map()) :: Operation.t()
  @doc false
  def normalize!(%Operation{} = operation), do: operation

  def normalize!(%{} = contribution) do
    %Operation{
      name: fetch_string!(contribution, :name),
      description: fetch_string!(contribution, :description),
      input_schema: fetch_map!(contribution, :input_schema),
      target_scope: Map.get(contribution, :target_scope, :workspace),
      admission_gate: Map.get(contribution, :admission_gate, :workspace_caps),
      execute: Map.fetch!(contribution, :route)
    }
  end

  def normalize!(other), do: raise(ArgumentError, "invalid SessionConfig extension: #{inspect(other)}")

  defp fetch_string!(map, key) do
    case Map.fetch!(map, key) do
      value when is_binary(value) and value != "" -> value
      value -> raise ArgumentError, "#{key} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp fetch_map!(map, key) do
    case Map.fetch!(map, key) do
      value when is_map(value) -> value
      value -> raise ArgumentError, "#{key} must be a map, got: #{inspect(value)}"
    end
  end
end
