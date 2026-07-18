defmodule Ezagent.Invariants.CapVerifyLoadBoundariesTest do
  @moduledoc """
  S4 I5 gate: storage admission is structural and bounded to the load/store
  homes, while cryptographic verification belongs only to the live target's
  central verifier.

  Boundary #3 is deliberately the durable identity-slice to dispatch-context
  loader. Born-signed artifacts use recipient-aware `storable_for?/2` or
  `verified_set/2` before entering an entity slice. These checks do not claim
  cryptographic authority; the target Kind verifies its own signature at
  dispatch.

  Git task access is the one signed-only consumption boundary: core remains in
  legacy dual-read mode, while provider effects require an exact receiver-bound
  artifact immediately before adapter selection.
  """
  use ExUnit.Case, async: true

  @identity_behavior "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
  @identity_facade "apps/ezagent_domain_identity/lib/ezagent/identity.ex"
  @entity_caps "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex"
  @recipe_cap_binding "apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex"
  @outbound_grant "apps/ezagent_domain_identity/lib/ezagent/outbound_grant.ex"
  @snapshot "apps/ezagent_core/lib/ezagent/kind/snapshot.ex"
  @cap "apps/ezagent_core/lib/ezagent/cap.ex"
  @cli_dispatch "apps/ezagent_cli/lib/ezagent_cli/dispatch.ex"
  @git_task_access "apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex"
  @provider_connection "apps/ezagent_domain_provider_connection/lib/ezagent/behavior/provider_connection.ex"

  @storage_homes %{
    @identity_behavior => 3,
    @entity_caps => 1,
    @recipe_cap_binding => 1,
    @outbound_grant => 1,
    @snapshot => 1,
    @git_task_access => 1
  }
  @storage_home_count 8

  test "I5 structural storage boundary calls are exact, ratcheted, and at most eight" do
    actual = cap_storage_calls()

    assert actual == @storage_homes,
           "Cap storage checks moved outside the reviewed load boundaries:\n#{inspect(actual, pretty: true)}"

    assert Enum.sum(Map.values(@storage_homes)) == @storage_home_count
    assert @storage_home_count <= 8
  end

  test "I5 named boundaries route through the reviewed verification helpers" do
    assert definition_source(@identity_behavior, :create, 1) =~ "Ezagent.Cap.verified_set"

    assert definition_source(@identity_behavior, :activate, 2) =~
             "reconcile_recipe_binding_state"

    assert definition_source(@identity_behavior, :reconcile_recipe_binding_state, 2) =~
             "Ezagent.Cap.verified_set"

    assert definition_source(@identity_behavior, :handle_grant_cap, 2) =~
             "store_verified_cap"

    assert definition_source(@identity_behavior, :handle_absorb_cap, 2) =~
             "store_verified_cap"

    store = definition_source(@identity_behavior, :store_verified_cap, 3)
    assert store =~ "Ezagent.Cap.storable_for?"
    assert store =~ "set_caps_effect(new_caps)"

    assert definition_source(@identity_behavior, :set_caps_effect, 1) =~
             "{:set, :caps, caps}"

    assert definition_source(@identity_facade, :list_caps_for, 1) =~ "verified_cap_set"
    assert definition_source(@identity_facade, :read_held_caps, 1) =~ "verified_cap_set"

    assert source(@identity_facade) =~
             "defdelegate read_entity_caps(entity_uri), to: Ezagent.EntityCaps, as: :load"

    facade_verifier = definition_source(@identity_facade, :verified_cap_set, 2)
    assert facade_verifier =~ "Ezagent.EntityCaps.verified_set"

    entity_caps_verifier = definition_source(@entity_caps, :verified_set, 2)
    assert entity_caps_verifier =~ "Ezagent.Cap.verified_set"

    assert definition_source(@recipe_cap_binding, :validate_artifact, 4) =~
             "Ezagent.Cap.storable_for?"

    assert definition_source(@outbound_grant, :normalize_attrs, 1) =~
             "Ezagent.Cap.storable_for?"

    git_authorizer = definition_source(@git_task_access, :authorize_receiver, 3)
    assert git_authorizer =~ "signed_for?"
    assert git_authorizer =~ "Cap.storable_for?"

    assert definition_source(@snapshot, :load_with_fallback, 3) =~
             "verify_snapshot_caps(receiver_uri)"

    assert definition_source(@snapshot, :verify_snapshot_caps, 2) =~
             "put_verified_snapshot_caps"

    assert definition_source(@snapshot, :put_verified_snapshot_caps, 4) =~
             "Ezagent.Cap.verified_set"

    assert definition_source(@cap, :verified_set, 2) =~ "storable_for?(cap, receiver_uri)"

    verifier = source("apps/ezagent_core/lib/ezagent/cap/verifier.ex")
    assert verifier =~ "Authority.verify_current(cap, presenter)"

    strict_verify_callers =
      source_files()
      |> Enum.filter(fn {_relative, absolute} ->
        File.read!(absolute) =~ "Authority.verify_current("
      end)
      |> Enum.map(&elem(&1, 0))

    assert strict_verify_callers == [
             "apps/ezagent_core/lib/ezagent/cap.ex",
             "apps/ezagent_core/lib/ezagent/cap/verifier.ex"
           ]

    provider_callback =
      definition_source(@provider_connection, :validate_callback_artifact, 2)

    assert provider_callback =~ "Cap.validate_for_current_target"

    narrow_helper = definition_source(@cap, :validate_for_current_target, 2)
    assert narrow_helper =~ "Authority.verify_current(artifact, receiver)"
  end

  test "slice-to-ctx callers use the verified identity loader without filtering inline caps" do
    cli_loader = definition_source(@cli_dispatch, :lookup_identity_caps, 1)
    assert cli_loader =~ "Ezagent.Identity.read_held_caps"
    refute cli_loader =~ "Ezagent.Kind.get_slice"

    runtime = source("apps/ezagent_core/lib/ezagent/kind/runtime.ex")
    refute runtime =~ "Ezagent.Cap.verified_set"
    assert runtime =~ "Ezagent.Cap.Verifier.authorize"
  end

  test "no matches consumption function also performs verification" do
    violations =
      for {relative, absolute} <- source_files(),
          definition <- definitions(absolute),
          definition =~ "Cap.storable_for?" or definition =~ "Cap.verified_set",
          definition =~ ".matches?",
          do: relative

    assert violations == []
  end

  defp cap_storage_calls do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      count =
        absolute
        |> quoted!()
        |> count_calls(&cap_storage_call?/1)

      if count == 0, do: acc, else: Map.put(acc, relative, count)
    end)
  end

  defp cap_storage_call?({{:., _, [module, function]}, _, args})
       when function in [:verified_set, :storable_for?] and is_list(args) and
              length(args) in [1, 2] do
    Macro.to_string(module) in ["Cap", "Ezagent.Cap"]
  end

  defp cap_storage_call?(_node), do: false

  defp count_calls(ast, predicate) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, count ->
        {node, if(predicate.(node), do: count + 1, else: count)}
      end)

    count
  end

  defp definition_source(relative, name, arity) do
    sources =
      relative
      |> absolute()
      |> definitions()
      |> Enum.filter(fn source -> definition_signature(source) == {name, arity} end)

    assert sources != [], "missing #{name}/#{arity} in #{relative}"
    Enum.join(sources, "\n")
  end

  defp definitions(file) do
    file
    |> quoted!()
    |> then(fn ast ->
      {_ast, defs} =
        Macro.prewalk(ast, [], fn
          {kind, _, [_head, [do: _body]]} = node, defs when kind in [:def, :defp] ->
            {node, [Macro.to_string(node) | defs]}

          node, defs ->
            {node, defs}
        end)

      defs
    end)
  end

  defp definition_signature(source) do
    {:ok, {kind, _, [head, [do: _body]]}} = Code.string_to_quoted(source)
    true = kind in [:def, :defp]
    head_signature(head)
  end

  defp head_signature({:when, _, [head | _guards]}), do: head_signature(head)
  defp head_signature({name, _, args}) when is_atom(name), do: {name, length(args || [])}

  defp source(relative), do: relative |> absolute() |> File.read!()
  defp absolute(relative), do: Path.join(repo_root(), relative)

  defp source_files do
    root = repo_root()

    root
    |> Path.join("apps/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&{String.replace_prefix(&1, root <> "/", ""), &1})
  end

  defp quoted!(file) do
    case Code.string_to_quoted(File.read!(file)) do
      {:ok, ast} -> ast
      {:error, reason} -> raise "cannot scan #{file}: #{inspect(reason)}"
    end
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
