defmodule EzagentPluginGitWorkflow.DeterministicRefTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.DeterministicRef
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :deterministic_ref

  describe "derive/2" do
    test "same run id always yields the same ref" do
      run_id = WorkflowRun.generate_id("bnd_1", 1, "task-1")

      assert DeterministicRef.derive("feature/", run_id) ==
               DeterministicRef.derive("feature/", run_id)
    end

    test "ref is namespace <> run- <> first 24 hex chars of the run id digest" do
      run_id = WorkflowRun.generate_id("bnd_1", 1, "task-1")
      "run_" <> digest = run_id

      assert DeterministicRef.derive("feature/", run_id) ==
               "feature/run-" <> String.slice(digest, 0, 24)
    end

    test "different runs yield different refs" do
      run_id_a = WorkflowRun.generate_id("bnd_1", 1, "task-1")
      run_id_b = WorkflowRun.generate_id("bnd_1", 1, "task-2")

      refute DeterministicRef.derive("feature/", run_id_a) ==
               DeterministicRef.derive("feature/", run_id_b)
    end

    test "different namespaces yield different refs for the same run" do
      run_id = WorkflowRun.generate_id("bnd_1", 1, "task-1")

      refute DeterministicRef.derive("feature/", run_id) ==
               DeterministicRef.derive("hotfix/", run_id)
    end
  end
end
