defmodule Ezagent.SkillRegistryTest do
  use ExUnit.Case, async: true

  @skill_ref "ezagent-session-orchestrator"

  defp registry! do
    assert {:module, Ezagent.SkillRegistry} = Code.ensure_loaded(Ezagent.SkillRegistry)
    Ezagent.SkillRegistry
  end

  defp tmp_dir(tag) do
    dir =
      Path.join(System.tmp_dir!(), "skill-registry-#{tag}-#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    dir
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  test "derived_recipe_skill_refs/0 is computed from plugin roles/0 recipes" do
    registry = registry!()

    assert registry.derived_recipe_skill_refs() == [@skill_ref]
  end

  test "seed_bundle_refs/0 matches the derived runtime skill set" do
    registry = registry!()

    assert @skill_ref in registry.seed_bundle_refs()
    assert registry.seed_bundle_refs() == registry.derived_recipe_skill_refs()
  end

  test "resolve/1 returns the shipped seed dir and directory hash" do
    registry = registry!()

    assert {:ok, {dir, hash}} = registry.resolve(@skill_ref)
    assert File.regular?(Path.join(dir, "SKILL.md"))
    assert hash == registry.dir_hash(dir)
    assert byte_size(hash) == 64
  end

  test "resolve/1 returns a fail-loud miss for an unknown ref" do
    registry = registry!()
    ref = "missing-skill-#{System.unique_integer([:positive])}"

    assert {:error, {:skill_source_not_found, ^ref}} = registry.resolve(ref)
  end

  test "dir_hash/1 hashes relpath, owner exec bit, content, and symlink target" do
    registry = registry!()
    dir = tmp_dir("hash")
    same_non_exec_mode = tmp_dir("hash-non-exec")
    renamed = tmp_dir("hash-renamed")
    exec_changed = tmp_dir("hash-exec")
    link_changed = tmp_dir("hash-link")

    try do
      write!(Path.join(dir, "bin/run"), "echo hi\n")
      write!(Path.join(dir, "README.md"), "body\n")
      File.ln_s!("bin/run", Path.join(dir, "run-link"))
      File.chmod!(Path.join(dir, "bin/run"), 0o644)

      File.cp_r!(dir, same_non_exec_mode)
      File.chmod!(Path.join(same_non_exec_mode, "bin/run"), 0o600)

      File.cp_r!(dir, renamed)
      File.rename!(Path.join(renamed, "README.md"), Path.join(renamed, "RENAMED.md"))

      File.cp_r!(dir, exec_changed)
      File.chmod!(Path.join(exec_changed, "bin/run"), 0o755)

      File.cp_r!(dir, link_changed)
      File.rm!(Path.join(link_changed, "run-link"))
      File.ln_s!("README.md", Path.join(link_changed, "run-link"))

      base_hash = registry.dir_hash(dir)

      assert registry.dir_hash(same_non_exec_mode) == base_hash
      refute registry.dir_hash(renamed) == base_hash
      refute registry.dir_hash(exec_changed) == base_hash
      refute registry.dir_hash(link_changed) == base_hash
    after
      for path <- [dir, same_non_exec_mode, renamed, exec_changed, link_changed] do
        File.rm_rf!(path)
      end
    end
  end
end
