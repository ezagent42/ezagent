defmodule Ezagent.PluginCc.Template.SkillColdSpawnRegressionTest do
  use ExUnit.Case, async: false

  alias Ezagent.Home.SkillSeed
  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.SkillRegistry

  @skill_ref "ezagent-session-orchestrator"

  setup do
    source = tmp_dir("seed-source")
    runtime = tmp_dir("runtime")
    reference = tmp_dir("reference")

    write!(Path.join(source, "#{@skill_ref}/SKILL.md"), "release skill v1\n")
    write!(Path.join(reference, ".credentials.json"), "{}")

    SkillRegistry.reset!()
    SkillSeed.boot!(source: source, dest: runtime, index?: false)

    on_exit(fn ->
      SkillRegistry.reset!()
      File.rm_rf!(source)
      File.rm_rf!(runtime)
      File.rm_rf!(reference)
    end)

    {:ok, reference: reference, runtime: runtime}
  end

  test "cold spawn on a fresh home materializes recipe skills into the swapped config_dir",
       %{reference: reference} do
    agent_uri = agent_uri("cold")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    tmpl = template(reference, target, [@skill_ref])

    assert {:ok, ^target} = CcAgent.create_agent_config_dir(agent_uri, tmpl)

    assert File.read!(Path.join([target, "skills", @skill_ref, "SKILL.md"])) ==
             "release skill v1\n"
  end

  test "materialized config_dir has one completion marker with skills inside the same swap",
       %{reference: reference} do
    agent_uri = agent_uri("marker")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    assert {:ok, ^target} =
             CcAgent.create_agent_config_dir(agent_uri, template(reference, target))

    assert File.regular?(Path.join([target, "skills", @skill_ref, "SKILL.md"]))

    markers =
      target
      |> all_files()
      |> Enum.filter(&(Path.basename(&1) == ".ezagent-config-complete"))
      |> Enum.sort()

    assert markers == [Path.join(target, ".ezagent-config-complete")]
  end

  test "re-materialization after a runtime skill upgrade replaces old skill bytes",
       %{reference: reference, runtime: runtime} do
    agent_uri = agent_uri("upgrade")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    assert {:ok, ^target} =
             CcAgent.create_agent_config_dir(agent_uri, template(reference, target))

    assert File.read!(Path.join([target, "skills", @skill_ref, "SKILL.md"])) =~ "v1"

    write!(Path.join(runtime, "#{@skill_ref}/SKILL.md"), "release skill v2\n")
    SkillRegistry.refresh!(runtime_dir: runtime)
    File.rm!(Path.join(target, ".ezagent-config-complete"))

    assert {:ok, ^target} =
             CcAgent.create_agent_config_dir(agent_uri, template(reference, target))

    assert File.read!(Path.join([target, "skills", @skill_ref, "SKILL.md"])) ==
             "release skill v2\n"
  end

  test "re-materialization after skill removal drops stale per-agent skill dirs",
       %{reference: reference} do
    agent_uri = agent_uri("remove")
    target = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(target) end)

    assert {:ok, ^target} =
             CcAgent.create_agent_config_dir(agent_uri, template(reference, target))

    assert File.dir?(Path.join([target, "skills", @skill_ref]))

    File.rm!(Path.join(target, ".ezagent-config-complete"))

    assert {:ok, ^target} =
             CcAgent.create_agent_config_dir(agent_uri, template(reference, target, []))

    refute File.exists?(Path.join(target, "skills"))
  end

  defp template(reference, target, skills \\ [@skill_ref]) do
    %{
      "config_dir" => reference,
      "allocated_config_dir" => target,
      "sandbox_content" => %{skills: skills}
    }
  end

  defp agent_uri(tag) do
    URI.new!("entity://system/agent/cc_skill_#{tag}_#{System.unique_integer([:positive])}")
  end

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "skill-cold-#{tag}-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  defp all_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn child ->
      path = Path.join(dir, child)

      if File.dir?(path) do
        all_files(path)
      else
        [path]
      end
    end)
  end
end
