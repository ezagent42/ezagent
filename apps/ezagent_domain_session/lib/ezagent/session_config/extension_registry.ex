defmodule Ezagent.Session.Config.ExtensionRegistry do
  @moduledoc "One-shot deterministic registry for plugin Session-Config operations."

  alias Ezagent.Session.Config.{Catalog, Extension}

  @key {__MODULE__, :operations}

  @spec assemble!([map()]) :: :ok
  @doc false
  def assemble!(extensions) when is_list(extensions) do
    if :persistent_term.get(@key, :unfrozen) != :unfrozen do
      raise ArgumentError, "SessionConfig extension registry is already frozen"
    end

    operations = extensions |> Enum.map(&Extension.normalize!/1) |> Enum.sort_by(& &1.name)
    reject_duplicates!(Catalog.core_operations() ++ operations)
    :persistent_term.put(@key, operations)
    :ok
  end

  @spec operations() :: [Ezagent.Session.Config.Operation.t()]
  @doc false
  def operations, do: :persistent_term.get(@key, [])

  @spec discover_loaded_extensions() :: [map()]
  @doc false
  def discover_loaded_extensions do
    Application.loaded_applications()
    |> Enum.map(fn {app, _description, _version} -> Application.spec(app, :mod) end)
    |> Enum.flat_map(fn
      {module, _args} ->
        if function_exported?(module, :session_config_operations, 0) do
          module.session_config_operations()
        else
          []
        end

      _ ->
        []
    end)
  end

  @doc false
  def reset_for_test! do
    if Mix.env() == :test do
      :persistent_term.erase(@key)
      :ok
    else
      raise "reset_for_test!/0 is test-only"
    end
  end

  defp reject_duplicates!(operations) do
    operations
    |> Enum.group_by(& &1.name)
    |> Enum.find(fn {_name, entries} -> length(entries) > 1 end)
    |> case do
      nil -> :ok
      {name, _} -> raise ArgumentError, "duplicate operation: #{name}"
    end
  end
end
