defmodule Ezagent.ActionSet.LegacyCallbacks do
  @moduledoc false

  def inject(env, action_names, interface, cap_subjects, actions) do
    defined = Module.definitions_in(env.module, :def)

    legacy_required_caps =
      Enum.map(actions, fn {name, spec} ->
        {name, build_required_cap_ast(env.module, name, spec.caps)}
      end)

    cap_subjects_ast = Macro.escape(cap_subjects)
    interface_ast = Macro.escape(interface)
    action_names_ast = Macro.escape(action_names)

    []
    |> maybe_add_unless_defined(
      defined,
      :actions,
      0,
      quote do
        def actions, do: unquote(action_names_ast)
      end
    )
    |> maybe_add_unless_defined(
      defined,
      :cap_subjects,
      0,
      quote do
        def cap_subjects, do: unquote(cap_subjects_ast)
      end
    )
    |> maybe_add_unless_defined(
      defined,
      :interface,
      0,
      quote do
        def interface, do: unquote(interface_ast)
      end
    )
    |> maybe_add_unless_defined(
      defined,
      :required_caps,
      0,
      quote do
        def required_caps,
          do:
            unquote(legacy_required_caps)
            |> Map.new()
      end
    )
  end

  defp maybe_add_unless_defined(acc, defined, name, arity, ast) do
    if {name, arity} in defined do
      acc
    else
      [ast | acc]
    end
  end

  defp build_required_cap_ast(behavior_module, action_name, caps_opt) do
    first_cap =
      case caps_opt do
        [first | _] -> first
        [] -> :any
        atom when is_atom(atom) -> atom
      end

    case first_cap do
      atom when is_atom(atom) ->
        quote do
          Ezagent.Capability.cap(:any, unquote(behavior_module), unquote(atom))
        end

      {action_atom, _opts} when is_atom(action_atom) ->
        quote do
          Ezagent.Capability.cap(:any, unquote(behavior_module), unquote(action_atom))
        end

      _ ->
        quote do
          Ezagent.Capability.cap(:any, unquote(behavior_module), unquote(action_name))
        end
    end
  end
end
