defmodule EzagentPluginFeishu.SourceInvariants.DispatchOnlySeedTest do
  @moduledoc """
  Handoff B1 Phase 5 — narrow source invariant: the Feishu user-binding
  seed pipeline (Application after_boot, UserBindingSeed importer,
  DispatchAdapter, and the three legacy mix wrappers) MUST NOT call raw
  storage (`EzagentPluginFeishu.UserBinding.*`), raw policy
  (`EzagentPluginFeishu.BindingPolicy.apply/2`), or raw handler
  (`EzagentPluginFeishu.Behavior.UserBinding.handle_*`) directly.

  Every mutation goes through the sanctioned `Ezagent.Cmd` →
  `Ezagent.Router.dispatch/1` boundary.

  This is a NARROW invariant — it does NOT forbid these calls in:
  - The formal Behavior itself (`behavior/user_binding.ex`) — it IS the
    handler, and it MUST call storage/policy internally.
  - Storage tests (`test/ezagent/user_binding_test.exs`) — they test
    the storage module directly.
  - The B2 World files — those are not this handoff's scope.

  The invariant is checked by grep — scan the producer files and assert
  they contain zero disallowed imports/calls.
  """
  use ExUnit.Case, async: true

  @producer_files [
    "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex",
    "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed.ex",
    "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed/parser.ex",
    "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed/dispatch_adapter.ex",
    "apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.bind.ex",
    "apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.unbind.ex",
    "apps/ezagent_plugin_feishu/lib/mix/tasks/ezagent.feishu.list.ex"
  ]

  # The three named modules that producer files must never call directly.
  # Storage: match actual CALLS (not mere mentions in moduledoc prose).
  # No exceptions — every producer file goes through the executor function
  # port or dispatch.
  @forbidden_raw_storage ~r/\bUserBinding\.(bind|unbind|resolve|list_all|open_ids_for)\b/
  # Policy (direct apply):
  @forbidden_raw_policy ~r/\bBindingPolicy\.apply\b/
  # Raw handler:
  @forbidden_raw_handler ~r/\bBV\.handle_|\bBehavior\.UserBinding\.handle_/
  @allowed_adapter_remote_modules MapSet.new([
                                    [Access],
                                    [:Application],
                                    [:Ezagent, :Cmd],
                                    [:Ezagent, :Entity, :User],
                                    [:Ezagent, :Invocation],
                                    [:Ezagent, :Router],
                                    [:Ezagent, :URI],
                                    [:MapSet],
                                    [:Mix],
                                    [:String],
                                    [:System],
                                    [:URI]
                                  ])
  @required_adapter_aliases %{
    Cmd: [:Ezagent, :Cmd],
    Invocation: [:Ezagent, :Invocation],
    Router: [:Ezagent, :Router]
  }
  defp repo_root, do: Path.expand("../../../..", __DIR__)

  # Pre-filter: exclude lines that are moduledoc prose or comments
  # (the `>` marker, backtick code-refs in docs, and `#`-prefixed comments).
  defp code_lines(content) do
    content
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "#") or
        String.starts_with?(trimmed, ">") or
        String.contains?(trimmed, "`UserBinding") or
        String.contains?(trimmed, "`BindingPolicy")
    end)
    |> Enum.with_index(1)
  end

  defp remote_calls_and_structs(content) do
    ast = Code.string_to_quoted!(content)

    {_ast, result} =
      Macro.prewalk(ast, {MapSet.new(), MapSet.new(), MapSet.new(), %{}}, fn
        {:alias, _,
         [
           {{:., _, [{:__aliases__, _, base_parts}, :{}]}, _, grouped_aliases}
         ]} = node,
        {calls, structs, imports, aliases} ->
          mappings =
            Map.new(grouped_aliases, fn {:__aliases__, _, child_parts} ->
              {List.last(child_parts), base_parts ++ child_parts}
            end)

          {node, {calls, structs, imports, Map.merge(aliases, mappings)}}

        {:alias, _, [{:__aliases__, _, target_parts} | options]} = node,
        {calls, structs, imports, aliases} ->
          short_name =
            options
            |> List.first([])
            |> Keyword.get(:as, List.last(target_parts))
            |> case do
              {:__aliases__, _, parts} -> List.last(parts)
              name -> name
            end

          {node, {calls, structs, imports, Map.put(aliases, short_name, target_parts)}}

        {:|>, _, [_input, {{:., _, [{:__aliases__, _, parts}, function]}, _, args}]} = node,
        {calls, structs, imports, aliases}
        when is_atom(function) and is_list(args) ->
          {node,
           {MapSet.put(calls, {parts, function, length(args) + 1}), structs, imports, aliases}}

        {{:., _, [{:__aliases__, _, parts}, function]}, _, args} = node,
        {calls, structs, imports, aliases}
        when is_atom(function) and is_list(args) ->
          {node, {MapSet.put(calls, {parts, function, length(args)}), structs, imports, aliases}}

        {{:., _, [module, function]}, _, args} = node, {calls, structs, imports, aliases}
        when is_atom(module) and is_atom(function) and is_list(args) ->
          {node,
           {MapSet.put(calls, {[module], function, length(args)}), structs, imports, aliases}}

        {:%, _, [{:__aliases__, _, parts}, {:%{}, _, _fields}]} = node,
        {calls, structs, imports, aliases} ->
          {node, {calls, MapSet.put(structs, parts), imports, aliases}}

        {:import, _, [{:__aliases__, _, parts} | _options]} = node,
        {calls, structs, imports, aliases} ->
          {node, {calls, structs, MapSet.put(imports, parts), aliases}}

        node, acc ->
          {node, acc}
      end)

    result
  end

  defp resolve_alias(parts, aliases) do
    case parts do
      [short_name] -> Map.get(aliases, short_name, parts)
      _ -> parts
    end
  end

  defp dynamic_bypass_sites(content) do
    ast = Code.string_to_quoted!(content)

    {_ast, sites} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, _parts}, _function]}, _, _args} = node, sites ->
          {node, sites}

        {{:., _, [module, _function]}, _, _args} = node, sites when is_atom(module) ->
          {node, sites}

        {{:., meta, [receiver, function]}, _, _args} = node, sites ->
          site = "line #{meta[:line]}: #{Macro.to_string(receiver)}.#{function}(...)"
          {node, [site | sites]}

        {:struct, meta, _args} = node, sites ->
          {node, ["line #{meta[:line]}: struct/2" | sites]}

        node, sites ->
          {node, sites}
      end)

    Enum.reverse(sites)
  end

  test "producer files never call raw storge (EzagentPluginFeishu.UserBinding)" do
    for file <- @producer_files do
      path = Path.join(repo_root(), file)
      assert File.exists?(path), "invariant producer file missing: #{file}"

      content = File.read!(path)

      forbidden_lines =
        code_lines(content)
        |> Enum.filter(fn {line, _lineno} ->
          String.match?(line, @forbidden_raw_storage)
        end)
        |> Enum.map(fn {line, lineno} -> "#{file}:#{lineno}: #{String.trim(line)}" end)

      assert forbidden_lines == [],
             "#{file} calls raw EzagentPluginFeishu.UserBinding directly — " <>
               "routes through Invocation.dispatch/1 instead:\n" <>
               Enum.join(forbidden_lines, "\n")
    end
  end

  test "producer files never call raw policy (EzagentPluginFeishu.BindingPolicy.apply)" do
    for file <- @producer_files do
      path = Path.join(repo_root(), file)
      content = File.read!(path)

      forbidden_lines =
        code_lines(content)
        |> Enum.filter(fn {line, _lineno} ->
          String.match?(line, @forbidden_raw_policy)
        end)
        |> Enum.map(fn {line, lineno} -> "#{file}:#{lineno}: #{String.trim(line)}" end)

      assert forbidden_lines == [],
             "#{file} calls BindingPolicy.apply directly — " <>
               "routes through Invocation.dispatch/1 instead:\n" <>
               Enum.join(forbidden_lines, "\n")
    end
  end

  test "producer files never call raw handler (Behavior.UserBinding.handle_*)" do
    for file <- @producer_files do
      path = Path.join(repo_root(), file)
      content = File.read!(path)

      forbidden_lines =
        code_lines(content)
        |> Enum.filter(fn {line, _lineno} ->
          String.match?(line, @forbidden_raw_handler)
        end)
        |> Enum.map(fn {line, lineno} -> "#{file}:#{lineno}: #{String.trim(line)}" end)

      assert forbidden_lines == [],
             "#{file} calls Behavior.UserBinding.handle_* directly — " <>
               "routes through Invocation.dispatch/1 instead:\n" <>
               Enum.join(forbidden_lines, "\n")
    end
  end

  test "producer files go through function port or dispatch" do
    for file <- @producer_files do
      path = Path.join(repo_root(), file)

      # Parser is a pure module — no executor needed.
      # Legacy CLI tasks are args-only — no dispatch at all.
      if String.contains?(path, "application.ex") or
           String.contains?(path, "user_binding_seed.ex") or
           String.contains?(path, "dispatch_adapter.ex") do
        content = File.read!(path)

        has_executor_or_dispatch =
          String.contains?(content, "executor_port") or
            String.contains?(content, "Invocation.dispatch") or
            String.contains?(content, "DispatchAdapter")

        assert has_executor_or_dispatch,
               "#{file} lacks function-port/dispatch wiring"
      end
    end
  end

  test "production adapter pins the reviewed admin-operator Cmd/Router seam" do
    file =
      "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/user_binding_seed/dispatch_adapter.ex"

    content = repo_root() |> Path.join(file) |> File.read!()
    {calls, structs, imports, aliases} = remote_calls_and_structs(content)
    dynamic_sites = dynamic_bypass_sites(content)

    assert aliases == @required_adapter_aliases,
           "production seed adapter aliases must retain the exact reviewed module mappings"

    assert dynamic_sites == [],
           "production seed adapter must not use dynamic remote calls or struct/2: " <>
             Enum.join(dynamic_sites, ", ")

    resolved_calls =
      MapSet.new(calls, fn {parts, function, arity} ->
        {resolve_alias(parts, aliases), function, arity}
      end)

    assert MapSet.member?(resolved_calls, {[:Ezagent, :Invocation], :with_admin_operator, 2})
    assert MapSet.member?(resolved_calls, {[:Ezagent, :Cmd], :trusted_internal, 5})
    assert MapSet.member?(resolved_calls, {[:Ezagent, :Router], :dispatch, 1})

    assert imports == MapSet.new(),
           "production seed adapter must not import modules that bypass the remote-call ratchet"

    resolved_structs = MapSet.new(structs, &resolve_alias(&1, aliases))

    assert Enum.all?(resolved_structs, &(&1 == [:URI])),
           "production seed adapter may only match or construct URI structs"

    remote_modules =
      resolved_calls
      |> Enum.reject(fn {_parts, function, _arity} -> function == :{} end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    assert MapSet.subset?(remote_modules, @allowed_adapter_remote_modules),
           "production seed adapter called a module outside the reviewed allowlist: " <>
             inspect(MapSet.difference(remote_modules, @allowed_adapter_remote_modules))
  end
end
