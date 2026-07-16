defmodule EzagentCore.Architecture.GitAdapterBoundaryScanner do
  @moduledoc false

  @domain_root "apps/ezagent_domain_git"
  @action_set_path "apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex"
  @callbacks ~w(resolve_repository create_change_request read_change_request list_checks list_reviews)a
  @provider_names ~r/(?:GitHub|Github|GitLab|Gitlab|Bitbucket|Gitea|Forgejo)/
  @provider_deps ~r/\{:(?:req|httpoison|tesla|tentacat|github|gitlab|goth|finch)\b/i
  @forbidden_field ~r/(?:^|_)(?:token|secret|credential|client|local_path|checkout_path|request_path|working_tree_path|capability|cap)(?:_|$)/i
  @forbidden_callback ~r/\b(?:\w*(?:token|secret|credential|client|path|capability)\w*|Req(?:\.[A-Z]\w*)?|Cap(?:ability)?(?:\.[A-Z]\w*)?)\b/i

  def empty_findings do
    %{
      adapter_effects: [],
      provider_modules: [],
      provider_dependencies: [],
      forbidden_struct_fields: [],
      forbidden_callback_terms: []
    }
  end

  def scan_repository(repo_root) do
    sources =
      Path.wildcard(Path.join(repo_root, "apps/*/lib/**/*.ex"))
      |> Enum.map(fn path ->
        relative = Path.relative_to(path, repo_root)
        {relative, File.read!(path)}
      end)

    findings =
      Enum.reduce(sources, empty_findings(), fn {path, source}, acc ->
        merge(acc, scan_source(path, source))
      end)

    mix_path = Path.join(repo_root, @domain_root <> "/mix.exs")

    if File.exists?(mix_path) and File.read!(mix_path) =~ @provider_deps do
      %{findings | provider_dependencies: [Path.relative_to(mix_path, repo_root)]}
    else
      findings
    end
  end

  def scan_source(path, source) do
    ast = Code.string_to_quoted!(source, warn_on_unnecessary_quotes: false, emit_warnings: false)

    %{
      adapter_effects: adapter_effects(path, ast),
      provider_modules: provider_modules(path, ast),
      provider_dependencies: provider_dependencies(path, source),
      forbidden_struct_fields: domain_only(path, forbidden_struct_fields(path, ast)),
      forbidden_callback_terms: domain_only(path, forbidden_callback_terms(path, ast))
    }
  end

  defp adapter_effects(@action_set_path, _ast), do: []

  defp adapter_effects(path, ast) do
    aliases = aliases(ast)

    function_bodies(ast)
    |> Enum.flat_map(fn body ->
      lookup? = contains_adapter_lookup?(body, aliases)

      {_body, findings} =
        Macro.prewalk(body, [], fn node, acc ->
          if adapter_effect_call?(node, aliases, lookup?),
            do: {node, [{path, line(node)} | acc]},
            else: {node, acc}
        end)

      findings
    end)
    |> Enum.uniq()
  end

  defp provider_modules(path, ast) do
    if String.starts_with?(path, @domain_root <> "/lib/") and
         Macro.to_string(ast) =~ @provider_names do
      [path]
    else
      []
    end
  end

  defp provider_dependencies(path, source) do
    if String.ends_with?(path, "/mix.exs") and source =~ @provider_deps, do: [path], else: []
  end

  defp forbidden_struct_fields(path, ast) do
    attributes = literal_list_attributes(ast)

    {_ast, fields} =
      Macro.prewalk(ast, [], fn
        {:defstruct, _, [argument]} = node, acc ->
          expanded = expand_fields(argument, attributes)

          {node, expanded |> Enum.filter(&forbidden_field?/1) |> Kernel.++(acc)}

        node, acc ->
          {node, acc}
      end)

    fields |> Enum.uniq() |> Enum.map(&{path, &1})
  end

  defp forbidden_callback_terms(path, ast) do
    {_ast, findings} =
      Macro.prewalk(ast, [], fn
        {:@, meta, [{:callback, _, [signature]}]} = node, acc ->
          if Macro.to_string(signature) =~ @forbidden_callback,
            do: {node, [{path, Keyword.get(meta, :line, 0)} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    findings
  end

  defp aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, [short]}]]} = node, acc
        when is_list(parts) ->
          if Enum.all?(parts, &is_atom/1),
            do: {node, Map.put(acc, short, Module.concat(parts))},
            else: {node, acc}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc when is_list(parts) ->
          if Enum.all?(parts, &is_atom/1),
            do: {node, Map.put(acc, List.last(parts), Module.concat(parts))},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp adapter_effect_call?({{:., _, [receiver, name]}, _, _args}, aliases, _lookup?)
       when name in @callbacks,
       do: not declaration_introspection?(receiver, name, aliases)

  defp adapter_effect_call?(
         {{:., _, [receiver, :lookup_for_action_set]}, _, _args},
         aliases,
         _lookup?
       ),
       do: resolve_alias(receiver, aliases) == Ezagent.DomainGit.AdapterRegistry

  defp adapter_effect_call?({:lookup_for_action_set, _, args}, _aliases, _lookup?)
       when is_list(args),
       do: true

  defp adapter_effect_call?({name, _, [_, callback, _]}, _aliases, lookup?) when name == :apply,
    do: (lookup? and dynamic_function?(callback)) or dynamic_callback?(callback)

  defp adapter_effect_call?({{:., _, [module, :apply]}, _, [_, callback, _]}, aliases, lookup?),
    do:
      resolve_alias(module, aliases) in [Kernel, :erlang] and
        ((lookup? and dynamic_function?(callback)) or dynamic_callback?(callback))

  defp adapter_effect_call?(_node, _aliases, _lookup?), do: false

  defp declaration_introspection?(_receiver, _name, _aliases), do: false
  defp dynamic_callback?(callback) when callback in @callbacks, do: true

  defp dynamic_callback?({name, _, context}) when is_atom(name) and is_atom(context),
    do: name in [:callback, :action]

  defp dynamic_callback?(_callback), do: false
  defp dynamic_function?({name, _, context}) when is_atom(name) and is_atom(context), do: true
  defp dynamic_function?(_callback), do: false

  defp contains_adapter_lookup?(body, aliases) do
    {_body, found?} =
      Macro.prewalk(body, false, fn node, found? ->
        lookup? =
          case node do
            {{:., _, [receiver, :lookup_for_action_set]}, _, _args} ->
              resolve_alias(receiver, aliases) == Ezagent.DomainGit.AdapterRegistry

            {:lookup_for_action_set, _, args} when is_list(args) ->
              true

            _node ->
              false
          end

        {node, found? or lookup?}
      end)

    found?
  end

  defp resolve_alias({:__aliases__, _, [short]}, aliases),
    do: Map.get(aliases, short, Module.concat([short]))

  defp resolve_alias({:__aliases__, _, parts}, _aliases), do: Module.concat(parts)
  defp resolve_alias(atom, _aliases) when is_atom(atom), do: atom
  defp resolve_alias(_other, _aliases), do: nil

  defp literal_list_attributes(ast) do
    {_ast, attrs} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [values]}]} = node, acc when is_atom(name) and is_list(values) ->
          {node, Map.put(acc, name, Enum.filter(values, &is_atom/1))}

        node, acc ->
          {node, acc}
      end)

    attrs
  end

  defp expand_fields(fields, _attrs) when is_list(fields), do: Enum.filter(fields, &is_atom/1)

  defp expand_fields({:@, _, [{name, _, _}]}, attrs) when is_atom(name),
    do: Map.get(attrs, name, [])

  defp expand_fields({name, _, context}, attrs) when is_atom(name) and is_atom(context),
    do: Map.get(attrs, name, [])

  defp expand_fields(_other, _attrs), do: []

  defp line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp line(_node), do: 0

  defp merge(left, right) do
    Map.new(left, fn {key, values} -> {key, values ++ Map.fetch!(right, key)} end)
  end

  defp function_bodies(ast) do
    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {kind, _, [_head, [do: body]]} = node, acc when kind in [:def, :defp] ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    bodies
  end

  defp forbidden_field?(field) do
    name = Atom.to_string(field)
    name =~ @forbidden_field and not String.ends_with?(name, "_owner_uri")
  end

  defp domain_only(path, findings) do
    if String.starts_with?(path, @domain_root <> "/lib/"), do: findings, else: []
  end
end

defmodule EzagentCore.Architecture.GitAdapterBoundaryTest do
  use ExUnit.Case, async: true

  alias EzagentCore.Architecture.GitAdapterBoundaryScanner, as: Scanner

  @repo_root Path.expand("../../../..", __DIR__)

  test "adapter selection and callback execution stay in GitTaskAccess" do
    assert Scanner.scan_repository(@repo_root).adapter_effects == []
  end

  test "domain app contains no provider implementation or provider dependency" do
    findings = Scanner.scan_repository(@repo_root)
    assert findings.provider_modules == []
    assert findings.provider_dependencies == []
  end

  test "domain structs and adapter callbacks carry no effectful authority" do
    findings = Scanner.scan_repository(@repo_root)
    assert findings.forbidden_struct_fields == []
    assert findings.forbidden_callback_terms == []
  end

  describe "controlled detector fixtures" do
    @tag :tmp_dir
    test "repository traversal finds a bypass planted in another production app", %{tmp_dir: root} do
      planted = Path.join(root, "apps/ezagent_plugin_probe/lib/probe.ex")
      File.mkdir_p!(Path.dirname(planted))

      File.write!(
        planted,
        "defmodule Probe do\n  def run(impl), do: impl.list_checks(:c, :r, :s)\nend\n"
      )

      domain_mix = Path.join(root, "apps/ezagent_domain_git/mix.exs")
      File.mkdir_p!(Path.dirname(domain_mix))
      File.write!(domain_mix, "defmodule Probe.MixProject do\nend\n")

      assert Scanner.scan_repository(root).adapter_effects != []

      ignored = Path.join(root, "apps/ezagent_plugin_probe/test/not_production.exs")
      File.mkdir_p!(Path.dirname(ignored))

      File.write!(
        ignored,
        "defmodule Ignored do\n  def run(impl), do: impl.list_checks(:c, :r, :s)\nend\n"
      )

      File.rm!(planted)
      assert Scanner.scan_repository(root).adapter_effects == []
    end

    test "registry lookup or callback execution is forbidden while declaration validation is allowed" do
      lookup =
        "defmodule Ezagent.DomainGit.AdapterRegistry do\ndef run, do: lookup_for_action_set(\"x\")\nend"

      callback =
        "defmodule Ezagent.DomainGit.AdapterRegistry do\ndef run(impl), do: impl.list_checks(:c, :r, :s)\nend"

      assert Scanner.scan_source("apps/ezagent_domain_git/lib/adapter_registry.ex", lookup).adapter_effects !=
               []

      assert Scanner.scan_source("apps/ezagent_domain_git/lib/adapter_registry.ex", callback).adapter_effects !=
               []
    end

    test "positive fixtures plant every forbidden boundary crossing" do
      source = """
      defmodule Ezagent.DomainGit.GitHubClient do
        @fields [:token, :local_path]
        defstruct @fields
        @callback fetch(
                    Req.Request.t(),
                    client :: term()
                  ) :: term()
        def bypass(adapter), do: adapter.resolve_repository(:context, :repository)
        def lookup, do: Ezagent.DomainGit.AdapterRegistry.lookup_for_action_set("github")
      end
      """

      findings = Scanner.scan_source("apps/ezagent_domain_git/lib/github_client.ex", source)

      assert findings.adapter_effects != []
      assert findings.provider_modules != []
      assert findings.forbidden_struct_fields != []
      assert findings.forbidden_callback_terms != []

      dependency =
        Scanner.scan_source("apps/ezagent_domain_git/mix.exs", "def deps, do: [{:req, []}]")

      assert dependency.provider_dependencies != []
    end

    test "negative fixtures retain declaration validation and neutral values" do
      source = """
      defmodule Ezagent.DomainGit.AdapterRegistry do
        alias Ezagent.DomainGit.Adapter
        def validate(module) do
          Adapter.behaviour_info(:callbacks)
          |> Enum.all?(fn {name, arity} -> function_exported?(module, name, arity) end)
        end
      end

      defmodule Ezagent.DomainGit.RepositoryRef do
        defstruct [:repository_uri, :provider_adapter, :owner, :name]
      end
      """

      assert Scanner.scan_source(
               "apps/ezagent_domain_git/lib/ezagent/domain_git/adapter_registry.ex",
               source
             ) == Scanner.empty_findings()
    end

    test "AST teeth cover aliases and dynamic callback call shapes" do
      fixtures = [
        "alias Ezagent.DomainGit.AdapterRegistry, as: Registry\ndef run, do: Registry.lookup_for_action_set(\"x\")",
        "def run(adapter_module), do: adapter_module.list_reviews(:c, :r, :id)",
        "def run(impl, callback), do: Kernel.apply(impl, callback, [])",
        "def run(impl, callback), do: :erlang.apply(impl, callback, [])",
        "def run(registry_result, callback), do: apply(registry_result, callback, [])",
        "alias Ezagent.DomainGit.AdapterRegistry, as: Registry\ndef run(cb) do\n  {:ok, registry_result} = Registry.lookup_for_action_set(\"x\")\n  Kernel.apply(registry_result, cb, [])\nend"
      ]

      for body <- fixtures do
        source = "defmodule Outside do\n#{body}\nend"

        assert Scanner.scan_source("apps/other/lib/outside.ex", source).adapter_effects != [],
               body
      end
    end

    test "forbidden fields and signatures cover expanded attributes and compound authority names" do
      fields =
        ~w(api_token credential_ref secret_ref http_client request_path working_tree_path capability_ref)

      for field <- fields do
        source = "defmodule Value do\n@shape [:#{field}]\ndefstruct @shape\nend"

        assert Scanner.scan_source("apps/ezagent_domain_git/lib/value.ex", source).forbidden_struct_fields !=
                 []
      end

      for term <- ["Req.Request.t()", "Cap.t()", "path :: String.t()", "client :: term()"] do
        source = "defmodule Contract do\n@callback run(#{term}) :: term()\nend"

        assert Scanner.scan_source("apps/ezagent_domain_git/lib/contract.ex", source).forbidden_callback_terms !=
                 []
      end
    end
  end
end
