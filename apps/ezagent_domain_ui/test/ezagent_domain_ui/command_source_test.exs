defmodule Ezagent.UI.CommandSourceTest do
  @moduledoc """
  V1 UI PR-2 (SPEC §2.3 + §4 item 11).

  `CommandSource.search/2` is a pure ranking function — these tests
  exercise filtering + ranking with no process / DB setup.

  The `describe "dependency boundary"` block is the SPEC §4 item 11
  invariant: `CommandSource` must have NO `EzagentWeb.*` and NO
  `Ezagent.KindRegistry` dependency. Nav routes reach it only via the
  `ezagent_web` on_mount assign; it never reaches up.
  """

  use ExUnit.Case, async: true

  alias Ezagent.UI.CommandSource

  doctest Ezagent.UI.CommandSource

  defp nav(key, label) do
    %{
      key: key,
      kind: :nav,
      label: label,
      target: "/" <> label,
      icon: "dot",
      group: "Navigate"
    }
  end

  defp entity(key, label) do
    %{
      key: key,
      kind: :entity,
      label: label,
      target: "/identities",
      icon: "users",
      group: "Entities"
    }
  end

  describe "search/2 — filtering" do
    test "an empty query returns all candidates (up to the limit)" do
      cands = [nav("nav:/a", "Alpha"), nav("nav:/b", "Beta")]
      assert CommandSource.search("", cands) == cands
    end

    test "a whitespace-only query is treated as empty" do
      cands = [nav("nav:/a", "Alpha")]
      assert CommandSource.search("   ", cands) == cands
    end

    test "filters out candidates whose label does not match" do
      cands = [nav("nav:/sessions", "Sessions"), nav("nav:/routing", "Routing")]
      results = CommandSource.search("sess", cands)
      assert Enum.map(results, & &1.key) == ["nav:/sessions"]
    end

    test "matching is case-insensitive" do
      cands = [nav("nav:/sessions", "Sessions")]
      assert [%{key: "nav:/sessions"}] = CommandSource.search("SESSIONS", cands)
    end

    test "matching is a fuzzy subsequence — non-contiguous chars match in order" do
      cands = [nav("nav:/sessions", "Sessions")]
      assert [%{key: "nav:/sessions"}] = CommandSource.search("ssn", cands)
    end

    test "a query with no matches returns []" do
      cands = [nav("nav:/sessions", "Sessions")]
      assert CommandSource.search("zzz", cands) == []
    end

    test "caps results at 20" do
      cands = for i <- 1..50, do: nav("nav:/p#{i}", "Page#{i}")
      assert length(CommandSource.search("page", cands)) == 20
    end

    test "an empty candidate list yields []" do
      assert CommandSource.search("anything", []) == []
      assert CommandSource.search("", []) == []
    end
  end

  describe "search/2 — ranking" do
    test "an exact label match outranks a prefix match" do
      cands = [nav("nav:/sessionsx", "Sessionsx"), nav("nav:/sessions", "Sessions")]
      results = CommandSource.search("sessions", cands)
      assert Enum.map(results, & &1.key) == ["nav:/sessions", "nav:/sessionsx"]
    end

    test "a prefix match outranks a substring match" do
      # "Routing" — query "rout" is a prefix; "Re-routing" — substring only.
      cands = [entity("entity:b", "Pre-routing"), nav("nav:/routing", "Routing")]
      results = CommandSource.search("rout", cands)
      assert Enum.map(results, & &1.key) == ["nav:/routing", "entity:b"]
    end

    test "a substring match outranks a fuzzy-only subsequence match" do
      # query "abc": "Fabcz" contains it contiguously; "Axbxc" only fuzzily.
      cands = [nav("nav:/fuzzy", "Axbxc"), nav("nav:/sub", "Fabcz")]
      results = CommandSource.search("abc", cands)
      assert Enum.map(results, & &1.key) == ["nav:/sub", "nav:/fuzzy"]
    end

    test "ties broken by shorter label first" do
      cands = [nav("nav:/long", "Agentsxxxx"), nav("nav:/short", "Agents")]
      results = CommandSource.search("agents", cands)
      assert Enum.map(results, & &1.key) == ["nav:/short", "nav:/long"]
    end

    test "preserves the full result() shape on every returned row" do
      cands = [nav("nav:/sessions", "Sessions")]
      assert [result] = CommandSource.search("sess", cands)
      assert %{key: _, kind: :nav, label: _, target: _, icon: _, group: _} = result
    end
  end

  describe "dependency boundary (SPEC §4 item 11)" do
    # CommandSource is a pure ranking function. It MUST NOT depend on
    # `EzagentWeb.*` (it lives BELOW ezagent_web — nav routes flow DOWN
    # via an on_mount assign) NOR on `Ezagent.KindRegistry` (it never
    # queries live registries; the caller injects all candidates).
    #
    # We extract every module the compiled CommandSource.beam calls
    # into and assert the forbidden modules are absent.
    test "CommandSource references no EzagentWeb.* and no Ezagent.KindRegistry" do
      called = called_modules(Ezagent.UI.CommandSource)

      ezagent_web_refs =
        Enum.filter(called, fn mod ->
          mod |> Atom.to_string() |> String.starts_with?("Elixir.EzagentWeb")
        end)

      assert ezagent_web_refs == [],
             "CommandSource must not reference EzagentWeb.* — found: #{inspect(ezagent_web_refs)}"

      refute Ezagent.KindRegistry in called,
             "CommandSource must not depend on Ezagent.KindRegistry — " <>
               "it operates only on injected candidates"
    end

    # Extract every module CommandSource calls into. Walks the BEAM
    # abstract code for `{:remote, ...}` call targets — this catches
    # fully-qualified `Mod.fun(...)` calls (which the `:imports` chunk
    # would miss, since CommandSource imports nothing).
    defp called_modules(module) do
      {:module, ^module} = Code.ensure_loaded(module)
      beam = :code.which(module)

      {:ok, {^module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
        :beam_lib.chunks(beam, [:abstract_code])

      forms
      |> collect_remote_modules()
      |> Enum.uniq()
    end

    defp collect_remote_modules(ast) do
      ast
      |> List.wrap()
      |> Enum.flat_map(&walk/1)
    end

    # A remote (fully-qualified) call with a literal module atom.
    defp walk({:remote, _, {:atom, _, mod}, _fun}) when is_atom(mod), do: [mod]

    defp walk(tuple) when is_tuple(tuple),
      do: tuple |> Tuple.to_list() |> collect_remote_modules()

    defp walk(list) when is_list(list), do: collect_remote_modules(list)
    defp walk(_other), do: []
  end
end
