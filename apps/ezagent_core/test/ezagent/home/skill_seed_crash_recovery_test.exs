defmodule Ezagent.Home.SkillSeedCrashRecoveryTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Home.SkillSeed

  setup do
    ref = "skill-crash-#{System.unique_integer([:positive])}"
    source = tmp_dir("src")
    dest = tmp_dir("dest")
    write!(Path.join(source, "#{ref}/SKILL.md"), "release two\n")

    on_exit(fn ->
      File.rm_rf!(source)
      File.rm_rf!(dest)
    end)

    {:ok, ref: ref, source: source, dest: dest}
  end

  test "mid-copy staging residue is deleted and seed re-runs", %{
    ref: ref,
    source: source,
    dest: dest
  } do
    write!(Path.join(dest, "#{ref}.staging-a/SKILL.md"), "partial\n")

    assert :ok = SkillSeed.seed!(source: source, dest: dest)

    assert_complete(dest, ref, "release two\n")
    assert_no_intermediates(dest)
  end

  test "complete staging plus old ref is deleted and upgrade re-runs", %{
    ref: ref,
    source: source,
    dest: dest
  } do
    write!(Path.join(dest, "#{ref}/SKILL.md"), "release one\n")
    write!(Path.join(dest, "#{ref}.staging-a/SKILL.md"), "release two\n")
    seed_index!(dest, ref, "release one\n")

    assert :ok = SkillSeed.seed!(source: source, dest: dest)

    assert_complete(dest, ref, "release two\n")
    assert_no_intermediates(dest)
  end

  test "missing ref with old and staging restores old then reapplies upgrade", %{
    ref: ref,
    source: source,
    dest: dest
  } do
    write!(Path.join(dest, "#{ref}.old-a/SKILL.md"), "release one\n")
    write!(Path.join(dest, "#{ref}.staging-a/SKILL.md"), "release two\n")
    seed_index!(dest, ref, "release one\n")

    assert :ok = SkillSeed.seed!(source: source, dest: dest)

    assert_complete(dest, ref, "release two\n")
    assert_no_intermediates(dest)
  end

  test "new ref plus old residue deletes old and keeps new", %{
    ref: ref,
    source: _source,
    dest: dest
  } do
    write!(Path.join(dest, "#{ref}/SKILL.md"), "release two\n")
    write!(Path.join(dest, "#{ref}.old-a/SKILL.md"), "release one\n")

    assert :ok = SkillSeed.recover!(dest: dest)

    assert_complete(dest, ref, "release two\n")
    assert_no_intermediates(dest)
  end

  test "fresh seed rename residue is absent or complete after recovery and seed", %{
    ref: ref,
    source: source,
    dest: dest
  } do
    File.mkdir_p!(dest)

    assert :ok = SkillSeed.seed!(source: source, dest: dest)

    assert_complete(dest, ref, "release two\n")
    assert_no_intermediates(dest)
  end

  test "double-crash partial staging delete is re-entrant", %{
    ref: ref,
    source: source,
    dest: dest
  } do
    write!(Path.join(dest, "#{ref}.staging-a/nested/SKILL.md"), "partial\n")

    assert :ok = SkillSeed.seed!(source: source, dest: dest)

    assert_complete(dest, ref, "release two\n")
    assert_no_intermediates(dest)
  end

  test "double-crash restored old ref with no intermediates reapplies upgrade", %{
    ref: ref,
    source: source,
    dest: dest
  } do
    write!(Path.join(dest, "#{ref}/SKILL.md"), "release one\n")
    seed_index!(dest, ref, "release one\n")

    assert :ok = SkillSeed.seed!(source: source, dest: dest)

    assert_complete(dest, ref, "release two\n")
    assert_no_intermediates(dest)
  end

  defp seed_index!(dest, ref, body) do
    source = tmp_dir("old-src")

    try do
      write!(Path.join(source, "#{ref}/SKILL.md"), body)
      assert SkillSeed.seed!(source: source, dest: dest) in [:ok, {:ok, :exists}]
    after
      File.rm_rf!(source)
    end
  end

  defp assert_complete(dest, ref, body) do
    assert File.read!(Path.join(dest, "#{ref}/SKILL.md")) == body
    Ezagent.SkillRegistry.reset!()
    assert :ok = Ezagent.SkillRegistry.refresh!(runtime_dir: dest)
    assert {:ok, {dir, hash}} = Ezagent.SkillRegistry.resolve(ref)
    assert dir == Path.expand(Path.join(dest, ref))
    assert hash == Ezagent.SkillRegistry.dir_hash(dir)
  end

  defp assert_no_intermediates(dest) do
    leftovers =
      dest
      |> File.ls!()
      |> Enum.filter(&(String.contains?(&1, ".staging-") or String.contains?(&1, ".old-")))

    assert leftovers == []
  end

  defp tmp_dir(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "skill-seed-crash-#{tag}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    dir
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end
end
