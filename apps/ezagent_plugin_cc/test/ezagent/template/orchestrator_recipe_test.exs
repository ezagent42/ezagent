defmodule Ezagent.PluginCc.Template.OrchestratorRecipeTest do
  @moduledoc """
  Acceptance tests for SPEC
  `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  Gap B + skill-distribution P3 — cc Template Class resolves the
  `ezagent-session-orchestrator` role and appends its hint, while skill bytes are
  materialized by `Ezagent.Credential.HomeRuntime` inside the atomic config_dir swap.

  Maps to the SPEC's Acceptance Criteria table:

    * B1: Orchestrator bootstrap does not post-copy skill bytes; the P3
      materializer owns `<config_dir>/skills/...`.
    * B2: Orchestrator agent's `<config_dir>/CLAUDE.md` contains the
      skill-load hint line (verbatim per `orchestrator_hint_line/0`).
    * B3: Default-role cc agent (role omitted) does NOT get the skill
      copied.
    * B4: Idempotent re-application doesn't duplicate the CLAUDE.md
      hint line.

  We exercise `apply_orchestrator_recipe_bootstrap/2` directly because the
  full `instantiate/3` path requires a PtyServer + claude executable
  on PATH, which the e2e suite covers. Bootstrap is a pure
  filesystem helper — unit-testable in a tmp dir.
  """

  # role-as-data (#1048): `bootstrap/2`/`try_role_bootstrap/3` resolve the
  # orchestrator role recipe read-through over `ConfigStore` (via
  # `RecipeRegistry.lookup/1`), so the suite needs the Ecto sandbox checked out for
  # the test process. The pure-FS / helper tests ignore it. (Boot's DB role seed
  # is skipped in `:test`; we seed explicitly in `setup` inside the sandbox.)
  use EzagentCore.DataCase, async: false

  alias Ezagent.Orchestrator.OrchestratorRecipe
  alias Ezagent.PluginCc.Template.CcAgent

  @hint CcAgent.orchestrator_hint_line()

  setup do
    # role-as-data: seed the orchestrator role into the test's sandbox so the
    # bootstrap's `resolve_orchestrator_recipe/0` read-through resolves it. Flush
    # the ETS cache first so a prior test's cached entry can't mask the
    # ConfigStore-sourced path (ETS is process-global; the sandbox is per-test).
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok = Ezagent.Agent.RecipeRegistry.flush_cache()
    {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(OrchestratorRecipe.recipe())

    # ETS is process-global but the seeded ConfigStore row is rolled back with
    # the per-test sandbox. Flush on exit too so a role cached by this test's
    # `lookup/1` cannot leak into a later module that asserts an unseeded miss
    # without its own flush (hermetic fixture).
    on_exit(fn -> Ezagent.Agent.RecipeRegistry.flush_cache() end)

    config_dir =
      Path.join(System.tmp_dir!(), "orch-cfg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(config_dir)

    on_exit(fn ->
      _ = File.rm_rf(config_dir)
    end)

    {:ok, config_dir: config_dir}
  end

  describe "B1 — bootstrap no longer post-copies skills" do
    test "SKILL.md is not copied by apply_orchestrator_recipe_bootstrap/2",
         %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)

      refute File.exists?(Path.join(config_dir, "skills"))
    end
  end

  describe "B2 — CLAUDE.md hint line appended" do
    test "creates CLAUDE.md if absent + appends the hint", %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)

      assert {:ok, content} = File.read(Path.join(config_dir, "CLAUDE.md"))
      assert String.contains?(content, @hint)
    end

    test "appends after existing content with a separating newline", %{config_dir: config_dir} do
      File.write!(Path.join(config_dir, "CLAUDE.md"), "operator preamble\n")

      tmpl = %{"role" => "orchestrator"}
      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)

      content = File.read!(Path.join(config_dir, "CLAUDE.md"))
      assert String.starts_with?(content, "operator preamble\n")
      assert String.contains?(content, @hint)
    end

    test "operator content WITHOUT trailing newline still gets a separator", %{
      config_dir: config_dir
    } do
      File.write!(Path.join(config_dir, "CLAUDE.md"), "operator preamble (no trailing nl)")

      tmpl = %{"role" => "orchestrator"}
      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)

      content = File.read!(Path.join(config_dir, "CLAUDE.md"))
      # The hint should be on its own line, not concatenated to the
      # preamble.
      assert content =~
               ~r/preamble \(no trailing nl\)\n## Use the ezagent-session-orchestrator skill/
    end
  end

  describe "B3 — default-role agent gets NO skill / NO hint" do
    test "role omitted = no skills dir and no hint", %{config_dir: config_dir} do
      tmpl = %{}
      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)

      refute File.dir?(Path.join(config_dir, "skills"))
      refute File.exists?(Path.join(config_dir, "CLAUDE.md"))
    end

    test "role=\"default\" explicit = no skills dir created", %{config_dir: config_dir} do
      tmpl = %{"role" => "default"}
      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)

      refute File.dir?(Path.join(config_dir, "skills"))
    end

    test "nil config_dir = no-op even for orchestrator role" do
      tmpl = %{"role" => "orchestrator"}
      # When the template has no `config_dir` reference,
      # `create_agent_config_dir/2` returns `{:ok, nil}` and the
      # bootstrap is skipped.
      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, nil)
    end
  end

  describe "B4 — idempotent re-bootstrap" do
    test "re-running does NOT duplicate the CLAUDE.md hint", %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)
      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)
      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)

      content = File.read!(Path.join(config_dir, "CLAUDE.md"))

      occurrences =
        content
        |> String.split(@hint)
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1,
             "expected exactly 1 hint occurrence after 3 calls, got #{occurrences}\ncontent:\n#{content}"
    end

    test "re-running leaves existing materialized skill dirs untouched",
         %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      sentinel =
        Path.join([config_dir, "skills", "ezagent-session-orchestrator", "_local_marker"])

      File.mkdir_p!(Path.dirname(sentinel))
      File.write!(sentinel, "local edit\n")

      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)
      assert :ok = CcAgent.apply_orchestrator_recipe_bootstrap(tmpl, config_dir)
      assert File.regular?(sentinel)
    end
  end

  describe "orchestrator_recipe?/1 helper" do
    test "true for role=orchestrator (string)" do
      assert CcAgent.orchestrator_recipe?(%{"role" => "orchestrator"})
    end

    # codex PR #408 review LOW — atom-form role under string-key "role"
    # also reads true. This is the ingress-normalization shape.
    test "true for role=:orchestrator (atom value under string key)" do
      assert CcAgent.orchestrator_recipe?(%{"role" => :orchestrator})
    end

    test "false for absent / default / unrelated" do
      refute CcAgent.orchestrator_recipe?(%{})
      refute CcAgent.orchestrator_recipe?(%{"role" => "default"})
      refute CcAgent.orchestrator_recipe?(%{"role" => :default})
      refute CcAgent.orchestrator_recipe?(%{"role" => "unknown"})
      # Atom-keyed map (`%{role: :orchestrator}`) is NOT the canonical
      # template shape — templates are string-keyed maps post-validate.
      # We deliberately do not coerce atom-key lookups to keep the
      # canonical shape sharp.
      refute CcAgent.orchestrator_recipe?(%{role: :orchestrator})
    end
  end

  describe "LOW (PR #408 review) — validator accepts string + atom role" do
    test "validate/1 accepts role=\"orchestrator\" (string)" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://system/agent/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => "orchestrator"
      }

      assert :ok = CcAgent.validate(tmpl)
    end

    test "validate/1 accepts role=:orchestrator (atom)" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://system/agent/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => :orchestrator
      }

      assert :ok = CcAgent.validate(tmpl)
    end

    test "validate/1 accepts role=\"default\" (string)" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://system/agent/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => "default"
      }

      assert :ok = CcAgent.validate(tmpl)
    end

    test "validate/1 accepts role=:default (atom)" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://system/agent/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => :default
      }

      assert :ok = CcAgent.validate(tmpl)
    end

    test "validate/1 rejects unknown role value" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://system/agent/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => "admin"
      }

      assert {:error, {:invalid_role, "admin"}} = CcAgent.validate(tmpl)
    end

    test "validate/1 omits the role field cleanly" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://system/agent/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!()
      }

      assert :ok = CcAgent.validate(tmpl)
    end
  end

  describe "HIGH-3 (PR #408 review) — try_role_bootstrap returns degraded meta on failure" do
    test "returns {:ok, %{role_degraded: true, role_degraded_reason: _}} when role lookup fails",
         %{config_dir: config_dir} do
      name = OrchestratorRecipe.name()
      :ok = Ezagent.Agent.RecipeRegistry.flush_cache()
      :ok = Ezagent.Agent.RecipeRegistry.retire_role(name)

      tmpl = %{"role" => "orchestrator"}
      agent_uri = URI.new!("entity://system/agent/cc_orch-#{System.unique_integer([:positive])}")

      assert {:ok, %{role_degraded: true, role_degraded_reason: reason}} =
               CcAgent.try_role_bootstrap(tmpl, config_dir, agent_uri)

      assert {:role_unresolved, {:role_not_registered, ^name}} = reason
    end

    test "returns {:ok, %{}} when role is default (no bootstrap to attempt)",
         %{config_dir: config_dir} do
      tmpl = %{"role" => "default"}
      agent_uri = URI.new!("entity://system/agent/cc_orch-#{System.unique_integer([:positive])}")

      assert {:ok, meta} = CcAgent.try_role_bootstrap(tmpl, config_dir, agent_uri)
      refute Map.has_key?(meta, :role_degraded)
    end

    test "returns {:ok, %{}} when orchestrator role succeeds",
         %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}
      agent_uri = URI.new!("entity://system/agent/cc_orch-#{System.unique_integer([:positive])}")

      assert {:ok, meta} = CcAgent.try_role_bootstrap(tmpl, config_dir, agent_uri)
      refute Map.has_key?(meta, :role_degraded)
    end

    test "telemetry event fires on bootstrap failure",
         %{config_dir: config_dir} do
      name = OrchestratorRecipe.name()
      :ok = Ezagent.Agent.RecipeRegistry.flush_cache()
      :ok = Ezagent.Agent.RecipeRegistry.retire_role(name)

      tmpl = %{"role" => "orchestrator"}
      agent_uri = URI.new!("entity://system/agent/cc_orch-#{System.unique_integer([:positive])}")

      handler = "role-bootstrap-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ezagent, :cc, :role_bootstrap, :failed],
        fn _name, _measurements, metadata, pid -> send(pid, {:telemetry_event, metadata}) end,
        self()
      )

      assert {:ok, %{role_degraded: true}} =
               CcAgent.try_role_bootstrap(tmpl, config_dir, agent_uri)

      assert_receive {:telemetry_event, %{agent_uri: ^agent_uri, reason: _, config_dir: _}}, 1_000

      :telemetry.detach(handler)
    end
  end
end
