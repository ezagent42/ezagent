defmodule Ezagent.ProviderConnection.AuthorityBoundaryTest do
  use ExUnit.Case, async: true

  defmodule Detector do
    @moduledoc false

    @provider_connection Ezagent.ActionSet.ProviderConnection
    @user Ezagent.Entity.User

    def scan_source(source, path) do
      ast = Code.string_to_quoted!(source, file: path, columns: true)
      aliases = aliases(ast)
      provider_action_set? = provider_action_set?(ast)
      capability_registry_imported? = capability_registry_imported?(ast, aliases)

      {_ast, findings} =
        Macro.prewalk(ast, [], fn
          {:use, meta, [kind, options]} = node, acc when is_list(options) ->
            finding =
              if resolve(kind, aliases) == Ezagent.Kind and
                   Keyword.get(options, :pattern) == :resource,
                 do: [site(:live_resource_kind, path, meta)],
                 else: []

            {node, finding ++ acc}

          {{:., _, [registry, function]}, meta, args} = node, acc
          when function in [:register, :register_owned, :unregister] and is_list(args) ->
            finding = registration_finding(registry, args, aliases, path, meta)
            {node, finding ++ acc}

          {function, meta, args} = node, acc
          when capability_registry_imported? and
                 function in [:register, :register_owned, :unregister] and is_list(args) ->
            finding =
              registration_finding(Ezagent.CapabilityRegistry, args, aliases, path, meta)

            {node, finding ++ acc}

          {:action, meta, [_action, options]} = node, acc when is_list(options) ->
            finding =
              if provider_action_set?,
                do: action_finding(options, aliases, path, meta),
                else: []

            {node, finding ++ acc}

          node, acc ->
            {node, acc}
        end)

      findings |> Enum.uniq() |> Enum.sort()
    end

    defp registration_finding(registry, [kind, _action, action_set | _rest], aliases, path, meta) do
      if resolve(registry, aliases) == Ezagent.CapabilityRegistry and
           resolve(action_set, aliases) == @provider_connection and
           resolve(kind, aliases) != @user do
        [site(:non_user_management_target, path, meta)]
      else
        []
      end
    end

    defp registration_finding(_registry, _args, _aliases, _path, _meta), do: []

    defp provider_action_set?(ast) do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {:defmodule, _, [module, _body]} = node, found? ->
            {node, found? or resolve(module, %{}) == @provider_connection}

          node, found? ->
            {node, found?}
        end)

      found?
    end

    defp capability_registry_imported?(ast, aliases) do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {:import, _, [module | _options]} = node, found? ->
            {node, found? or resolve(module, aliases) == Ezagent.CapabilityRegistry}

          node, found? ->
            {node, found?}
        end)

      found?
    end

    defp action_finding(options, aliases, path, meta) do
      options
      |> Keyword.get(:caps, [])
      |> List.wrap()
      |> Enum.flat_map(fn
        {_action, cap_options} when is_list(cap_options) ->
          if Keyword.get(cap_options, :kind) == :user,
            do: [],
            else: [site(:non_user_cap_kind, path, meta)]

        {:__aliases__, _, _parts} = action_set ->
          if resolve(action_set, aliases) == @provider_connection,
            do: [],
            else: []

        _other ->
          []
      end)
    end

    defp aliases(ast) do
      {_ast, aliases} =
        Macro.prewalk(ast, %{}, fn
          {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes} | _options]} =
              node,
          acc ->
            aliases =
              if Enum.all?(prefix, &is_atom/1) do
                Enum.reduce(suffixes, acc, fn
                  {:__aliases__, _, suffix}, aliases when is_list(suffix) ->
                    if Enum.all?(suffix, &is_atom/1),
                      do: Map.put(aliases, List.last(suffix), Module.concat(prefix ++ suffix)),
                      else: aliases

                  _other, aliases ->
                    aliases
                end)
              else
                acc
              end

            {node, aliases}

          {:alias, _, [{:__aliases__, _, parts} | options]} = node, acc
          when is_list(parts) ->
            if Enum.all?(parts, &is_atom/1) do
              short =
                case Keyword.get(options, :as) do
                  {:__aliases__, _, [name]} -> name
                  nil -> List.last(parts)
                end

              {node, Map.put(acc, short, Module.concat(parts))}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      aliases
    end

    defp resolve({:__aliases__, _, [short]}, aliases),
      do: Map.get(aliases, short, Module.concat([short]))

    defp resolve({:__aliases__, _, parts}, _aliases) when is_list(parts) do
      if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
    end

    defp resolve(atom, _aliases) when is_atom(atom), do: atom
    defp resolve(_other, _aliases), do: nil

    defp site(category, path, meta), do: {category, path, Keyword.get(meta, :line, 0)}
  end

  @repo_root Path.expand("../../../..", __DIR__)
  @production_glob Path.join(@repo_root, "apps/*/lib/**/*.ex")

  test "live Kinds are never resources and ProviderConnection is User-bound" do
    violations =
      @production_glob
      |> Path.wildcard()
      |> Enum.flat_map(fn path -> Detector.scan_source(File.read!(path), path) end)

    assert violations == []
  end

  test "ProviderConnection declares only exact User capabilities and User ownership" do
    for {_action, capability} <- Ezagent.ActionSet.ProviderConnection.required_caps() do
      assert capability.kind == :user
    end

    assert Ezagent.ActionSet.ProviderConnection.data_owner(Ezagent.URI.user("acme", "owner")) ==
             Ezagent.URI.user("acme", "owner")

    assert Ezagent.ActionSet.ProviderConnection.data_owner(
             Ezagent.URI.agent("acme", "not-an-owner")
           ) == :no_owner
  end

  test "detector catches live Resource Kinds and non-User management bindings" do
    source = """
    defmodule ForbiddenResource do
      use Ezagent.Kind, pattern: :resource, supervisor: Probe.Supervisor
    end

    defmodule ForbiddenBinding do
      alias Ezagent.ActionSet.ProviderConnection
      alias Ezagent.CapabilityRegistry
      alias Ezagent.Entity.Agent
      def bind, do: CapabilityRegistry.register_owned(Agent, :refresh, ProviderConnection)
    end
    """

    findings = Detector.scan_source(source, "fixture.ex")
    assert Enum.any?(findings, &match?({:live_resource_kind, "fixture.ex", _}, &1))
    assert Enum.any?(findings, &match?({:non_user_management_target, "fixture.ex", _}, &1))
  end

  test "detector catches an imported non-User management binding" do
    source = """
    defmodule ForbiddenImportedBinding do
      alias Ezagent.{CapabilityRegistry, URI}
      import CapabilityRegistry
      alias Ezagent.ActionSet.ProviderConnection
      alias Ezagent.Entity.Agent
      def bind, do: register_owned(Agent, :refresh, ProviderConnection)
    end
    """

    assert [{:non_user_management_target, "fixture.ex", _line}] =
             Detector.scan_source(source, "fixture.ex")
  end

  test "detector catches a grouped-alias remote non-User management binding" do
    source = """
    defmodule ForbiddenGroupedBinding do
      alias Ezagent.{CapabilityRegistry, ActionSet.ProviderConnection, Entity.Agent}
      def bind, do: CapabilityRegistry.register_owned(Agent, :refresh, ProviderConnection)
    end
    """

    assert [{:non_user_management_target, "fixture.ex", _line}] =
             Detector.scan_source(source, "fixture.ex")
  end

  test "detector catches a ProviderConnection action declared on a non-User kind" do
    source = """
    defmodule Ezagent.ActionSet.ProviderConnection do
      action(:refresh,
        args: {:closed_map, %{}},
        caps: [{:refresh, kind: :agent}],
        data_owner: :self
      )
    end
    """

    assert [{:non_user_cap_kind, "fixture.ex", _line}] =
             Detector.scan_source(source, "fixture.ex")
  end

  test "detector permits the exact User registration" do
    source = """
    defmodule LegalBinding do
      alias Ezagent.ActionSet.ProviderConnection
      alias Ezagent.CapabilityRegistry
      alias Ezagent.Entity.User
      def bind, do: CapabilityRegistry.register_owned(User, :refresh, ProviderConnection)
    end
    """

    assert Detector.scan_source(source, "legal.ex") == []
  end
end
