defmodule Ezagent.PluginCc.Template.SkillRoleResolveGuardTest do
  @moduledoc """
  Acceptance-fix regression (2026-07-09) — gates SPEC
  `2026-07-08-skill-distribution-impl.md` §4.1.7 through the PROD guard chain.

  `skill_cold_spawn_regression_test.exs` injects `sandbox_content` directly, so
  `attach_role_sandbox_content/2` no-ops and the chain
  role → `resolve_role/1` → attach guard → HomeRuntime materialize is never
  driven. This file builds the template the way production does — with
  `role: "orchestrator"` and NO pre-set `sandbox_content`
  (`cc_orchestrator_seed.ex` template slice shape) — and pins BOTH directions:

  1. happy path: recipe refs resolve → skill bytes land in the config_dir;
  2. loud-on-miss: with the registry ready but the recipe ref unresolvable,
     the spawn path survives BUT `Logger.error` + the
     `[:ezagent, :skill, :resolve_miss]` telemetry event + the `role_degraded`
     marker (via `try_role_bootstrap/3` role_meta) all fire — never a silent
     skip.
  """
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Home.SkillSeed
  alias Ezagent.Orchestrator.OrchestratorRecipe
  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.SkillRegistry

  @skill_ref "ezagent-session-orchestrator"

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok = RecipeRegistry.flush_cache()

    {:ok, _} = RecipeRegistry.seed_role_if_absent(OrchestratorRecipe.recipe())

    source = tmp_dir("seed-source")
    runtime = tmp_dir("runtime")
    reference = tmp_dir("reference")

    write!(Path.join(source, "#{@skill_ref}/SKILL.md"), "release skill v1\n")
    write!(Path.join(reference, ".credentials.json"), "{}")

    SkillRegistry.reset!()
    SkillSeed.boot!(source: source, dest: runtime, index?: false)

    on_exit(fn ->
      SkillRegistry.reset!()
      :ok = RecipeRegistry.flush_cache()
      File.rm_rf!(source)
      File.rm_rf!(runtime)
      File.rm_rf!(reference)
    end)

    {:ok, reference: reference}
  end

  test "prod-shaped role template: recipe refs resolve and skill bytes land in the config_dir",
       %{reference: reference} do
    agent_uri = agent_uri("role-happy")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    tmpl = prod_template(reference, target)

    assert {:ok, ^target} = CcAgent.create_agent_config_dir(agent_uri, tmpl)

    assert File.read!(Path.join([target, "skills", @skill_ref, "SKILL.md"])) ==
             "release skill v1\n"
  end

  test "unresolvable recipe ref: spawn survives but role_degraded + telemetry + Logger.error fire",
       %{reference: reference} do
    agent_uri = agent_uri("role-miss")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    # Point the registry at an EMPTY runtime origin: ready, zero entries —
    # the packaging-drop / recipe-gained-a-ref-without-regen shape.
    SkillRegistry.reset!()
    empty_runtime = tmp_dir("empty-runtime")
    on_exit(fn -> File.rm_rf!(empty_runtime) end)
    :ok = SkillRegistry.refresh!(runtime_dir: empty_runtime)

    test_pid = self()
    handler_id = "skill-resolve-miss-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:ezagent, :skill, :resolve_miss],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:skill_resolve_miss_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    tmpl = prod_template(reference, target)

    {attached_tmpl, log} =
      with_log(fn ->
        # Mirror the spawn path (`spawn_for_local_pty`): attach first
        # (materialization_template), then materialize with the attached tmpl.
        assert {:ok, attached_tmpl} = CcAgent.attach_role_sandbox_content(tmpl, agent_uri)
        refute Map.has_key?(attached_tmpl, "sandbox_content")

        assert {:ok, ^target} = CcAgent.create_agent_config_dir(agent_uri, attached_tmpl)
        attached_tmpl
      end)

    # (a) spawn survives — config_dir materialized, but no skill bytes.
    refute File.exists?(Path.join([target, "skills", @skill_ref, "SKILL.md"]))

    # (b) Logger.error names the agent, the role, and the exact missing refs.
    assert log =~ "[error]"
    assert log =~ "skill refs did NOT resolve"
    assert log =~ URI.to_string(agent_uri)
    assert log =~ "orchestrator"
    assert log =~ @skill_ref

    # (c) telemetry fires with the miss detail.
    assert_receive {:skill_resolve_miss_telemetry, [:ezagent, :skill, :resolve_miss],
                    %{count: 1}, %{role: "orchestrator", refs: [@skill_ref]}}

    # (d) the existing role_degraded surfacing idiom carries the miss: the
    # spawn path's role_meta (try_role_bootstrap) marks the agent degraded.
    tmpl_with_dir = Map.put(attached_tmpl, "allocated_config_dir", target)
    assert {:ok, role_meta} = CcAgent.try_role_bootstrap(tmpl_with_dir, target, agent_uri)
    assert role_meta.role_degraded == true

    assert {:skill_resolve_miss, %{role: "orchestrator", refs: [@skill_ref]}} =
             role_meta.role_degraded_reason
  end

  # The prod template shape (`cc_orchestrator_seed.ex` template slice →
  # `to_template_data`): a "role" key, NO pre-set "sandbox_content".
  defp prod_template(reference, target) do
    %{
      "config_dir" => reference,
      "allocated_config_dir" => target,
      "role" => "orchestrator"
    }
  end

  defp agent_uri(tag) do
    URI.new!("entity://system/agent/cc_skill_#{tag}_#{System.unique_integer([:positive])}")
  end

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "skill-guard-#{tag}-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end
end
