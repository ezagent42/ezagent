defmodule Ezagent.ProviderConnection.SecretBoundaryTest do
  use ExUnit.Case, async: true

  defmodule Detector do
    @moduledoc false

    @backend_behaviours [
      Ezagent.ProviderConnection.CredentialBackend,
      Ezagent.ProviderConnection.ProviderAuthorizationBackend
    ]
    @transport_modules [Req, Finch, HTTPoison, Tesla]
    @logger_sink_functions [
      :emergency,
      :alert,
      :critical,
      :error,
      :warning,
      :warn,
      :notice,
      :info,
      :debug,
      :log
    ]
    @generic_secret_getter ~r/\A(?:get|fetch|read|load|decrypt|unseal|unwrap|reveal|plaintext).*(?:secret|token|credential|material)|(?:secret|token|credential|material).*(?:get|fetch|read|load|decrypt|unseal|unwrap|reveal|plaintext)\z/i
    @sensitive_term ~r/(?:credential_material|plaintext|authorization_code|raw_state|raw_callback|provider_envelope|callback_envelope|provider_body|authorization_header|sensitive_sentinel)/i
    @secret_identifier ~r/(?:\Asecret\z|\Asecret_|_secret\z|_secret_)/i

    def scan_source(source, path) do
      ast = Code.string_to_quoted!(source, file: path, columns: true)

      ast
      |> modules()
      |> Enum.flat_map(&scan_module(&1, path))
      |> Enum.uniq()
      |> Enum.sort()
    end

    defp modules(ast) do
      {_ast, modules} =
        Macro.prewalk(ast, [], fn
          {:defmodule, meta, [name, [do: body]]} = node, acc ->
            {node, [{expand_alias(name), body, meta} | acc]}

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(modules)
    end

    defp scan_module({_module, body, module_meta}, path) do
      alias_map = alias_map(body)
      backend? = backend_module?(body, alias_map)
      logger_imported? = imported?(body, alias_map, Logger)

      {_body, findings} =
        Macro.prewalk(body, [], fn
          {:@, meta, [{:callback, _, [signature]}]} = node, acc ->
            name = callback_name(signature)
            finding = generic_getter_finding(name, :generic_secret_callback, meta, path)
            {node, add(finding, acc)}

          {:def, meta, [{name, _, _args}, _body]} = node, acc when is_atom(name) ->
            finding = generic_getter_finding(name, :generic_secret_getter, meta, path)
            {node, add(finding, acc)}

          {{:., _, [receiver, function]}, meta, args} = node, acc when is_list(args) ->
            findings =
              []
              |> maybe_add(
                backend? and transport_call?(receiver, alias_map),
                :backend_transport,
                meta,
                path
              )
              |> maybe_add(
                sensitive_sink?(receiver, function, args, alias_map),
                :sensitive_output,
                meta,
                path
              )

            {node, findings ++ acc}

          {:raise, meta, args} = node, acc when is_list(args) ->
            {node, maybe_add([], sensitive?(args), :sensitive_output, meta, path) ++ acc}

          {function, meta, args} = node, acc when is_atom(function) and is_list(args) ->
            finding =
              logger_imported? and function in @logger_sink_functions and sensitive?(args)

            {node, maybe_add(acc, finding, :sensitive_output, meta, path)}

          node, acc ->
            {node, acc}
        end)

      if backend? and (transport_alias?(body) or transport_import?(body, alias_map)) do
        [{:backend_transport, path, line(module_meta)} | findings]
      else
        findings
      end
    end

    defp backend_module?(body, alias_map) do
      {_body, found?} =
        Macro.prewalk(body, false, fn
          {:@, _, [{:behaviour, _, [behaviour]}]} = node, found? ->
            {node, found? or expand_alias(behaviour, alias_map) in @backend_behaviours}

          node, found? ->
            {node, found?}
        end)

      found?
    end

    defp transport_alias?(body) do
      {_body, found?} =
        Macro.prewalk(body, false, fn
          {:alias, _, arguments} = node, found? ->
            {node, found? or Enum.any?(aliases(arguments), &(&1 in @transport_modules))}

          node, found? ->
            {node, found?}
        end)

      found?
    end

    defp transport_import?(body, alias_map) do
      Enum.any?(@transport_modules, &imported?(body, alias_map, &1))
    end

    defp imported?(body, alias_map, expected_module) do
      {_body, found?} =
        Macro.prewalk(body, false, fn
          {:import, _, [module | _options]} = node, found? ->
            {node, found? or expand_alias(module, alias_map) == expected_module}

          node, found? ->
            {node, found?}
        end)

      found?
    end

    defp transport_call?(receiver, alias_map),
      do: expand_alias(receiver, alias_map) in @transport_modules

    defp sensitive_sink?(receiver, function, args, alias_map) do
      sink? =
        expand_alias(receiver, alias_map) in [Logger, IO] or
          {expand_alias(receiver, alias_map), function} in [
            {:telemetry, :execute},
            {Kernel, :inspect}
          ]

      sink? and sensitive?(args)
    end

    defp sensitive?(ast) do
      Macro.to_string(ast) =~ @sensitive_term or secret_identifier?(ast)
    end

    defp secret_identifier?(ast) do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {name, _, context} = node, found? when is_atom(name) and is_atom(context) ->
            {node, found? or Atom.to_string(name) =~ @secret_identifier}

          atom, found? when is_atom(atom) ->
            {atom, found? or Atom.to_string(atom) =~ @secret_identifier}

          node, found? ->
            {node, found?}
        end)

      found?
    end

    defp generic_getter_finding(nil, _category, _meta, _path), do: nil

    defp generic_getter_finding(name, category, meta, path) do
      if Atom.to_string(name) =~ @generic_secret_getter,
        do: {category, path, line(meta)},
        else: nil
    end

    defp callback_name({:"::", _, [{name, _, _args}, _return]}) when is_atom(name), do: name
    defp callback_name(_signature), do: nil

    defp aliases([{:__aliases__, _, parts} | _options]) do
      if Enum.all?(parts, &is_atom/1), do: [Module.concat(parts)], else: []
    end

    defp aliases([{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes} | _options]) do
      Enum.map(suffixes, fn {:__aliases__, _, suffix} -> Module.concat(prefix ++ suffix) end)
    end

    defp aliases(_arguments), do: []

    defp alias_map(body) do
      {_body, aliases} =
        Macro.prewalk(body, %{}, fn
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

    defp expand_alias(ast, alias_map \\ %{})

    defp expand_alias({:__aliases__, _, [short]}, alias_map),
      do: Map.get(alias_map, short, Module.concat([short]))

    defp expand_alias({:__aliases__, _, parts}, _alias_map) do
      if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
    end

    defp expand_alias(atom, _alias_map) when is_atom(atom), do: atom
    defp expand_alias(_other, _alias_map), do: nil

    defp maybe_add(acc, true, category, meta, path), do: [{category, path, line(meta)} | acc]
    defp maybe_add(acc, false, _category, _meta, _path), do: acc
    defp add(nil, acc), do: acc
    defp add(finding, acc), do: [finding | acc]
    defp line(meta), do: Keyword.get(meta, :line, 0)
  end

  @root Path.expand("../..", __DIR__)
  @production_glob Path.join(@root, "lib/**/*.ex")

  test "production connection domain exposes no generic secret or backend HTTP path" do
    violations =
      @production_glob
      |> Path.wildcard()
      |> Enum.flat_map(fn path -> Detector.scan_source(File.read!(path), path) end)

    assert violations == []
  end

  test "credential backend contract remains operation-bound without plaintext retrieval" do
    assert Enum.sort(Ezagent.ProviderConnection.CredentialBackend.behaviour_info(:callbacks)) ==
             Enum.sort(
               consume_lease: 1,
               lease_for_operation: 1,
               replace: 1,
               revoke: 1,
               status: 1,
               store: 1
             )
  end

  test "detector catches generic getters, backend transport, and sensitive sinks" do
    source = """
    defmodule ForbiddenBackend do
      alias Ezagent.ProviderConnection.{CredentialBackend, Operation}
      alias Req
      @behaviour CredentialBackend
      @callback decrypt_credential(map()) :: {:ok, term()}
      def get_secret(_ref), do: "sensitive_sentinel"
      def status(command) do
        Logger.error(command.credential_material)
        Req.post!("https://provider.invalid")
      end
    end
    """

    findings = Detector.scan_source(source, "fixture.ex")

    assert Enum.any?(findings, &match?({:generic_secret_callback, "fixture.ex", _}, &1))
    assert Enum.any?(findings, &match?({:generic_secret_getter, "fixture.ex", _}, &1))
    assert Enum.any?(findings, &match?({:backend_transport, "fixture.ex", _}, &1))
    assert Enum.any?(findings, &match?({:sensitive_output, "fixture.ex", _}, &1))
  end

  test "detector catches imported HTTP transport in a backend module" do
    source = """
    defmodule ForbiddenImportedTransport do
      alias Ezagent.ProviderConnection.CredentialBackend
      @behaviour CredentialBackend
      import Req, only: [post!: 2]
      def status(command), do: post!("https://provider.invalid", json: command)
    end
    """

    assert [{:backend_transport, "fixture.ex", _line}] =
             Detector.scan_source(source, "fixture.ex")
  end

  test "detector catches sensitive output through an imported Logger sink" do
    source = """
    defmodule ForbiddenImportedLogger do
      import Logger, only: [error: 1]
      def leak(secret), do: error(secret)
    end
    """

    assert [{:sensitive_output, "fixture.ex", _line}] =
             Detector.scan_source(source, "fixture.ex")
  end

  test "detector permits private crypto handed directly to the operation-bound backend" do
    source = """
    defmodule LegalBackend do
      @behaviour Ezagent.ProviderConnection.ProviderAuthorizationBackend
      def consume_callback(command), do: handoff(command)
      defp handoff(command) do
        plaintext = unseal_with(command.envelope)
        command.credential_backend.store(%{credential_material: plaintext})
      end
      defp unseal_with(envelope), do: envelope
    end
    """

    assert Detector.scan_source(source, "legal.ex") == []
  end
end
