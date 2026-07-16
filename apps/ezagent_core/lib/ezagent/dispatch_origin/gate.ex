defmodule Ezagent.DispatchOrigin.Gate do
  @moduledoc """
  Build-time source inventory for dispatch provenance.

  The gate parses every product Elixir source containing a dispatch envelope or
  dispatch call. Envelope defaults are deliberately unstamped; every product
  constructor must explicitly choose one of the two positive values. The sole
  product exception is the Feishu HTTP webhook path, which deliberately passes
  `nil` into the shared dispatcher and is rejected until transport
  authentication is implemented.
  """

  @positive [:authenticated_external, :trusted_internal]
  @dynamic_origin_sites ["inbound_dispatcher.ex", "ezagent/router.ex"]

  @type finding :: {String.t(), pos_integer(), term()}

  @doc false
  @spec check_source(String.t(), String.t()) :: [finding()]
  def check_source(source, path \\ "fixture.ex") when is_binary(source) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, ast} ->
        {_ast, findings} = Macro.prewalk(ast, [], &inspect_node(&1, &2, path))
        Enum.reverse(findings)

      {:error, error} ->
        [{path, 1, {:parse_error, error}}]
    end
  end

  @doc false
  @spec inventory([String.t()]) :: %{
          dispatches: non_neg_integer(),
          constructors: non_neg_integer()
        }
  def inventory(paths) do
    Enum.reduce(paths, %{dispatches: 0, constructors: 0}, fn path, counts ->
      source = File.read!(path)

      %{
        dispatches:
          counts.dispatches +
            occurrences(source, ["Router.dispatch(", "Invocation.dispatch("]),
        constructors:
          counts.constructors +
            occurrences(source, ["%Cmd{", "%Ezagent.Cmd{", "%Invocation{", "%Ezagent.Invocation{"])
      }
    end)
  end

  defp inspect_node({:%, meta, [module_ast, {:%{}, _, fields}]} = node, findings, path) do
    if envelope_constructor?(module_ast, fields) do
      case Keyword.fetch(fields, :origin) do
        {:ok, origin} when origin in @positive ->
          {node, findings}

        {:ok, {:origin, _, _} = other} ->
          if Enum.any?(@dynamic_origin_sites, &String.ends_with?(path, &1)) do
            {node, findings}
          else
            {node, [{path, meta[:line] || 1, {:invalid_origin, other}} | findings]}
          end

        {:ok, nil} ->
          {node, [{path, meta[:line] || 1, :unstamped_origin} | findings]}

        {:ok, other} ->
          {node, [{path, meta[:line] || 1, {:invalid_origin, other}} | findings]}

        :error ->
          {node, [{path, meta[:line] || 1, :missing_origin} | findings]}
      end
    else
      {node, findings}
    end
  end

  defp inspect_node(node, findings, _path), do: {node, findings}

  defp envelope_constructor?(module_ast, fields) do
    if Keyword.keyword?(fields) do
      keys = fields |> Keyword.keys() |> MapSet.new()

      case module_name(module_ast) do
        :Cmd -> MapSet.subset?(MapSet.new([:target, :action, :args, :ctx]), keys)
        :Invocation -> MapSet.subset?(MapSet.new([:target, :mode, :args, :ctx]), keys)
        _ -> false
      end
    else
      false
    end
  end

  defp module_name({:__aliases__, _, parts}), do: List.last(parts)
  defp module_name(_module), do: nil

  defp occurrences(source, needles) do
    Enum.reduce(needles, 0, fn needle, total ->
      total + max(length(String.split(source, needle)) - 1, 0)
    end)
  end
end
