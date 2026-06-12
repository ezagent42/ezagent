defmodule EzagentPluginAutoservice.TenantAdminContentRoundtripTest do
  @moduledoc """
  Round-trip test for the dev content APIs the tenant content-admin
  LiveView (`/autoservice/admin`) wires to. Confirms the slot + skill
  read/write helpers operate on the tenant SANDBOX and that the two
  base-dir conventions the LV reconciles are correct:

    - SoulStore: base = ".../tenants"           (joins [base, tid, ...])
    - SkillStore/Loader: base = parent of that  (they append "tenants")

  These are the exact calls the LV makes; keeping them green guards the
  wiring without needing a full LiveView mount.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginContent.Soul.SoulStore
  alias EzagentPluginContent.Skill.{SkillStore, SkillLoader}

  @tid "acme"
  @role "slow"

  setup do
    # `tenants_base` matches TenantRuntime.base_dir() shape (".../tenants").
    root = Path.join(System.tmp_dir!(), "as-admin-test-#{System.unique_integer([:positive])}")
    tenants_base = Path.join(root, "tenants")
    File.mkdir_p!(tenants_base)
    on_exit(fn -> File.rm_rf!(root) end)
    # `root` is the SkillStore/SkillLoader base (they append "tenants").
    {:ok, tenants_base: tenants_base, skill_base: root}
  end

  test "slot values round-trip through the sandbox", %{tenants_base: base} do
    # Empty before any write.
    assert {:ok, %{}} == SoulStore.read_slots(base, @tid, @role, :sandbox)

    :ok =
      SoulStore.write_slots(base, @tid, @role, %{"brand" => "Acme", "tone" => "warm"}, :sandbox)

    assert {:ok, %{"brand" => "Acme", "tone" => "warm"}} =
             SoulStore.read_slots(base, @tid, @role, :sandbox)

    # write_slots merges (preserves existing keys).
    :ok = SoulStore.write_slots(base, @tid, @role, %{"tone" => "formal"}, :sandbox)

    assert {:ok, %{"brand" => "Acme", "tone" => "formal"}} =
             SoulStore.read_slots(base, @tid, @role, :sandbox)
  end

  test "sandbox slot writes never touch the release path", %{tenants_base: base} do
    :ok = SoulStore.write_slots(base, @tid, @role, %{"k" => "v"}, :sandbox)

    sandbox_file = Path.join([base, @tid, "sandbox", "slots", "#{@role}.yaml"])
    release_file = Path.join([base, @tid, "release", "_current", "slots", "#{@role}.yaml"])

    assert File.exists?(sandbox_file)
    refute File.exists?(release_file)
  end

  test "skill files round-trip and list from the sandbox", %{skill_base: base} do
    assert SkillLoader.list(base, @tid, @role, :tenant) == []

    :ok = SkillStore.write(base, @tid, @role, "greeting", "# Greeting\nsay hi")

    names = SkillLoader.list(base, @tid, @role, :tenant) |> Enum.map(& &1.name)
    assert "greeting" in names

    assert {:ok, "# Greeting\nsay hi"} = SkillStore.read(base, @tid, @role, "greeting")

    # Skills are written under the tenant sandbox skills tree.
    skill_file =
      Path.join([base, "tenants", @tid, "sandbox", "skills", @role, "greeting", "SKILL.md"])

    assert File.exists?(skill_file)

    assert :ok = SkillStore.delete(base, @tid, @role, "greeting")
    assert SkillLoader.list(base, @tid, @role, :tenant) == []
  end
end
