defmodule EzagentPluginContent.SkillIndexerTest do
  use ExUnit.Case, async: true

  alias EzagentPluginContent.SkillIndexer

  setup do
    dir =
      System.tmp_dir!() |> Path.join("skill_indexer_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_skill(base, rel_path, frontmatter, body \\ "# Body") do
    full_path = Path.join(base, rel_path)
    File.mkdir_p!(Path.dirname(full_path))

    content =
      if frontmatter do
        "---\n#{frontmatter}---\n\n#{body}"
      else
        body
      end

    File.write!(full_path, content)
  end

  describe "build/2 with two skills in nested dirs" do
    test "lists both skills sorted by name, with correct rel paths", %{dir: dir} do
      write_skill(dir, "beta-skill/SKILL.md", "name: beta-skill\ndescription: Beta desc\n")

      write_skill(
        dir,
        "nested/alpha-skill/SKILL.md",
        "name: alpha-skill\ndescription: Alpha desc\n"
      )

      result = SkillIndexer.build(dir, "acme")

      assert result =~ "## Skill Index"

      assert result =~
               "- alpha-skill — Alpha desc (plugins/acme/skills/nested/alpha-skill/SKILL.md)"

      assert result =~ "- beta-skill — Beta desc (plugins/acme/skills/beta-skill/SKILL.md)"

      # alpha appears before beta (sorted by name)
      alpha_pos = :binary.match(result, "alpha-skill") |> elem(0)
      beta_pos = :binary.match(result, "beta-skill") |> elem(0)
      assert alpha_pos < beta_pos
    end
  end

  describe "build/2 with missing frontmatter" do
    test "uses directory name as skill name, no crash", %{dir: dir} do
      write_skill(dir, "my-skill/SKILL.md", nil, "# Just a body, no frontmatter")

      result = SkillIndexer.build(dir, "acme")

      assert result =~ "## Skill Index"
      # directory name used as fallback
      assert result =~ "my-skill"
      refute result =~ "(none)"
    end
  end

  describe "build/2 with nonexistent dir" do
    test "returns (none) form" do
      result = SkillIndexer.build("/tmp/nonexistent_dir_#{:erlang.unique_integer()}", "acme")
      assert result == "## Skill Index\n\n(none)\n"
    end
  end

  describe "build/2 edge cases" do
    test "empty dir (no SKILL.md files) returns (none) form", %{dir: dir} do
      # dir exists but has no SKILL.md
      result = SkillIndexer.build(dir, "acme")
      assert result == "## Skill Index\n\n(none)\n"
    end

    test "SKILL.md with malformed frontmatter falls back to dir name, no crash", %{dir: dir} do
      path = Path.join(dir, "bad-skill/SKILL.md")
      File.mkdir_p!(Path.dirname(path))
      # Malformed YAML between ---
      File.write!(path, "---\n: invalid: yaml: [\n---\n# body")

      result = SkillIndexer.build(dir, "acme")

      assert result =~ "## Skill Index"
      assert result =~ "bad-skill"
    end

    test "skill with name but no description uses empty description", %{dir: dir} do
      write_skill(dir, "no-desc/SKILL.md", "name: no-desc\n")

      result = SkillIndexer.build(dir, "acme")
      assert result =~ "- no-desc —  (plugins/acme/skills/no-desc/SKILL.md)"
    end
  end
end
