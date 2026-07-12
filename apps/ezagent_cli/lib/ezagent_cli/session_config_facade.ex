defmodule EzagentCli.SessionConfigFacade do
  @moduledoc "Thin CLI projection of the canonical Session-Config core contract."

  alias Ezagent.Session.Config.{Catalog, Operation}

  @spec register_all() :: :ok
  @doc "Register the canonical core operation set as CLI facade commands."
  def register_all do
    Enum.each(Catalog.core_operations(), fn %Operation{} = operation ->
      EzagentCli.FacadeRegistry.register(
        :session_config,
        trusted_catalog_atom(operation.name),
        fn parsed -> execute(operation.name, parsed) end,
        cli_spec(operation)
      )
    end)

    :ok
  end

  defp execute(operation_name, parsed) do
    with {:ok, principal} <- EzagentCli.Exec.authenticated_principal(),
         {:ok, target} <- target(Map.get(parsed.options, :target)) do
      args =
        parsed.options
        |> Map.drop([:target])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

      case Ezagent.Session.Config.execute(operation_name, args, principal, target) do
        :ok -> {:ok, :ok}
        {:ok, result} -> {:ok, encodable(result)}
        {:error, _} = error -> error
        result -> {:ok, encodable(result)}
      end
    end
  end

  defp target(nil), do: {:ok, nil}
  defp target(%URI{} = uri), do: {:ok, uri}

  defp target(value) when is_binary(value) do
    {:ok, Ezagent.URI.new!(value)}
  rescue
    ArgumentError -> {:error, {:invalid_target_uri, value}}
  end

  defp cli_spec(%Operation{} = operation) do
    properties = get_in(operation.input_schema, ["properties"]) || %{}

    opts =
      [target: :uri] ++
        Enum.map(properties, fn {name, schema} ->
          {trusted_catalog_atom(name), cli_type(schema)}
        end)

    %{
      opts: opts,
      about: operation.description,
      canonical_schema: Operation.schema(operation)
    }
  end

  defp cli_type(%{"type" => "string"}), do: :string
  defp cli_type(%{"type" => "integer"}), do: :integer
  defp cli_type(%{"type" => "boolean"}), do: :boolean
  defp cli_type(%{"type" => "object"}), do: :map
  defp cli_type(%{"type" => "array", "items" => %{"type" => "string"}}), do: {:list, :string}
  defp cli_type(_schema), do: :string

  # These strings come only from the frozen domain catalog, never from argv.
  # FacadeRegistry/Optimus require atom keys, so this bounded conversion is
  # safe and cannot create atoms from caller-controlled input.
  defp trusted_catalog_atom(name) when is_binary(name), do: String.to_atom(name)

  defp encodable(%URI{} = uri), do: URI.to_string(uri)
  defp encodable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encodable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encodable(%MapSet{} = value), do: value |> MapSet.to_list() |> encodable()
  defp encodable(value) when is_struct(value), do: value |> Map.from_struct() |> encodable()
  defp encodable(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, encodable(v)} end)
  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(value) when is_tuple(value), do: value |> Tuple.to_list() |> encodable()
  defp encodable(value) when is_atom(value), do: Atom.to_string(value)
  defp encodable(value), do: value
end
