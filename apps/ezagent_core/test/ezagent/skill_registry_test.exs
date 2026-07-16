defmodule Ezagent.SkillRegistryTest do
  use ExUnit.Case, async: true

  @skill_ref "ezagent-session-orchestrator"
  @socialware_skill_refs ["dev-together", "kanban-assistant"]

  setup do
    registry = registry!()
    registry.reset!()

    on_exit(fn -> registry.reset!() end)

    :ok
  end

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

  test "derived_recipe_skill_refs/0 is computed from plugin and socialware recipes" do
    registry = registry!()

    derived = registry.derived_recipe_skill_refs()

    # Membership + shape, NOT a hand-counted exact list (IC-3 bans the
    # hand-count: other plugins' roles/0 legitimately declare more skills and
    # the derived set follows them). The bundle↔derivation consistency
    # invariant is the next test.
    assert @skill_ref in derived
    assert Enum.all?(@socialware_skill_refs, &(&1 in derived))
    assert derived == derived |> Enum.uniq() |> Enum.sort()
  end

  test "seed_bundle_refs/0 matches the derived runtime skill set" do
    registry = registry!()

    assert @skill_ref in registry.seed_bundle_refs()
    assert registry.seed_bundle_refs() == registry.derived_recipe_skill_refs()
  end

  test "resolve/1 reads the runtime origin after an explicit scan" do
    registry = registry!()
    source = tmp_dir("runtime-origin")

    try do
      write!(Path.join(source, "#{@skill_ref}/SKILL.md"), "runtime copy\n")

      assert :ok = registry.refresh!(runtime_dir: source)
      assert {:ok, {dir, hash}} = registry.resolve(@skill_ref)
      assert dir == Path.expand(Path.join(source, @skill_ref))
      assert File.regular?(Path.join(dir, "SKILL.md"))
      assert hash == registry.dir_hash(dir)
      assert byte_size(hash) == 64
    after
      File.rm_rf!(source)
    end
  end

  test "resolve/1 returns a fail-loud miss for an unknown ref" do
    registry = registry!()
    source = tmp_dir("runtime-empty")
    ref = "missing-skill-#{System.unique_integer([:positive])}"

    try do
      File.mkdir_p!(source)
      assert :ok = registry.refresh!(runtime_dir: source)
      assert {:error, {:skill_source_not_found, ^ref}} = registry.resolve(ref)
    after
      File.rm_rf!(source)
    end
  end

  test "resolve/1 raises before the registry has scanned its runtime origin" do
    registry = registry!()

    assert_raise RuntimeError, ~r/SkillRegistry is not ready/, fn ->
      registry.resolve(@skill_ref)
    end
  end

  test "operator-dropped skill dir registers on the next scan" do
    registry = registry!()
    source = tmp_dir("operator-drop")

    try do
      File.mkdir_p!(source)
      assert :ok = registry.refresh!(runtime_dir: source)
      assert {:error, {:skill_source_not_found, @skill_ref}} = registry.resolve(@skill_ref)

      write!(Path.join(source, "#{@skill_ref}/SKILL.md"), "operator copy\n")
      assert :ok = registry.refresh!(runtime_dir: source)
      assert {:ok, {dir, _hash}} = registry.resolve(@skill_ref)
      assert dir == Path.expand(Path.join(source, @skill_ref))
    after
      File.rm_rf!(source)
    end
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
