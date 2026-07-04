defmodule EzagentPluginKb.KbIsolationTest do
  @moduledoc """
  Fast static gates for the KB isolation/architecture claims (SPEC §8.8) +
  recipe parity. These do not need the framework booted.

    * **§8.8 no ezagent-Postgres entanglement** — the plugin's `lib/` declares
      NO `Ecto.Schema`, NO `Ecto.Migration`, NO `Repo.insert/update/delete`, and
      NO `migrations/` dir. The KB corpus is wholly in the per-KB sqlite file;
      nothing touches ezagent's Postgres.
    * **§8.8 no new Kind / no new domain** — the plugin declares NO `kinds/0`
      and NO `resource_kinds/0`; KB is role × native on the existing
      Entity.Agent. (`def roles` IS expected; `def kinds`/`resource_kinds` are
      not.)
    * **recipe parity** — the `kb` recipe requests exactly one cap per
      `Behavior.Kb` action, passive, behaviors `[Behavior.Kb]`.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginKb.Application, as: KbApp

  @plugin_lib Path.expand("../lib", __DIR__)

  describe "no ezagent-Postgres entanglement (SPEC §8.8)" do
    test "the plugin lib declares no Ecto schema / migration / Repo writes" do
      sources = lib_sources()

      banned = [
        {~r/\buse\s+Ecto\.Schema\b/, "Ecto.Schema (KB corpus must NOT be a Postgres table)"},
        {~r/\buse\s+Ecto\.Migration\b/, "Ecto.Migration (no ezagent migration touches KB)"},
        {~r/\bRepo\.(insert|update|delete|insert_all)\b/, "Repo write (KB is sqlite-only)"}
      ]

      for {path, src} <- sources, {pattern, label} <- banned do
        refute Regex.match?(pattern, src),
               "#{Path.relative_to(path, @plugin_lib)} must not contain #{label}"
      end
    end

    test "the plugin owns no migrations directory" do
      refute File.dir?(Path.expand("../priv/repo/migrations", __DIR__))
      refute File.dir?(Path.expand("../priv/migrations", __DIR__))
    end
  end

  describe "no new Kind / no new domain (SPEC §8.8)" do
    test "the plugin declares no kinds/0 and no resource_kinds/0" do
      refute function_exported?(KbApp, :kinds, 0) and KbApp.kinds() != [],
             "KB is role × native — it must declare NO Kind"

      refute function_exported?(KbApp, :resource_kinds, 0),
             "KB must declare NO resource Kind (Plan-B is locked out)"
    end
  end

  describe "recipe parity" do
    test "kb recipe = passive [Behavior.Kb] with one cap per action" do
      recipe = KbApp.kb_recipe()

      assert recipe.name == "kb"
      assert recipe.passive == true
      assert recipe.behaviors == [Ezagent.ActionSet.Kb]

      requested =
        recipe.requested_caps
        |> Enum.map(fn c -> {c.behavior, c.action} end)
        |> MapSet.new()

      actions = MapSet.new(Ezagent.ActionSet.Kb.actions())

      expected =
        actions |> Enum.map(fn a -> {Ezagent.ActionSet.Kb, a} end) |> MapSet.new()

      assert requested == expected,
             "the recipe must request exactly one cap per Behavior.Kb action"

      assert MapSet.new([:query, :ingest]) == actions
    end

    test "resource_types declares kb-store and kb-source, ws-isolated" do
      types = KbApp.resource_types() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
      assert MapSet.new(["kb-store", "kb-source"]) == types

      # R-3: a foreign-workspace URI is rejected; the matching workspace passes.
      ok_uri = URI.new!("resource://ws1/kb-store/agent1")
      assert :ok = KbApp.kb_authority(ok_uri, %{workspace: "ws1"})
      assert {:error, {:foreign_workspace, _}} = KbApp.kb_authority(ok_uri, %{workspace: "ws2"})
    end
  end

  defp lib_sources do
    Path.wildcard(Path.join(@plugin_lib, "**/*.ex"))
    |> Enum.map(fn path -> {path, File.read!(path)} end)
  end
end
