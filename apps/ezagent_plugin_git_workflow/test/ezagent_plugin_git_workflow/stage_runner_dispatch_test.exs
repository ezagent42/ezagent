defmodule EzagentPluginGitWorkflow.StageRunnerDispatchTest do
  @moduledoc """
  The Slice P4c runner driven through the REAL seam — `ExecutionSeam.CapBacked`
  → `Ezagent.Invocation.dispatch/1` → the task-access Kind → the Git
  task-access action set → the adapter/workspace probes.

  `stage_runner_test.exs` scripts the seam, which is what makes its ordering
  and absence claims expressible; the cost is that it proves nothing about the
  arg SHAPES. This file is the other half: every arg key set here is checked by
  the action set's `@allowed_keys`, every `head_ref` by
  `validate_requested_head`, every repository by the policy's own copy, and
  every call by a real signed capability. A runner that assembled the right
  values under the wrong keys passes the scripted suite and fails here.
  """

  use EzagentPluginGitWorkflow.GitDispatchCase

  alias Ezagent.DomainGit.WorkspaceChangeRegistry
  alias Ezagent.DomainGit.WorkspaceProvisionRegistry
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.GitAdapterProbe
  alias EzagentPluginGitWorkflow.PolicyDerivation
  alias EzagentPluginGitWorkflow.ReadyWorkspaceProbe
  alias EzagentPluginGitWorkflow.StageRunner
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowFacts
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :stage_runner

  setup %{binding: binding, run: fixture_run, policy: fixture_policy, task_access_uri: uri} do
    restore = install_workspace_probes()
    on_exit(restore)

    :ok = ExecutionSeamTestDelegate.put_backend(CapBacked)
    on_exit(fn -> ExecutionSeamTestDelegate.clear_backend() end)

    {:ok, _} = Store.register_binding(binding)

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: binding.id,
        binding_generation: binding.generation,
        external_task_id: fixture_run.external_task_id,
        source_task_uri: fixture_run.source_task_uri,
        source_revision: nil,
        requested_head_ref: nil
      })

    {:ok, accepted} = Store.accept(intent)
    {:ok, run} = Store.transition(accepted.id, accepted.state_version, "accepted", "authorized")

    # The policy the runner will derive comes from the DB rows, not from the
    # fixture structs. If those two ever disagreed the task-access URI would
    # differ, a second Kind would be spawned, and the case template's teardown
    # would leak one — so this is asserted rather than assumed.
    {:ok, policy} = PolicyDerivation.derive(run, binding)
    assert GitTaskAccess.uri_from_args(policy) == uri
    assert policy == fixture_policy

    %{run: run, policy: policy}
  end

  defp install_workspace_probes do
    provision_original = WorkspaceProvisionRegistry.implementation()
    change_original = WorkspaceChangeRegistry.implementation()

    :ok = WorkspaceProvisionRegistry.replace_for_test(ReadyWorkspaceProbe)
    :ok = WorkspaceChangeRegistry.replace_for_test(ReadyWorkspaceProbe)

    fn ->
      restore_registry(WorkspaceProvisionRegistry, provision_original)
      restore_registry(WorkspaceChangeRegistry, change_original)
    end
  end

  defp restore_registry(registry, {:ok, implementation}),
    do: :ok = registry.replace_for_test(implementation)

  defp restore_registry(registry, {:error, _not_registered}),
    do: :ok = registry.replace_for_test(nil)

  defp advance!(run_id) do
    assert {:ok, run} = StageRunner.advance(run_id)
    run
  end

  describe "authorized → pr_open through real dispatch" do
    test "each stage advances and the adapter is reached only at the last one", %{
      run: run,
      policy: policy
    } do
      assert %WorkflowRun{status: "workspace_ready"} = advance!(run.id)
      # §8's fault injection forbids any provider call before workspace_ready;
      # the probe is the only thing that can report one.
      refute_receive {:git_p4b_adapter_call, _action, _context}

      assert %WorkflowRun{status: "changes_ready"} = advance!(run.id)
      refute_receive {:git_p4b_adapter_call, _action, _context}

      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)
      assert_receive {:git_p4b_adapter_call, :create_change_request, _context}

      assert {:ok,
              %WorkflowFacts{
                workspace_provision_id: provision_id,
                expected_base_sha: base_sha,
                change_digest: "sha256:" <> _,
                deterministic_head_ref: head_ref,
                change_request_state: "open",
                head_sha: head_sha
              }} = Store.read_facts(run.id)

      assert is_binary(provision_id)
      assert base_sha == ReadyWorkspaceProbe.base_commit()
      assert head_ref == policy.allowed_head_ref
      assert head_sha == GitAdapterProbe.head_sha()
    end

    test "no probe value that must not persist reaches any workflow column", %{run: run} do
      Enum.each(1..3, fn _ -> advance!(run.id) end)

      for table <- ~w(git_workflow_facts git_workflow_runs) do
        %{rows: rows} = Repo.query!("SELECT * FROM #{table}")

        refute Enum.any?(List.flatten(rows), fn value ->
                 is_binary(value) and String.contains?(value, ReadyWorkspaceProbe.start_token())
               end)
      end
    end
  end

  describe "idempotency" do
    setup %{run: run} do
      Enum.each(1..3, fn _ -> advance!(run.id) end)
      {:ok, facts} = Store.read_facts(run.id)
      %{first_pass: facts}
    end

    test "a run at pr_open owes no further stage and reaches no adapter", %{run: run} do
      assert_receive {:git_p4b_adapter_call, :create_change_request, _context}

      assert {:error, {:unexpected_status, "pr_open"}} = StageRunner.advance(run.id)

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "replaying all three stages reproduces every fact, in exactly one row", %{
      run: run,
      first_pass: first_pass
    } do
      # Rewinding a completed run is an operator action, not a runner one, so
      # it is done here directly: the point is that the SAME run replaying the
      # SAME stages against the SAME durable inputs lands on the same facts.
      rewind_to!(run.id, "authorized")

      Enum.each(1..3, fn _ -> advance!(run.id) end)

      {:ok, replayed} = Store.read_facts(run.id)

      # `id` and `inserted_at` prove the row was UPDATED, not replaced —
      # `upsert_facts`' ON CONFLICT clause excludes both.
      assert replayed.id == first_pass.id
      assert replayed.inserted_at == first_pass.inserted_at
      assert replayed.workspace_provision_id == first_pass.workspace_provision_id
      assert replayed.expected_base_sha == first_pass.expected_base_sha
      assert replayed.change_digest == first_pass.change_digest
      assert replayed.deterministic_head_ref == first_pass.deterministic_head_ref
      assert replayed.change_request_id == first_pass.change_request_id
      assert replayed.head_sha == first_pass.head_sha

      %{rows: [[count]]} =
        Repo.query!("SELECT COUNT(*) FROM git_workflow_facts WHERE run_id = $1", [run.id])

      assert count == 1

      # The adapter DID see a second create — P3's adapter is idempotent by
      # design, and the value above proves the runner did not defeat that by
      # varying its inputs. (`stage_runner_test.exs` asserts the INPUTS are
      # byte-identical; the seam is where those are observable.)
      assert_receive {:git_p4b_adapter_call, :create_change_request, _first}
      assert_receive {:git_p4b_adapter_call, :create_change_request, _second}
    end
  end

  defp rewind_to!(run_id, status) do
    Repo.query!("UPDATE git_workflow_runs SET status = $1 WHERE id = $2", [status, run_id])
    :ok
  end

  describe "resume" do
    test "resuming from workspace_ready reaches pr_open", %{run: run} do
      assert %WorkflowRun{status: "workspace_ready"} = advance!(run.id)

      # A "restart": nothing is carried between calls but the durable rows.
      assert %WorkflowRun{status: "changes_ready"} = advance!(run.id)
      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)
    end

    test "resuming from changes_ready reaches pr_open without a second provision", %{run: run} do
      assert %WorkflowRun{status: "workspace_ready"} = advance!(run.id)
      assert %WorkflowRun{status: "changes_ready"} = advance!(run.id)

      {:ok, before_resume} = Store.read_facts(run.id)

      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)

      {:ok, after_resume} = Store.read_facts(run.id)
      assert after_resume.workspace_provision_id == before_resume.workspace_provision_id
      assert after_resume.expected_base_sha == before_resume.expected_base_sha
      assert after_resume.change_digest == before_resume.change_digest
    end
  end
end
