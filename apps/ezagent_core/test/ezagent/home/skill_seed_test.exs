defmodule Ezagent.Home.SkillSeedTest do
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ezagent.Home.SkillSeed
  alias Ezagent.Socialware.{ConfigObject, ConfigStore}

  @ref "ezagent-session-orchestrator"
  @ws "workspace://system"
  @subject "skill:#{@ref}"
  @layer "workspace"
  @key "skill"

  setup do
    source = tmp_dir("src")
    dest = tmp_dir("dest")
    write!(Path.join(source, "#{@ref}/SKILL.md"), "version: one\n")

    on_exit(fn ->
      File.rm_rf!(source)
      File.rm_rf!(dest)
    end)

    {:ok, source: source, dest: dest}
  end

  test "idempotent seed copies once and records the skill index", %{source: source, dest: dest} do
    assert :ok = SkillSeed.seed!(source: source, dest: dest)
    assert File.read!(Path.join(dest, "#{@ref}/SKILL.md")) == "version: one\n"

    assert {:ok, :exists} = SkillSeed.seed!(source: source, dest: dest)
    assert File.read!(Path.join(dest, "#{@ref}/SKILL.md")) == "version: one\n"

    assert {:ok, %ConfigObject{body: body}} =
             ConfigStore.resolve(@layer, @ws, @subject, @key)

    assert body["ref"] == @ref
    assert body["content_hash"] == Ezagent.SkillRegistry.dir_hash(Path.join(dest, @ref))
    assert body["shipped_hash"] == Ezagent.SkillRegistry.dir_hash(Path.join(source, @ref))
  end

  test "untouched deployed copy upgrades when the release seed hash changes", %{
    source: source,
    dest: dest
  } do
    assert :ok = SkillSeed.seed!(source: source, dest: dest)
    write!(Path.join(source, "#{@ref}/SKILL.md"), "version: two\n")

    assert :ok = SkillSeed.seed!(source: source, dest: dest)

    assert File.read!(Path.join(dest, "#{@ref}/SKILL.md")) == "version: two\n"

    assert {:ok, %ConfigObject{body: %{"shipped_hash" => shipped_hash}}} =
             ConfigStore.resolve(@layer, @ws, @subject, @key)

    assert shipped_hash == Ezagent.SkillRegistry.dir_hash(Path.join(source, @ref))
  end

  test "operator-edited deployed copy is preserved when the release seed is unchanged", %{
    source: source,
    dest: dest
  } do
    assert :ok = SkillSeed.seed!(source: source, dest: dest)
    write!(Path.join(dest, "#{@ref}/SKILL.md"), "operator edit\n")

    assert {:ok, :preserved} = SkillSeed.seed!(source: source, dest: dest)

    assert File.read!(Path.join(dest, "#{@ref}/SKILL.md")) == "operator edit\n"
  end

  test "operator-edited deployed copy plus release change is preserved with warning and telemetry",
       %{
         source: source,
         dest: dest
       } do
    assert :ok = SkillSeed.seed!(source: source, dest: dest)
    write!(Path.join(dest, "#{@ref}/SKILL.md"), "operator edit\n")
    write!(Path.join(source, "#{@ref}/SKILL.md"), "version: two\n")

    test_pid = self()
    handler_id = "skill-seed-upgrade-skipped-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:ezagent, :skill_seed, :upgrade_skipped],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:skill_seed_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert {:ok, :preserved} = SkillSeed.seed!(source: source, dest: dest)
      end)

    assert log =~ "skill-seed: SKIPPED release upgrade for #{@ref}"
    assert File.read!(Path.join(dest, "#{@ref}/SKILL.md")) == "operator edit\n"

    assert_receive {:skill_seed_telemetry, [:ezagent, :skill_seed, :upgrade_skipped], %{count: 1},
                    %{ref: @ref, on_disk_hash: _, shipped_hash: _, release_hash: _}}
  end

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "skill-seed-#{tag}-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    dir
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end
end
