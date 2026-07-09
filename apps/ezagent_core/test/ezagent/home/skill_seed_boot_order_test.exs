defmodule Ezagent.Home.SkillSeedBootOrderTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Home.SkillSeed
  alias Ezagent.SkillRegistry

  setup do
    source = tmp_dir("src")
    dest = tmp_dir("dest")

    # The fixture source is built FROM the derivation (IC-3): a hand-listed
    # single ref rots the moment any plugin's roles/0 declares another skill
    # (the first test iterates every derived ref against this source).
    fixture_refs =
      Enum.uniq(["ezagent-session-orchestrator" | SkillRegistry.derived_recipe_skill_refs()])

    for ref <- fixture_refs do
      write!(Path.join(source, "#{ref}/SKILL.md"), "boot seed\n")
    end

    SkillRegistry.reset!()

    on_exit(fn ->
      SkillRegistry.reset!()
      File.rm_rf!(source)
      File.rm_rf!(dest)
    end)

    {:ok, source: source, dest: dest}
  end

  test "fresh home resolves every derived Recipe.skills ref on the first registry read after boot",
       %{source: source, dest: dest} do
    refute SkillRegistry.ready?()

    assert :ok = SkillSeed.boot!(source: source, dest: dest)
    assert SkillRegistry.ready?()

    for ref <- SkillRegistry.derived_recipe_skill_refs() do
      assert {:ok, {dir, _hash}} = SkillRegistry.resolve(ref)
      assert File.regular?(Path.join(dir, "SKILL.md"))
      assert String.starts_with?(dir, Path.expand(dest))
    end
  end

  test "pre-ready resolve fails loudly and never scans the runtime dir", %{dest: dest} do
    write!(Path.join(dest, "ezagent-session-orchestrator/SKILL.md"), "complete\n")
    SkillRegistry.reset!()

    assert_raise RuntimeError, ~r/SkillRegistry is not ready/, fn ->
      SkillRegistry.resolve("ezagent-session-orchestrator")
    end
  end

  defp tmp_dir(tag) do
    dir =
      Path.join(System.tmp_dir!(), "skill-seed-boot-#{tag}-#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    dir
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end
end
