defmodule Ezagent.Identity.AuthenticatedHoldersTest do
  @moduledoc """
  #189 PR-2 (codex spec-review F4) — the closed `authenticated_holder?`
  classification invariant. It is DECLARATION-only: nothing in authorization
  consults it in PR-2 (the read plane stays legacy; the 9 `holder_revoked`
  reds stay red). The ratchet forces every production Kind `type_name` to carry
  an explicit holder/non-holder decision so the fleet barrier + backfill have a
  precise, closed population.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Identity.AuthenticatedHolders

  @valid_classes [:durable_holder, :ephemeral_holder, :non_holder]

  test "the declared classification uses only valid classes" do
    for {type_name, class} <- AuthenticatedHolders.classification() do
      assert is_atom(type_name)
      assert class in @valid_classes, "#{type_name} => #{inspect(class)} is not a valid class"
    end
  end

  test "the known holder population is classified as expected" do
    assert AuthenticatedHolders.classify(:user) == :durable_holder
    assert AuthenticatedHolders.classify(:agent) == :durable_holder
    assert AuthenticatedHolders.classify(:session) == :durable_holder
    assert AuthenticatedHolders.classify(:external_mirror_worker) == :ephemeral_holder

    assert AuthenticatedHolders.authenticated_holder?(:user)
    assert AuthenticatedHolders.authenticated_holder?(:external_mirror_worker)
    assert AuthenticatedHolders.durable_holder?(:agent)
    assert AuthenticatedHolders.ephemeral_holder?(:external_mirror_worker)
    refute AuthenticatedHolders.durable_holder?(:external_mirror_worker)

    refute AuthenticatedHolders.authenticated_holder?(:workspace)
    refute AuthenticatedHolders.authenticated_holder?(:system)
    refute AuthenticatedHolders.authenticated_holder?(:agent_template)
    refute AuthenticatedHolders.authenticated_holder?(:session_template)

    assert Enum.sort(AuthenticatedHolders.durable_holder_type_names()) ==
             [:agent, :session, :user]

    assert AuthenticatedHolders.ephemeral_holder_type_names() == [:external_mirror_worker]
  end

  test "an unclassified type_name is :unknown (fail-loud, never a silent holder)" do
    assert AuthenticatedHolders.classify(:some_new_kind) == :unknown
    refute AuthenticatedHolders.authenticated_holder?(:some_new_kind)
  end

  test "RATCHET: every production Kind type_name is explicitly classified" do
    production = production_type_names()

    # Sanity: the scanner must actually find the production Kinds (a wrong repo
    # path would silently pass with an empty set).
    assert :user in production
    assert :agent in production
    assert :external_mirror_worker in production
    # Pin the MACRO-form (`use Ezagent.Kind, type_name:`) detection specifically
    # (codex impl-review finding 3): a scanner that regressed to literal-`def`-only
    # would drop this and the "closed" classification would silently reopen.
    assert :git_task_access in production

    unclassified =
      Enum.filter(production, &(AuthenticatedHolders.classify(&1) == :unknown))

    assert unclassified == [],
           "New production Kind(s) are unclassified in " <>
             "Ezagent.Identity.AuthenticatedHolders — add an explicit " <>
             "holder/non-holder decision for: #{inspect(unclassified)}"
  end

  # ------------------------------------------------------------------
  # Scanner — every production Kind `type_name`, in BOTH declaration forms
  # across `apps/*/lib`:
  #
  #   1. a literal `def type_name, do: <atom>` (the entity modules that override
  #      the macro), and
  #   2. the MACRO form `use Ezagent.Kind, ..., type_name: <atom>` (e.g.
  #      `Ezagent.Entity.GitTaskAccess`) — scanning only literal `def`s missed
  #      this class, so the "closed" classification was structurally incomplete
  #      (codex impl-review finding 3).
  #
  # The `unquote(type_name)` clause INSIDE the `Ezagent.Kind` macro itself
  # (`kind.ex`, a non-literal body) is naturally skipped; test-support fixture
  # Kinds live under `test/` and are out of scope.
  # ------------------------------------------------------------------

  defp production_type_names do
    Path.join(repo_root(), "apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(&type_names_in_file/1)
    |> Enum.uniq()
  end

  defp type_names_in_file(path) do
    with {:ok, src} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(src) do
      {_ast, found} =
        Macro.prewalk(ast, [], fn
          # Form 1 — a literal `def type_name, do: :atom`.
          {:def, _, [{:type_name, _, ctx}, [do: body]]} = node, acc
          when (is_nil(ctx) or ctx == []) and is_atom(body) ->
            {node, [body | acc]}

          # Form 2 — `use Ezagent.Kind, ..., type_name: :atom`.
          {:use, _, [{:__aliases__, _, [:Ezagent, :Kind]}, opts]} = node, acc ->
            case type_name_opt(opts) do
              nil -> {node, acc}
              type_name -> {node, [type_name | acc]}
            end

          node, acc ->
            {node, acc}
        end)

      found
    else
      _ -> []
    end
  end

  defp type_name_opt(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :type_name) do
        atom when is_atom(atom) and not is_nil(atom) -> atom
        _ -> nil
      end
    end
  end

  defp type_name_opt(_opts), do: nil

  defp repo_root, do: Path.expand("../../../../..", __DIR__)
end
