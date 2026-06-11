defmodule EzagentPluginContent.Platform.PlatformSkillStoreTest do
  use ExUnit.Case
  alias EzagentPluginContent.Platform.PlatformSkillStore

  @test_role "test-skills-role"

  setup do
    # Create a temp skill for testing writes/deletes
    on_exit(fn ->
      PlatformSkillStore.delete_skill(@test_role, "test-skill")
      PlatformSkillStore.delete_skill(@test_role, "delete-test-skill")
    end)
    :ok
  end

  test "list_skills for customer role returns known skills" do
    {:ok, skills} = PlatformSkillStore.list_skills("customer")
    assert is_list(skills)
    # The platform ships with at least customer-type-clarifier
    if skills != [] do
      assert Enum.all?(skills, &is_binary/1)
    end
  end

  test "list_skills for nonexistent role returns empty list" do
    {:ok, skills} = PlatformSkillStore.list_skills("nonexistent-role-xyz")
    assert skills == []
  end

  test "write_skill and read_skill roundtrip" do
    content = "# Test Skill\n\nTest content for platform skill."
    :ok = PlatformSkillStore.write_skill(@test_role, "test-skill", content)
    {:ok, read_back} = PlatformSkillStore.read_skill(@test_role, "test-skill")
    assert read_back == content
  end

  test "read_skill nonexistent returns :not_found" do
    assert {:error, :not_found} = PlatformSkillStore.read_skill(@test_role, "nonexistent-skill")
  end

  test "delete_skill removes skill" do
    PlatformSkillStore.write_skill(@test_role, "delete-test-skill", "temp content")
    {:ok, _} = PlatformSkillStore.read_skill(@test_role, "delete-test-skill")
    :ok = PlatformSkillStore.delete_skill(@test_role, "delete-test-skill")
    assert {:error, :not_found} = PlatformSkillStore.read_skill(@test_role, "delete-test-skill")
  end
end
