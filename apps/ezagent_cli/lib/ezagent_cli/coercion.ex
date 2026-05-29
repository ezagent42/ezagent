defmodule EzagentCli.Coercion do
  @moduledoc """
  Convert `Ezagent.Behavior.interface/0` type declarations into Optimus
  option specs.

  Per Spec 02 §2.C type-mapping table — every type in
  `Ezagent.InterfaceValidator`'s grammar gets a corresponding Optimus
  parser + value-name + multiplicity setting.
  """

  @doc """
  Convert one (`name`, `type_spec`) pair into Optimus options keyword
  entry. Returns `{name, opts_keyword}` for `Optimus.new!/1`'s
  `:options` field.
  """
  @spec to_option(atom(), term(), keyword()) :: {atom(), keyword()}
  def to_option(name, type_spec, extra_opts \\ []) do
    base = base_for(type_spec, name)
    {name, Keyword.merge(base, extra_opts)}
  end

  defp base_for(:string, name) do
    [value_name: opt_value_name(name, "STR"), long: long(name), parser: :string]
  end

  defp base_for(:integer, name) do
    [value_name: opt_value_name(name, "INT"), long: long(name), parser: :integer]
  end

  defp base_for(:boolean, name) do
    [long: long(name)]
  end

  defp base_for(:atom, name) do
    [
      value_name: opt_value_name(name, "ATOM"),
      long: long(name),
      parser: fn s ->
        try do
          {:ok, String.to_existing_atom(s)}
        rescue
          ArgumentError -> {:error, "unknown atom: #{inspect(s)}"}
        end
      end
    ]
  end

  defp base_for(:uri, name) do
    [
      value_name: opt_value_name(name, "URI"),
      long: long(name),
      parser: fn s ->
        # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
        # with try/rescue keeping the parser's `{:error, msg}` contract.
        try do
          {:ok, Ezagent.URI.new!(s)}
        rescue
          ArgumentError -> {:error, "malformed URI: #{inspect(s)}"}
        end
      end
    ]
  end

  defp base_for(:map, name) do
    [
      value_name: opt_value_name(name, "JSON"),
      long: long(name),
      parser: fn s ->
        case Jason.decode(s) do
          {:ok, m} when is_map(m) -> {:ok, m}
          {:ok, _} -> {:error, "value must be a JSON object"}
          {:error, _} -> {:error, "invalid JSON: #{inspect(s)}"}
        end
      end
    ]
  end

  defp base_for({:list, inner_type}, name) do
    inner_base = base_for(inner_type, name)
    inner_parser = Keyword.get(inner_base, :parser, :string)

    csv_parser =
      cond do
        is_function(inner_parser, 1) ->
          fn s ->
            results = Enum.map(String.split(s, ",", trim: true), inner_parser)

            case Enum.find(results, &match?({:error, _}, &1)) do
              nil -> {:ok, Enum.map(results, fn {:ok, v} -> v end)}
              {:error, reason} -> {:error, reason}
            end
          end

        inner_parser == :string ->
          fn s -> {:ok, String.split(s, ",", trim: true)} end

        inner_parser == :integer ->
          fn s ->
            try do
              {:ok, Enum.map(String.split(s, ",", trim: true), &String.to_integer/1)}
            rescue
              ArgumentError -> {:error, "non-integer in list"}
            end
          end

        true ->
          fn s -> {:ok, String.split(s, ",", trim: true)} end
      end

    [value_name: "CSV", long: long(name), parser: csv_parser]
  end

  defp base_for({:option, inner_type}, name) do
    base_for(inner_type, name) |> Keyword.put(:required, false)
  end

  defp base_for(_other, name) do
    # Fallback: treat as JSON
    [
      value_name: opt_value_name(name, "JSON"),
      long: long(name),
      parser: fn s ->
        case Jason.decode(s) do
          {:ok, v} -> {:ok, v}
          {:error, _} -> {:error, "invalid JSON: #{inspect(s)}"}
        end
      end
    ]
  end

  defp long(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  defp opt_value_name(name, default) do
    name
    |> Atom.to_string()
    |> String.upcase()
    |> case do
      ^default -> default
      _ -> default
    end
  end

  @doc """
  Return `true` if the type spec marks the arg as flag-like (boolean,
  presence-only). Used by Optimus to put the option in `:flags` not
  `:options`.
  """
  @spec flag?(term()) :: boolean()
  def flag?(:boolean), do: true
  def flag?(_), do: false
end
