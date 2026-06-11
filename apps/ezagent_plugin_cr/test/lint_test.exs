defmodule EzagentPluginCr.LintTest do
  @moduledoc """
  Tests for EzagentPluginCr.Lint.

  Uses a tmp EZAGENT_HOME to isolate filesystem state.
  No CrStore involvement — Lint only reads the sandbox.
  """

  use ExUnit.Case, async: false

  alias EzagentPluginContent.TenantPaths
  alias EzagentPluginCr.Lint

  # Unique per test; must match ~r/^[a-zA-Z0-9_-]+$/
  defp tid, do: "lt#{System.unique_integer([:positive])}"

  setup do
    tmp =
      System.tmp_dir!()
      |> Path.join("lint_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    original_home = System.get_env("EZAGENT_HOME")
    original_profile = System.get_env("EZAGENT_PROFILE")

    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", "default")

    on_exit(fn ->
      File.rm_rf!(tmp)

      case original_home do
        nil -> System.delete_env("EZAGENT_HOME")
        val -> System.put_env("EZAGENT_HOME", val)
      end

      case original_profile do
        nil -> System.delete_env("EZAGENT_PROFILE")
        val -> System.put_env("EZAGENT_PROFILE", val)
      end
    end)

    :ok
  end

  defp populate_sandbox(t) do
    sandbox = TenantPaths.sandbox_dir(t)
    File.mkdir_p!(sandbox)
    File.cp_r!(TenantPaths.skeleton_dir(), sandbox)
    sandbox
  end

  describe "run/1 — missing sandbox" do
    test "propagates {:error, :no_sandbox} when sandbox does not exist" do
      t = tid()
      assert {:error, :no_sandbox} = Lint.run(t)
    end
  end

  describe "run/1 — clean sandbox (no issues)" do
    test "returns {:ok, []} when skeleton has no unresolved placeholders and all skills present" do
      t = tid()
      populate_sandbox(t)
      assert {:ok, warnings} = Lint.run(t)
      assert warnings == []
    end
  end

  describe "R01 — placeholder warnings" do
    test "warns on unresolved {{key}} placeholder in soul override" do
      t = tid()
      sandbox = populate_sandbox(t)

      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)

      File.write!(Path.join(souls_dir, "customer.md"), """
      ## Tenant Override
      Contact us at {{contact.email}} or call {{support.phone}}.
      {{contact.email}} appears twice.
      """)

      assert {:ok, warnings} = Lint.run(t)

      # Deduped: {{contact.email}} appears twice but should be one warning
      assert "unresolved slot: {{contact.email}}" in warnings
      assert "unresolved slot: {{support.phone}}" in warnings
      # Dedup check: exactly one entry per placeholder
      contact_count =
        Enum.count(warnings, fn w -> String.contains?(w, "contact.email") end)

      assert contact_count == 1
    end

    test "warns on placeholder in soul override using {{not.a.slot}} form" do
      t = tid()
      sandbox = populate_sandbox(t)

      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)
      File.write!(Path.join(souls_dir, "customer.md"), "Hello {{not.a.slot}}\n")

      assert {:ok, warnings} = Lint.run(t)
      assert "unresolved slot: {{not.a.slot}}" in warnings
    end
  end

  describe "R03 — missing skill (fatal)" do
    test "returns {:error, {:missing_skill, rel}} for a soul referencing a nonexistent skill" do
      t = tid()
      sandbox = populate_sandbox(t)

      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)

      # Reference a skill that does NOT exist in the sandbox
      File.write!(Path.join(souls_dir, "customer.md"), """
      Use the skill at plugins/#{t}/skills/nope/SKILL.md for help.
      """)

      assert {:error, {:missing_skill, "nope/SKILL.md"}} = Lint.run(t)
    end

    test "passes R03 when referenced skill file exists" do
      t = tid()
      sandbox = populate_sandbox(t)

      skill_dir = Path.join(sandbox, "skills/myskill")
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "# My Skill\n")

      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)

      File.write!(Path.join(souls_dir, "customer.md"), """
      Use plugins/#{t}/skills/myskill/SKILL.md for guidance.
      """)

      assert {:ok, _warnings} = Lint.run(t)
    end

    test "fatal error takes precedence even when warnings also present" do
      t = tid()
      sandbox = populate_sandbox(t)

      souls_dir = Path.join(sandbox, "souls")
      File.mkdir_p!(souls_dir)

      File.write!(Path.join(souls_dir, "customer.md"), """
      {{unresolved.slot}} and plugins/#{t}/skills/missing/SKILL.md
      """)

      # R03 fatal — does not return {:ok, warnings}
      assert {:error, {:missing_skill, "missing/SKILL.md"}} = Lint.run(t)
    end
  end
end
