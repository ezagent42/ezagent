defmodule Ezagent.InterfaceValidator do
  @moduledoc """
  Recursive type-spec validator for `@interface` args / returns maps.

  Type-spec grammar (per ARCHITECTURE.md §6.2):
  - `:string` / `:integer` / `:boolean` / `:atom` / `:map` — primitives
  - `:term` — opaque wildcard, accepts ANY value (PR-6: the curl
    `:in_process_sync` adapter result `{:ok, %{…}} | {:error, term}` is a
    structurally-varied payload the `:sync_result` Behavior pattern-matches
    itself; the dispatch validator must not reject it). Use sparingly — a
    precise spec is preferred wherever the shape is known.
  - `:uri` — `%URI{}` struct (Phase 2: Message envelope identity fields
    are typed URIs, not bare strings — see DECISIONS §interface-validator-uri)
  - `{:struct, Module}` — an exact struct type for closed domain evidence
  - `{:list, ty}` — homogeneous list
  - `{:tuple, [ty1, ty2, ...]}` — fixed-arity tuple
  - `{:option, ty}` — `nil` or `ty`
  - `%{field => ty, ...}` — record shape (all fields required unless
    declared `{:option, _}`)

  Phase 1 validation runs inside `Ezagent.Kind.Runtime.handle_dispatch/3`
  after BehaviorRegistry lookup so we have the Behavior's `@interface`
  in hand. Failure returns `{:error, {:invalid_args, [{field, reason}]}}`
  with a violations list — adapters surface this back to the caller.
  """

  @type type_spec ::
          :string
          | :integer
          | :boolean
          | :atom
          | :map
          | :term
          | :uri
          | {:struct, module()}
          | {:list, type_spec()}
          | {:tuple, [type_spec()]}
          | {:option, type_spec()}
          | %{optional(atom()) => type_spec()}

  @type violation :: {path :: [atom()], reason :: term()}

  @doc """
  Validate `args` against `schema` (a map of `field => type_spec`).

  Returns `:ok` if every field in `schema` is present and well-typed
  in `args`; otherwise `{:error, {:invalid_args, violations}}` listing
  every problem found (so callers see all failures, not just the first).
  """
  @spec validate(map(), map()) :: :ok | {:error, {:invalid_args, [violation()]}}
  def validate(args, schema) when is_map(args) and is_map(schema) do
    violations =
      schema
      |> Enum.flat_map(fn {field, ty} ->
        case check(Map.get(args, field, :__missing__), ty, [field]) do
          :ok -> []
          {:error, vs} -> vs
        end
      end)

    case violations do
      [] -> :ok
      _ -> {:error, {:invalid_args, violations}}
    end
  end

  # --- Recursive type check ----------------------------------------------

  defp check(:__missing__, {:option, _ty}, _path), do: :ok
  defp check(:__missing__, _ty, path), do: {:error, [{path, :missing}]}

  defp check(value, :string, _path) when is_binary(value), do: :ok
  defp check(value, :integer, _path) when is_integer(value), do: :ok
  defp check(value, :boolean, _path) when is_boolean(value), do: :ok
  defp check(value, :atom, _path) when is_atom(value), do: :ok
  defp check(value, :map, _path) when is_map(value), do: :ok
  # `:term` — opaque wildcard. Accepts any value (a present field of any
  # shape). The `:__missing__` sentinel is still rejected by the
  # missing-field clause above (a `:term` field is REQUIRED unless wrapped in
  # `{:option, :term}`), so `:term` relaxes the VALUE check, not presence.
  defp check(_value, :term, _path), do: :ok
  defp check(%URI{} = _value, :uri, _path), do: :ok
  defp check(value, {:struct, module}, _path) when is_struct(value, module), do: :ok

  defp check(nil, {:option, _ty}, _path), do: :ok
  defp check(value, {:option, ty}, path), do: check(value, ty, path)

  defp check(value, {:list, ty}, path) when is_list(value) do
    violations =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, idx} ->
        case check(item, ty, path ++ [idx]) do
          :ok -> []
          {:error, vs} -> vs
        end
      end)

    if violations == [], do: :ok, else: {:error, violations}
  end

  defp check(value, {:tuple, tys}, path) when is_tuple(value) do
    if tuple_size(value) != length(tys) do
      {:error, [{path, {:expected_tuple_size, length(tys), :got, tuple_size(value)}}]}
    else
      violations =
        tys
        |> Enum.with_index()
        |> Enum.flat_map(fn {ty, idx} ->
          case check(elem(value, idx), ty, path ++ [idx]) do
            :ok -> []
            {:error, vs} -> vs
          end
        end)

      if violations == [], do: :ok, else: {:error, violations}
    end
  end

  defp check(value, ty, path) when is_map(ty) and is_map(value) do
    violations =
      ty
      |> Enum.flat_map(fn {field, inner_ty} ->
        case check(Map.get(value, field, :__missing__), inner_ty, path ++ [field]) do
          :ok -> []
          {:error, vs} -> vs
        end
      end)

    if violations == [], do: :ok, else: {:error, violations}
  end

  defp check(value, ty, path),
    do: {:error, [{path, {:type_mismatch, expected: ty, got: value}}]}

  # --- @interface action-map shape check ---------------------------------

  @doc """
  Validate a single `@interface` action map's shape.

  An action map is `%{args: map(), returns: map(), modes: [atom()]}` with
  an OPTIONAL `description:` key. The V1 UI SPEC §0 adds `description:` as
  a single source of truth for "what does this action do" (consumed by the
  CLI `tree_builder`, CmdK later). It is optional — absent is valid — but
  when present it MUST be a binary.

  Returns `:ok` if the action map is well-shaped, otherwise
  `{:error, {:invalid_interface, violations}}` where `violations` is a
  list of `{path :: [atom()], reason :: term()}` (same shape as
  `validate/2`'s violations).
  """
  @spec validate_action(map()) :: :ok | {:error, {:invalid_interface, [violation()]}}
  def validate_action(action_map) when is_map(action_map) do
    violations =
      case Map.fetch(action_map, :description) do
        {:ok, desc} when is_binary(desc) -> []
        {:ok, desc} -> [{[:description], {:type_mismatch, expected: :string, got: desc}}]
        :error -> []
      end

    case violations do
      [] -> :ok
      _ -> {:error, {:invalid_interface, violations}}
    end
  end
end
