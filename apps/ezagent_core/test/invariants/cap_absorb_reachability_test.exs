defmodule Ezagent.Invariants.CapAbsorbReachabilityTest do
  @moduledoc """
  S3 I2/I8 reachability gate: absorb is a VM-internal, same-node store action.
  It accepts only a structurally born-signed artifact for the receiver and
  never issues authority itself. Cryptographic authorization remains solely at
  the target Kind verifier.
  """
  use ExUnit.Case, async: true

  @same_beam_producers [
    "apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex",
    "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex",
    "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex"
  ]

  @same_beam_route_files [
    "apps/ezagent_domain_identity/lib/ezagent/identity.ex",
    "apps/ezagent_actor/lib/ezagent/router.ex",
    "apps/ezagent_actor/lib/ezagent/invocation.ex",
    "apps/ezagent_actor/lib/ezagent/kind_registry.ex",
    "apps/ezagent_actor/lib/ezagent/pending_delivery.ex",
    "apps/ezagent_actor/lib/ezagent/kind/ready_transition.ex"
  ]

  @cross_node_markers [":rpc.", ":erpc.", "Node."]

  test "absorb is provenance-gated, structurally stores, and never self-issues" do
    source = identity_source()
    [_, absorb_section] = String.split(source, "def handle_absorb_cap", parts: 2)
    [absorb_section | _] = String.split(absorb_section, "def handle_revoke_cap", parts: 2)

    assert absorb_section =~ "%{caller: :vm_internal}"
    assert absorb_section =~ "Ezagent.Cap.storable_for?(cap_struct"
    assert absorb_section =~ "def handle_absorb_cap(_args, _ctx), do: {:error, :unauthorized}"
    refute absorb_section =~ "Cap.issue"
  end

  test "Phase 3 contains no cross-node absorb transport" do
    root = repo_root()

    violations =
      root
      |> Path.join("apps/**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/test/"))
      |> Enum.reject(&EzagentCore.AstScan.tmp_fixture?/1)
      |> Enum.filter(fn file ->
        source = File.read!(file)

        source =~ "absorb_cap" and
          Enum.any?(@cross_node_markers, &String.contains?(source, &1))
      end)

    assert violations == []
  end

  test "all Phase-3 delegated producers issue locally and reach absorb only through the facade" do
    root = repo_root()

    facade =
      root
      |> Path.join("apps/ezagent_domain_identity/lib/ezagent/identity.ex")
      |> File.read!()

    Enum.each(@same_beam_producers, fn relative ->
      producer = root |> Path.join(relative) |> File.read!()

      assert producer =~ "Ezagent.Cap.issue(", "#{relative} must ISSUE before hand-off"
      assert producer =~ "Ezagent.Identity.absorb_cap(", "#{relative} must use the sole facade"
      refute producer =~ "handle_absorb_cap("
      refute producer =~ "Ezagent.Identity.Grant.grant_cap("

      Enum.each(@cross_node_markers, fn marker ->
        refute producer =~ marker,
               "#{relative} contains cross-node marker #{marker}; Phase 4 crypto is required first"
      end)
    end)

    assert facade =~ "def absorb_cap("
    assert facade =~ "caller: :vm_internal"
    assert facade =~ "mode: :cast"
    assert facade =~ "reply: :ignore"

    Enum.each(@cross_node_markers, fn marker ->
      refute facade =~ marker,
             "Identity.absorb_cap facade contains cross-node marker #{marker}"
    end)
  end

  test "the absorb route is pinned to local Router, Registry, and ETS primitives" do
    root = repo_root()

    sources =
      @same_beam_route_files
      |> Kernel.++(@same_beam_producers)
      |> Enum.uniq()
      |> Map.new(fn relative ->
        {relative, root |> Path.join(relative) |> File.read!()}
      end)

    assert sources["apps/ezagent_domain_identity/lib/ezagent/identity.ex"] =~
             "Router.dispatch(cmd)"

    assert sources["apps/ezagent_actor/lib/ezagent/router.ex"] =~ "Invocation.dispatch()"
    assert sources["apps/ezagent_actor/lib/ezagent/invocation.ex"] =~ "KindRegistry.lookup"
    assert sources["apps/ezagent_actor/lib/ezagent/kind_registry.ex"] =~ "Registry.lookup"
    assert sources["apps/ezagent_actor/lib/ezagent/pending_delivery.ex"] =~ ":ets."
    assert sources["apps/ezagent_actor/lib/ezagent/pending_delivery.ex"] =~ "[node()]"

    violations =
      Map.new(sources, fn {relative, source} ->
        {relative, remote_transport_fingerprints(source)}
      end)
      |> Map.reject(fn {_relative, fingerprints} -> fingerprints == [] end)

    assert violations == %{},
           "I8 same-BEAM route gained a remote send/call primitive: #{inspect(violations, pretty: true)}"
  end

  test "the I8 scanner catches direct, apply, capture, and registered-name remote routes" do
    fingerprints =
      remote_transport_fingerprints("""
      :rpc.call(node(), Mod, :run, [])
      Kernel.apply(:erpc, :call, [node(), Mod, :run, []])
      Function.capture(Node, :spawn, 2)
      GenServer.call({:remote_server, node()}, :request)
      send({:remote_mailbox, node()}, :message)
      """)

    assert {:rpc, :call, 4} in fingerprints
    assert {:apply, :erpc, :call} in fingerprints
    assert {:capture, Node, :spawn} in fingerprints
    assert {GenServer, :call, :remote_target} in fingerprints
    assert {:kernel, :send, :remote_target} in fingerprints
  end

  test "the I8 scanner resolves aliases before classifying remote routes" do
    fingerprints =
      remote_transport_fingerprints("""
      alias Node, as: N
      alias Kernel, as: K
      alias Function, as: F
      alias GenServer, as: GS

      N.spawn(remote, fun)
      K.apply(N, :spawn, [remote, fun])
      F.capture(N, :spawn, 2)
      GS.call({:remote_server, remote}, :request)
      """)

    assert {Node, :spawn, 2} in fingerprints
    assert {:apply, Node, :spawn} in fingerprints
    assert {:capture, Node, :spawn} in fingerprints
    assert {GenServer, :call, :remote_target} in fingerprints
  end

  defp remote_transport_fingerprints(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, {_aliases, found}} =
      Macro.prewalk(ast, {%{}, []}, fn
        {:alias, _, [target_ast | opts]} = node, {aliases, found} ->
          aliases =
            target_ast
            |> alias_entries(opts, aliases)
            |> Enum.reduce(aliases, fn {alias_name, target}, acc ->
              Map.put(acc, alias_name, target)
            end)

          {node, {aliases, found}}

        node, {aliases, found} ->
          case remote_transport_fingerprint(node, aliases) do
            nil -> {node, {aliases, found}}
            fingerprint -> {node, {aliases, [fingerprint | found]}}
          end
      end)

    found |> Enum.reverse() |> Enum.uniq()
  end

  defp remote_transport_fingerprint({{:., _, [module_ast, function]}, _, args}, aliases)
       when is_atom(function) and is_list(args) do
    module = module_name(module_ast, aliases)

    cond do
      module in [:rpc, :erpc, Node] ->
        {module, function, length(args)}

      module in [Kernel, :erlang] and function == :apply and length(args) == 3 ->
        apply_fingerprint(args, aliases)

      module == Function and function == :capture and length(args) == 3 ->
        capture_fingerprint(args, aliases)

      module in [GenServer, Process, :erlang] and
        function in [:call, :cast, :send] and
        args != [] and remote_target_ast?(hd(args)) ->
        {module, function, :remote_target}

      true ->
        nil
    end
  end

  defp remote_transport_fingerprint({function, _, args}, aliases)
       when function in [:apply, :send, :spawn, :spawn_link] and is_list(args) do
    cond do
      function == :apply and length(args) == 3 ->
        apply_fingerprint(args, aliases)

      function == :send and length(args) == 2 and remote_target_ast?(hd(args)) ->
        {:kernel, :send, :remote_target}

      function in [:spawn, :spawn_link] and length(args) >= 4 ->
        {:kernel, function, :remote_node}

      true ->
        nil
    end
  end

  defp remote_transport_fingerprint(_node, _aliases), do: nil

  defp apply_fingerprint([module_ast, function, _args], aliases) when is_atom(function) do
    case module_name(module_ast, aliases) do
      module when module in [:rpc, :erpc, Node] -> {:apply, module, function}
      _module -> nil
    end
  end

  defp apply_fingerprint(_args, _aliases), do: nil

  defp capture_fingerprint([module_ast, function, _arity], aliases) when is_atom(function) do
    case module_name(module_ast, aliases) do
      module when module in [:rpc, :erpc, Node] -> {:capture, module, function}
      _module -> nil
    end
  end

  defp capture_fingerprint(_args, _aliases), do: nil

  defp alias_entries(
         {{:., _, [prefix_ast, :{}]}, _, suffix_asts},
         _opts,
         aliases
       )
       when is_list(suffix_asts) do
    case module_name(prefix_ast, aliases) do
      nil ->
        []

      prefix ->
        Enum.flat_map(suffix_asts, fn
          {:__aliases__, _, parts} when is_list(parts) and parts != [] ->
            target = Module.concat([prefix | parts])
            [{Module.concat([List.last(parts)]), target}]

          _unsupported_suffix ->
            []
        end)
    end
  end

  defp alias_entries(target_ast, opts, aliases) do
    case module_name(target_ast, aliases) do
      nil -> []
      target -> [{alias_module_name(target, opts), target}]
    end
  end

  defp alias_module_name(_target, [[as: as_ast]]), do: module_name(as_ast, %{})

  defp alias_module_name(target, _opts) when is_atom(target) do
    case target do
      module when module in [:rpc, :erpc] -> module
      module -> module |> Module.split() |> List.last() |> then(&Module.concat([&1]))
    end
  end

  defp module_name({:__aliases__, _, parts}, aliases) do
    module = Module.concat(parts)
    Map.get(aliases, module, module)
  end

  defp module_name(module, aliases) when is_atom(module), do: Map.get(aliases, module, module)
  defp module_name(_module, _aliases), do: nil

  # A `{registered_name, node}` destination is the OTP remote-target shape.
  # Macro AST represents literal tuples either as `{:{}, _, parts}` or as a
  # plain two-tuple when both elements are already valid AST terms.
  defp remote_target_ast?({:{}, _, [_name, _node]}), do: true
  defp remote_target_ast?({left, right}) when not is_integer(right), do: valid_ast_term?(left)
  defp remote_target_ast?(_target), do: false

  defp valid_ast_term?(term), do: is_atom(term) or is_tuple(term) or is_binary(term)

  defp identity_source do
    File.read!(
      Path.join(
        repo_root(),
        "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
      )
    )
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
