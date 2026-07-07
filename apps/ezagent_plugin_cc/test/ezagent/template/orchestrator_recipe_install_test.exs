defmodule Ezagent.PluginCc.Template.OrchestratorRecipeInstallTest do
  @moduledoc """
  Task #54 PR-2 — the resolve / install split of the orchestrator role loader.

  `Ezagent.PluginCc.Template.OrchestratorBootstrap` now installs whatever the
  composed role recipe yields, not a hardcoded skill. These tests pin the two
  decoupled stages directly:

    * `install_role_sandbox/2` — pure filesystem, driven by an EXPLICIT skills
      list (so the installer is exercised independently of the recipe);
    * `resolve_orchestrator_recipe/0` — composes the code recipe into
      `sandbox_content` (skills + persona prompt).
  """
  # role-as-data: `resolve_orchestrator_recipe/0` now resolves the role read-through
  # over ConfigStore, so the suite needs the DataCase sandbox. The pure
  # `install_role_sandbox/2` (filesystem) tests ignore it.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Orchestrator.OrchestratorRecipe
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
        prompt: OrchestratorRecipe.persona()
      }

      assert :ok = Bootstrap.install_role_sandbox(sandbox_content, config_dir)
      claude_md = File.read!(Path.join(config_dir, "CLAUDE.md"))
      assert claude_md =~ @hint
      refute claude_md =~ "You are an Ezagent session orchestrator"
    end
  end

  describe "resolve_orchestrator_recipe/0 — registry lookup → sandbox_content (RF-9)" do
    test "yields the orchestrator skill + persona, no flavor" do
      # role-as-data (RF-9): resolve looks the recipe up BY NAME read-through over
      # ConfigStore (boot SEEDS it; boot's DB seed is :test-skipped). Seed it
      # explicitly here in the DataCase sandbox + flush the cache so the test
      # exercises the real ConfigStore-sourced path.
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      :ok = Ezagent.Agent.RecipeRegistry.flush_cache()

      assert {:ok, _} =
               Ezagent.Agent.RecipeRegistry.seed_role_if_absent(OrchestratorRecipe.recipe())

      assert {:ok, sandbox_content} = Bootstrap.resolve_orchestrator_recipe()
      assert "ezagent-session-orchestrator" in sandbox_content.skills
      assert sandbox_content.prompt == OrchestratorRecipe.persona()
    end

    test "fails closed when the orchestrator role is not seeded" do
      # No production fallback to a bespoke compose masks an empty store
      # (let-it-crash) — an unseeded role surfaces as `{:role_unresolved,
      # {:role_not_registered, _}}`, which `try_apply/3` degrades to a plain cc
      # spawn + telemetry. The store is ConfigStore (the DataCase sandbox is
      # EMPTY — nothing seeded this test); flush the ETS cache so a prior test's
      # cached entry cannot mask the miss, then drive the fail-closed branch.
      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      name = OrchestratorRecipe.name()
      :ok = Ezagent.Agent.RecipeRegistry.flush_cache()
      :ok = Ezagent.Agent.RecipeRegistry.retire_role(name)

      on_exit(fn ->
        _ = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(OrchestratorRecipe.recipe())
      end)

      assert {:error, {:role_unresolved, {:role_not_registered, ^name}}} =
               Bootstrap.resolve_orchestrator_recipe()
    end
  end

  # Phase 3 ③ T2 (2026-06-28) — the install gate is generalized over the agent's
  # ACTUAL role, not hardcoded to `orchestrator`. A cc-headless agent whose
  # template carries ANY registered role (pm coordinator, dev-together
  # methodology, …) must get that role's skills copied into its `config_dir`.
  describe "bootstrap/2 — generalized over the agent's role (T2)" do
    setup %{config_dir: config_dir} do
      # A NON-orchestrator role with its OWN skill ref, sourced via the generic
      # per-ref override (mirrors the orchestrator-specific override) so the test
      # exercises a genuinely distinct role + skill, not the orchestrator one.
      suffix = System.unique_integer([:positive])
      role_name = "pm-fixture-#{suffix}"
      skill_ref = "pm-coordinator-fixture-#{suffix}"

      fixture_root = Path.join(System.tmp_dir!(), "t2-skill-#{suffix}")
      skill_src = Path.join(fixture_root, skill_ref)
      File.mkdir_p!(skill_src)
      File.write!(Path.join(skill_src, "SKILL.md"), "pm coordinator fixture skill\n")
      Application.put_env(:ezagent_plugin_cc, :role_skill_sources, %{skill_ref => skill_src})

      {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
      :ok = Ezagent.Agent.RecipeRegistry.flush_cache()

      {:ok, _} =
        Ezagent.Agent.RecipeRegistry.seed_role_if_absent(%{
          name: role_name,
          skills: [skill_ref],
          prompt: "you are pm",
          behaviors: [],
          requested_caps: [],
          session_template: nil
        })

      on_exit(fn ->
        Application.delete_env(:ezagent_plugin_cc, :role_skill_sources)
        _ = File.rm_rf(fixture_root)
      end)

      {:ok, config_dir: config_dir, role_name: role_name, skill_ref: skill_ref}
    end

    test "a NON-orchestrator role's skill is copied into config_dir/skills/<ref>",
         %{config_dir: config_dir, role_name: role_name, skill_ref: skill_ref} do
      # Pre-T2 this was a no-op (bootstrap gated on `orchestrator_recipe?/1`) and the
      # skill never landed — this is the regression-earning assertion.
      assert :ok = Bootstrap.bootstrap(%{"role" => role_name}, config_dir)

      assert File.regular?(Path.join([config_dir, "skills", skill_ref, "SKILL.md"]))

      # The orchestrator-specific CLAUDE.md hint is derived from the orchestrator
      # skill ref, so a different role leaves no stale orchestrator hint.
      claude_md = Path.join(config_dir, "CLAUDE.md")
      refute File.exists?(claude_md) and File.read!(claude_md) =~ @hint
    end

    test "an absent / default role stays a no-op (legacy cc agents unaffected)",
         %{config_dir: config_dir} do
      assert :ok = Bootstrap.bootstrap(%{"role" => "default"}, config_dir)
      assert :ok = Bootstrap.bootstrap(%{}, config_dir)
      refute File.dir?(Path.join(config_dir, "skills"))
    end

    test "role_name/1 extracts the installable role name (nil for absent/default)" do
      assert "orchestrator" = Bootstrap.role_name(%{"role" => "orchestrator"})
      assert "orchestrator" = Bootstrap.role_name(%{"role" => :orchestrator})
      assert "pm" = Bootstrap.role_name(%{"role" => "pm"})
      assert nil == Bootstrap.role_name(%{"role" => "default"})
      assert nil == Bootstrap.role_name(%{"role" => :default})
      assert nil == Bootstrap.role_name(%{"role" => ""})
      assert nil == Bootstrap.role_name(%{})
    end
  end
end
