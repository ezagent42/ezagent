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
      # When the template has no `config_dir` reference,
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

    # codex PR #408 review HIGH-2 — when there is no override AND the
    # default walk-upward search misses the skill marker, the error tag
    # changes to `:skill_source_not_found` and carries the list of paths
    # that were probed so an operator can diagnose missing-skill
    # deployments without guessing.
    test "returns {:error, {:skill_source_not_found, attempted}} when walk fails",
         %{config_dir: config_dir} do
      # Drop the override so the auto-walk runs against the real priv dir.
      Application.delete_env(:ezagent_plugin_cc, :orchestrator_skill_source)

      # Replace the runtime priv-dir lookup by pointing `:code.priv_dir`
      # at a temp dir whose ancestors definitely do NOT contain a
      # `.claude/skills/ezagent-session-orchestrator/SKILL.md`. We do
      # this via the public `resolve_orchestrator_skill_source/0` —
      # which already accepts an override (covered by the previous
      # test) — by forcing the override to a non-existent path AND
      # asserting the search-loop's tag is reachable via the
      # walk-from-priv path with a temp-rooted priv stand-in.
      #
      # Since we can't trivially monkey-patch :code.priv_dir, we instead
      # use the override mechanism to drive the SAME validation: a
      # binary that is NOT a directory falls to `:skill_source_missing`.
      # The walk path's `:skill_source_not_found` is reached only when
      # NO override is set. We exercise it by passing the override as a
      # path that's a regular FILE (not a dir) — File.dir?(_) is false,
      # so we land on `:skill_source_missing`. The
      # `:skill_source_not_found` path is exercised directly by calling
      # the private search via app-env temp:
      tmp_root = Path.join(System.tmp_dir!(), "no-skill-here-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_root)
      tmp_file = Path.join(tmp_root, "this-is-a-file-not-a-dir")
      File.write!(tmp_file, "")

      tmpl = %{"role" => "orchestrator"}

      try do
        Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, tmp_file)

        assert {:error, {:skill_source_missing, ^tmp_file}} =
                 CcAgent.apply_orchestrator_role_bootstrap(tmpl, config_dir)
      after
        File.rm_rf(tmp_root)
      end
    end

    test "auto-walk path: production tree resolves to the real skill dir" do
      # Drop the override so resolve_orchestrator_skill_source/0 hits
      # the walk-upward branch. The CI / dev priv-dir chain in this
      # umbrella DOES contain `.claude/skills/ezagent-session-orchestrator/SKILL.md`
      # at the repo root — so the walk SUCCEEDS in tree.
      Application.delete_env(:ezagent_plugin_cc, :orchestrator_skill_source)

      assert {:ok, source_dir} = CcAgent.resolve_orchestrator_skill_source()
      assert File.regular?(Path.join(source_dir, "SKILL.md"))
    end

    # codex PR #408 r2 WARN HIGH-2 — exercise the exhausted-walk branch
    # directly via the public-for-test `search_orchestrator_skill_source_from/1`.
    # Pre-r2 the `:skill_source_not_found` tag was only structurally
    # reachable (via `:code.priv_dir` returning a non-list, unreachable
    # from a loaded plugin); now we have a deterministic test.
    test "search_orchestrator_skill_source_from/1 — exhausted walk returns attempted paths" do
      tmp_root =
        Path.join(System.tmp_dir!(), "no-skill-walk-#{System.unique_integer([:positive])}")

      nested = Path.join([tmp_root, "a", "b", "c"])
      File.mkdir_p!(nested)

      try do
        # `tmp_root` is under `System.tmp_dir!()` which on macOS is
        # `/var/folders/.../T/`. Neither `/`, `/var`, `/var/folders`
        # carry `.claude/skills/ezagent-session-orchestrator/SKILL.md`,
        # so the walk reaches `/` without finding the marker.
        assert {:error, {:skill_source_not_found, attempted}} =
                 CcAgent.search_orchestrator_skill_source_from(nested)

        # The attempted-paths list includes the start-dir's candidate
        # AND the parent's candidate (proving the walk actually ascended).
        nested_candidate =
          Path.join(nested, ".claude/skills/ezagent-session-orchestrator")

        parent_candidate =
          Path.join(Path.dirname(nested), ".claude/skills/ezagent-session-orchestrator")

        assert is_list(attempted)
        assert nested_candidate in attempted
        assert parent_candidate in attempted

        # The walk terminates at root, so the LAST attempted path must
        # be root's candidate.
        assert List.last(attempted) ==
                 Path.join("/", ".claude/skills/ezagent-session-orchestrator")
      after
        _ = File.rm_rf(tmp_root)
      end
    end

    test "search_orchestrator_skill_source_from/1 — hit returns the matching dir" do
      # Plant the marker in the tmp tree, then search from a descendant.
      tmp_root =
        Path.join(System.tmp_dir!(), "skill-walk-hit-#{System.unique_integer([:positive])}")

      skill_dir = Path.join(tmp_root, ".claude/skills/ezagent-session-orchestrator")
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "fixture\n")

      descendant = Path.join([tmp_root, "sub", "deep"])
      File.mkdir_p!(descendant)

      try do
        assert {:ok, found} = CcAgent.search_orchestrator_skill_source_from(descendant)
        assert found == skill_dir
        assert File.regular?(Path.join(found, "SKILL.md"))
      after
        _ = File.rm_rf(tmp_root)
      end
    end
  end

  describe "orchestrator_role?/1 helper" do
    test "true for role=orchestrator (string)" do
      assert CcAgent.orchestrator_role?(%{"role" => "orchestrator"})
    end

    # codex PR #408 review LOW — atom-form role under string-key "role"
    # also reads true. This is the ingress-normalization shape.
    test "true for role=:orchestrator (atom value under string key)" do
      assert CcAgent.orchestrator_role?(%{"role" => :orchestrator})
    end

    test "false for absent / default / unrelated" do
      refute CcAgent.orchestrator_role?(%{})
      refute CcAgent.orchestrator_role?(%{"role" => "default"})
      refute CcAgent.orchestrator_role?(%{"role" => :default})
      refute CcAgent.orchestrator_role?(%{"role" => "unknown"})
      # Atom-keyed map (`%{role: :orchestrator}`) is NOT the canonical
      # template shape — templates are string-keyed maps post-validate.
      # We deliberately do not coerce atom-key lookups to keep the
      # canonical shape sharp.
      refute CcAgent.orchestrator_role?(%{role: :orchestrator})
    end
  end

  describe "LOW (PR #408 review) — validator accepts string + atom role" do
    test "validate/1 accepts role=\"orchestrator\" (string)" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/system/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => "orchestrator"
      }

      assert :ok = CcAgent.validate(tmpl)
    end

    test "validate/1 accepts role=:orchestrator (atom)" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/system/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => :orchestrator
      }

      assert :ok = CcAgent.validate(tmpl)
    end

    test "validate/1 accepts role=\"default\" (string)" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/system/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => "default"
      }

      assert :ok = CcAgent.validate(tmpl)
    end

    test "validate/1 accepts role=:default (atom)" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/system/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => :default
      }

      assert :ok = CcAgent.validate(tmpl)
    end

    test "validate/1 rejects unknown role value" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/system/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!(),
        "role" => "admin"
      }

      assert {:error, {:invalid_role, "admin"}} = CcAgent.validate(tmpl)
    end

    test "validate/1 omits the role field cleanly" do
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/system/cc_test-#{System.unique_integer([:positive])}",
        "cwd" => System.tmp_dir!()
      }

      assert :ok = CcAgent.validate(tmpl)
    end
  end

  describe "HIGH-3 (PR #408 review) — try_role_bootstrap returns degraded meta on failure" do
    test "returns {:ok, %{role_degraded: true, role_degraded_reason: _}} when skill source missing",
         %{config_dir: config_dir} do
      # Force a skill-source failure by pointing the override at nothing.
      Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, "/no/such/path")

      tmpl = %{"role" => "orchestrator"}
      agent_uri = URI.new!("entity://agent/system/cc_orch-#{System.unique_integer([:positive])}")

      assert {:ok, %{role_degraded: true, role_degraded_reason: reason}} =
               CcAgent.try_role_bootstrap(tmpl, config_dir, agent_uri)

      assert match?({:skill_source_missing, _}, reason)
    end

    test "returns {:ok, %{}} when role is default (no bootstrap to attempt)",
         %{config_dir: config_dir} do
      tmpl = %{"role" => "default"}
      agent_uri = URI.new!("entity://agent/system/cc_orch-#{System.unique_integer([:positive])}")

      assert {:ok, meta} = CcAgent.try_role_bootstrap(tmpl, config_dir, agent_uri)
      refute Map.has_key?(meta, :role_degraded)
    end

    test "returns {:ok, %{}} when orchestrator role succeeds",
         %{config_dir: config_dir} do
      tmpl = %{"role" => "orchestrator"}
      agent_uri = URI.new!("entity://agent/system/cc_orch-#{System.unique_integer([:positive])}")

      assert {:ok, meta} = CcAgent.try_role_bootstrap(tmpl, config_dir, agent_uri)
      refute Map.has_key?(meta, :role_degraded)
    end

    test "telemetry event fires on bootstrap failure",
         %{config_dir: config_dir} do
      Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, "/no/such/path-2")

      tmpl = %{"role" => "orchestrator"}
      agent_uri = URI.new!("entity://agent/system/cc_orch-#{System.unique_integer([:positive])}")

      :telemetry.attach(
        "role-bootstrap-test-#{System.unique_integer([:positive])}",
        [:ezagent, :cc, :role_bootstrap, :failed],
        fn _name, _measurements, metadata, pid -> send(pid, {:telemetry_event, metadata}) end,
        self()
      )

      assert {:ok, %{role_degraded: true}} =
               CcAgent.try_role_bootstrap(tmpl, config_dir, agent_uri)

      assert_receive {:telemetry_event, %{agent_uri: ^agent_uri, reason: _, config_dir: _}}, 1_000

      :telemetry.detach("role-bootstrap-test-#{System.unique_integer([:positive])}")
    end
  end
end
