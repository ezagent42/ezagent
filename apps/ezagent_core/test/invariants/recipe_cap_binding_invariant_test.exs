defmodule EzagentCore.Invariants.RecipeCapBindingInvariantTest do
  @moduledoc """
  Phase 3 S5 / I9 architecture lock for durable recipe-cap bindings.

  The binding is identity-owned, keyed identically by writer and readers, and
  committed immediately after a fresh agent establishes its per-Kind authority
  and before it can join. Definitive bind/join failures must conditionally
  tombstone the exact binding version and terminate the unjoined agent.
  """
  use ExUnit.Case, async: true

  @binding "apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex"
  @identity "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
  @materializer "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex"
  @identity_mix "apps/ezagent_domain_identity/mix.exs"
  @identity_application "apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex"
  @sweeper "apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding/sweeper.ex"

  test "I9 binding stays in the identity tier with no downstream dependency" do
    assert File.exists?(absolute(@binding))

    mix = source(@identity_mix)
    assert mix =~ "{:ezagent_core, in_umbrella: true}"
    refute mix =~ "{:ezagent_domain_session,"
    refute mix =~ "{:ezagent_domain_agent,"
  end

  test "I9 writer and both startup readers share the canonical instance key" do
    binding = source(@binding)
    identity = source(@identity)

    assert binding =~ "Ezagent.URI.instance"
    assert binding =~ "issue_and_upsert"
    assert identity =~ "RecipeCapBinding.fetch"
    assert identity =~ "recipe_binding_version"
    assert identity =~ "recipe_binding_keys"
    assert definition_source(@identity, :create, 1) =~ "recipe_binding"
    assert definition_source(@identity, :activate, 2) =~ "reconcile_recipe_binding"
  end

  test "I9 fresh materialization spawns before binding, syncs, then joins" do
    materialize = definition_source(@materializer, :materialize_fresh_agent, 6)
    refute materialize =~ "bind_recipe_caps"

    spawn = definition_source(@materializer, :spawn_bound_agent, 8)
    assert ordered?(spawn, "spawn_agent", "bind_recipe_caps")
    assert ordered?(spawn, "bind_recipe_caps", "RecipeCapBinding.sync_live")
    assert ordered?(spawn, "RecipeCapBinding.sync_live", "join_or_cleanup")
    assert spawn =~ "compensate_recipe_binding"
    assert spawn =~ "terminate_worker"

    compensate = definition_source(@materializer, :compensate_recipe_binding, 2)
    assert compensate =~ "RecipeCapBinding.tombstone_if_version"
  end

  test "I9 reused and already-materialized URIs upsert the durable binding" do
    materializer = source(@materializer)
    reuse = definition_source(@materializer, :reuse_existing_agent, 6)

    assert reuse =~ "bind_recipe_caps"
    assert ordered?(reuse, "Participants.add_participant", "bind_recipe_caps")

    assert definition_source(@materializer, :refresh_existing_binding, 4) =~
             "bind_recipe_caps"

    assert materializer =~ "RecipeCapBinding.issue_and_upsert"
  end

  test "I9 tombstones have a supervised, bounded-retention GC path" do
    assert source(@identity_application) =~ "Ezagent.Identity.RecipeCapBinding.Sweeper"

    sweeper = source(@sweeper)
    assert sweeper =~ "RecipeCapBinding.prune_tombstoned"
    assert sweeper =~ "Process.send_after"
    assert sweeper =~ "@default_retention_ms"
  end

  test "C2 issue authorization completes before the durable transaction" do
    issue = definition_source(@binding, :issue_and_upsert, 4)
    assert ordered?(issue, "issue_all", "persist_issued")

    issue_all = definition_source(@binding, :issue_all, 3)
    assert issue_all =~ "Ezagent.Cap.issue"

    persist = definition_source(@binding, :persist_issued, 5)
    assert persist =~ "Repo.transaction"
    refute persist =~ "Ezagent.Cap.issue"
  end

  defp ordered?(source, first, second) do
    case {index(source, first), index(source, second)} do
      {{first_index, _}, {second_index, _}} -> first_index < second_index
      _ -> false
    end
  end

  defp index(source, needle), do: :binary.match(source, needle)

  defp definition_source(relative, name, arity) do
    matches =
      relative
      |> absolute()
      |> quoted!()
      |> definitions()
      |> Enum.filter(fn {signature, _source} -> signature == {name, arity} end)
      |> Enum.map(&elem(&1, 1))

    assert matches != [], "missing #{name}/#{arity} in #{relative}"
    Enum.join(matches, "\n")
  end

  defp definitions(ast) do
    {_ast, definitions} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, [do: _body]]} = node, acc when kind in [:def, :defp] ->
          {node, [{head_signature(head), Macro.to_string(node)} | acc]}

        node, acc ->
          {node, acc}
      end)

    definitions
  end

  defp head_signature({:when, _, [head | _guards]}), do: head_signature(head)
  defp head_signature({name, _, args}) when is_atom(name), do: {name, length(args || [])}

  defp quoted!(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()
    ast
  end

  defp source(relative), do: relative |> absolute() |> File.read!()
  defp absolute(relative), do: Path.join(repo_root(), relative)

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
