defmodule Ezagent.PluginCc.Template.OrchestratorRoleTest do
  @moduledoc """
  Acceptance tests for SPEC
  `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  Gap B — cc Template Class loads the `ezagent-session-orchestrator`
  skill into the per-agent config dir when `role: "orchestrator"`.

  Maps to the SPEC's Acceptance Criteria table:

    * B1: Orchestrator agent's `<config_dir>/skills/ezagent-session-orchestrator/SKILL.md`
      exists after `apply_orchestrator_role_bootstrap`.
    * B2: Orchestrator agent's `<config_dir>/CLAUDE.md` contains the
      skill-load hint line (verbatim per `orchestrator_hint_line/0`).
    * B3: Default-role cc agent (role omitted) does NOT get the skill
      copied.
    * B4: Idempotent re-application doesn't duplicate the CLAUDE.md
      hint line.

  We exercise `apply_orchestrator_role_bootstrap/2` directly because the
  full `instantiate/3` path requires a PtyServer + claude executable
  on PATH, which the e2e suite covers. Bootstrap is a pure
  filesystem helper — unit-testable in a tmp dir.
  """

  use ExUnit.Case, async: false

  alias Ezagent.PluginCc.Template.CcAgent

  @hint CcAgent.orchestrator_hint_line()

  setup do
    # Stage a fake umbrella-root skill source in a temp dir so the
    # test doesn't depend on the real `.claude/skills/...` (which a
    # CI build might not ship). Override the
    # `:orchestrator_skill_source` app env to point at it.
    fixture_root = Path.join(System.tmp_dir!(), "orch-skill-#{System.unique_integer([:positive])}")
    skill_src = Path.join(fixture_root, "ezagent-session-orchestrator")
    File.mkdir_p!(skill_src)
    File.write!(Path.join(skill_src, "SKILL.md"), "fixture skill\n")
    File.write!(Path.join(skill_src, "AUX.md"), "fixture aux\n")

    Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, skill_src)

    config_dir =
      Path.join(System.tmp_dir!(), "orch-cfg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(config_dir)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_cc, :orchestrator_skill_source)
      _ = File.rm_rf(fixture_root)
      _ = File.rm_rf(config_dir)
    end)

    {:ok, config_dir: config_dir, skill_src: skill_src}
  end

  describe "B1 — orchestrator role copies skill into per-agent config dir" do
    test "SKILL.md ends up at <config_dir>/skills/ezagent-session-orchestrator/SKILL.md",
         %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      assert File.regular?(
               Path.join([
                 config_dir,
                 "skills",
                 "ezagent-session-orchestrator",
                 "SKILL.md"
               ])
             )
    end

    test "every file from the source tree is copied", %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      assert File.regular?(
               Path.join([
                 config_dir,
                 "skills",
                 "ezagent-session-orchestrator",
                 "AUX.md"
               ])
             )
    end
  end

  describe "B2 — CLAUDE.md hint line appended" do
    test "creates CLAUDE.md if absent + appends the hint", %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      assert {:ok, content} = File.read(Path.join(config_dir, "CLAUDE.md"))
      assert String.contains?(content, @hint)
    end

    test "appends after existing content with a separating newline", %{config_dir: config_dir} do
      File.write!(Path.join(config_dir, "CLAUDE.md"), "operator preamble\n")

      tmpl = %{"role" => "orchestrator"}
      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      content = File.read!(Path.join(config_dir, "CLAUDE.md"))
      assert String.starts_with?(content, "operator preamble\n")
      assert String.contains?(content, @hint)
    end

    test "operator content WITHOUT trailing newline still gets a separator", %{
      config_dir: config_dir
    } do
      File.write!(Path.join(config_dir, "CLAUDE.md"), "operator preamble (no trailing nl)")

      tmpl = %{"role" => "orchestrator"}
      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      content = File.read!(Path.join(config_dir, "CLAUDE.md"))
      # The hint should be on its own line, not concatenated to the
      # preamble.
      assert content =~ ~r/preamble \(no trailing nl\)\n## Use the ezagent-session-orchestrator skill/
    end
  end

  describe "B3 — default-role agent gets NO skill / NO hint" do
    test "role omitted = no skills dir created", %{config_dir: config_dir} do
      tmpl = %{}
      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      refute File.dir?(Path.join(config_dir, "skills"))
      refute File.exists?(Path.join(config_dir, "CLAUDE.md"))
    end

    test "role=\"default\" explicit = no skills dir created", %{config_dir: config_dir} do
      tmpl = %{"role" => "default"}
      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      refute File.dir?(Path.join(config_dir, "skills"))
    end

    test "nil config_dir = no-op even for orchestrator role" do
      tmpl = %{"role" => "orchestrator"}
      # When the template has no `claude_config_dir` reference,
      # `create_agent_config_dir/2` returns `{:ok, nil}` and the
      # bootstrap is skipped.
      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, nil)
    end
  end

  describe "B4 — idempotent re-bootstrap" do
    test "re-running does NOT duplicate the CLAUDE.md hint", %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)
      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)
      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      content = File.read!(Path.join(config_dir, "CLAUDE.md"))

      occurrences =
        content
        |> String.split(@hint)
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1,
             "expected exactly 1 hint occurrence after 3 calls, got #{occurrences}\ncontent:\n#{content}"
    end

    test "re-running with skill dir already present is a no-op", %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}

      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)

      # Touch a sentinel file inside the skill dir; if the second
      # call re-copied (overwriting), the sentinel would disappear.
      sentinel =
        Path.join([config_dir, "skills", "ezagent-session-orchestrator", "_local_marker"])

      File.write!(sentinel, "local edit\n")

      assert :ok = CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)
      assert File.regular?(sentinel)
    end
  end

  describe "missing skill source error path" do
    test "returns {:error, {:skill_source_missing, _}} when override points nowhere",
         %{config_dir: config_dir} do
      Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, "/nope/does/not/exist")

      tmpl = %{"role" => "orchestrator"}

      assert {:error, {:skill_source_missing, "/nope/does/not/exist"}} =
               CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)
    end
  end

  describe "orchestrator_role?/1 helper" do
    test "true for role=orchestrator" do
      assert CcAgent.orchestrator_role?(%{"role" => "orchestrator"})
    end

    test "false for absent / default / unrelated" do
      refute CcAgent.orchestrator_role?(%{})
      refute CcAgent.orchestrator_role?(%{"role" => "default"})
      refute CcAgent.orchestrator_role?(%{"role" => "unknown"})
      refute CcAgent.orchestrator_role?(%{role: :orchestrator})
    end
  end
end
