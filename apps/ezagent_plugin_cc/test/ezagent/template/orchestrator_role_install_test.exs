defmodule Ezagent.PluginCc.Template.OrchestratorRoleInstallTest do
  @moduledoc """
  Task #54 PR-2 — the resolve / install split of the orchestrator role loader.

  `Ezagent.PluginCc.Template.OrchestratorBootstrap` now installs whatever the
  composed role recipe yields, not a hardcoded skill. These tests pin the two
  decoupled stages directly:

    * `install_role_sandbox/2` — pure filesystem, driven by an EXPLICIT skills
      list (so the installer is exercised independently of the recipe);
    * `resolve_orchestrator_role/0` — composes the code recipe into
      `sandbox_content` (skills + persona prompt).
  """
  # role-as-data: `resolve_orchestrator_role/0` now resolves the role read-through
  # over ConfigStore, so the suite needs the DataCase sandbox. The pure
  # `install_role_sandbox/2` (filesystem) tests ignore it.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Orchestrator.OrchestratorRole
  alias Ezagent.PluginCc.Template.OrchestratorBootstrap, as: Bootstrap

  @hint Bootstrap.hint_line()

  setup do
    # Stage a fake skill source so the install does not depend on the real
    # `.claude/skills/...` (a CI build might not ship it). The override is keyed
    # to the orchestrator skill ref.
    fixture_root = Path.join(System.tmp_dir!(), "orch-inst-#{System.unique_integer([:positive])}")
    skill_src = Path.join(fixture_root, "ezagent-session-orchestrator")
    File.mkdir_p!(skill_src)
    File.write!(Path.join(skill_src, "SKILL.md"), "fixture skill\n")

    Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, skill_src)

    config_dir =
      Path.join(System.tmp_dir!(), "orch-inst-cfg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(config_dir)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_cc, :orchestrator_skill_source)
      _ = File.rm_rf(fixture_root)
      _ = File.rm_rf(config_dir)
    end)

    {:ok, config_dir: config_dir}
  end

  describe "install_role_sandbox/2 — pure FS, explicit skills list" do
    test "copies each named skill into config_dir/skills/<ref> + appends the hint",
         %{config_dir: config_dir} do
      sandbox_content = %{skills: ["ezagent-session-orchestrator"], plugins: [], prompt: "p"}

      assert :ok = Bootstrap.install_role_sandbox(sandbox_content, config_dir)

      assert File.regular?(
               Path.join([config_dir, "skills", "ezagent-session-orchestrator", "SKILL.md"])
             )

      assert File.read!(Path.join(config_dir, "CLAUDE.md")) =~ @hint
    end

    test "empty skills installs nothing AND appends no hint (hint derived from skills)",
         %{config_dir: config_dir} do
      # The hint is derived from the installed skills, not hardcoded — with no
      # orchestrator skill installed there is nothing to hint about.
      assert :ok =
               Bootstrap.install_role_sandbox(%{skills: [], plugins: [], prompt: nil}, config_dir)

      refute File.dir?(Path.join(config_dir, "skills"))
      refute File.exists?(Path.join(config_dir, "CLAUDE.md"))
    end

    test "an unresolvable skill ref fails closed (not hardcoded to the orchestrator skill)",
         %{config_dir: config_dir} do
      # A ref with no override + no walk hit must surface an error — proving the
      # installer is genuinely ref-driven, not silently installing the
      # orchestrator skill regardless.
      sandbox_content = %{
        skills: ["definitely-not-a-real-skill-#{System.unique_integer([:positive])}"]
      }

      assert {:error, {:skill_source_not_found, _}} =
               Bootstrap.install_role_sandbox(sandbox_content, config_dir)
    end

    test "fail-closed: a non-empty plugins list is rejected (PR-2 defers plugin install)",
         %{config_dir: config_dir} do
      # A silent drop would be fail-open; rejecting makes the PR-2 deferral
      # explicit so try_apply/3 surfaces degraded meta.
      assert {:error, {:unsupported_role_content, :plugins}} =
               Bootstrap.install_role_sandbox(
                 %{skills: [], plugins: ["some-plugin"], prompt: nil},
                 config_dir
               )
    end

    test "does NOT write the persona prompt even when installing the skill (seed-copy provides it)",
         %{config_dir: config_dir} do
      # The per-agent config_dir inherits the persona via HomeRuntime's
      # seed-sandbox copy; install writing it would duplicate it. So the
      # post-install CLAUDE.md carries the hint but NOT the persona body.
      sandbox_content = %{
        skills: ["ezagent-session-orchestrator"],
        plugins: [],
        prompt: OrchestratorRole.persona()
      }

      assert :ok = Bootstrap.install_role_sandbox(sandbox_content, config_dir)
      claude_md = File.read!(Path.join(config_dir, "CLAUDE.md"))
      assert claude_md =~ @hint
      refute claude_md =~ "You are an Ezagent session orchestrator"
    end
  end

  describe "resolve_orchestrator_role/0 — registry lookup → sandbox_content (RF-9)" do
    test "yields the orchestrator skill + persona, no flavor" do
      # role-as-data (RF-9): resolve looks the recipe up BY NAME read-through over
      # ConfigStore (boot SEEDS it; boot's DB seed is :test-skipped). Seed it
      # explicitly here in the DataCase sandbox + flush the cache so the test
      # exercises the real ConfigStore-sourced path.
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      :ok = Ezagent.Agent.RoleRegistry.flush_cache()
      assert {:ok, _} = Ezagent.Agent.RoleRegistry.seed_role_if_absent(OrchestratorRole.recipe())

      assert {:ok, sandbox_content} = Bootstrap.resolve_orchestrator_role()
      assert "ezagent-session-orchestrator" in sandbox_content.skills
      assert sandbox_content.prompt == OrchestratorRole.persona()
    end

    test "fails closed when the orchestrator role is not seeded" do
      # No production fallback to a bespoke compose masks an empty store
      # (let-it-crash) — an unseeded role surfaces as `{:role_unresolved,
      # {:role_not_registered, _}}`, which `try_apply/3` degrades to a plain cc
      # spawn + telemetry. The store is ConfigStore (the DataCase sandbox is
      # EMPTY — nothing seeded this test); flush the ETS cache so a prior test's
      # cached entry cannot mask the miss, then drive the fail-closed branch.
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      name = OrchestratorRole.name()
      :ok = Ezagent.Agent.RoleRegistry.flush_cache()

      assert {:error, {:role_unresolved, {:role_not_registered, ^name}}} =
               Bootstrap.resolve_orchestrator_role()
    end
  end
end
