defmodule EzagentPluginGitWorkflow.StageRunnerTest do
  @moduledoc """
  Stage-by-stage behaviour of the Slice P4c runner against a SCRIPTED seam.

  The scripted seam is what makes the two claims in this file that are about
  ABSENCE and ORDER testable at all: an action can be made to fail exactly
  where the claim is about, and `refute_receive` can prove an action was never
  reached. `stage_runner_dispatch_test.exs` covers the same runner against the
  REAL seam, where the arg shapes and the policy gates are enforced for real.
  """

  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias Ezagent.DomainGit.ChangeRequest
  alias Ezagent.DomainGit.FileChange
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture
  alias EzagentPluginGitWorkflow.PolicyDerivation
  alias EzagentPluginGitWorkflow.ScriptedExecutionSeam
  alias EzagentPluginGitWorkflow.StageRunner
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowFacts
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :stage_runner

  @base_sha String.duplicate("b", 40)
  @head_sha String.duplicate("c", 40)
  @provision_id "prov-p4c-1"

  setup do
    binding = GitTaskAccessFixture.binding()
    {:ok, _} = Store.register_binding(binding)

    attrs = GitTaskAccessFixture.run_attrs()

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: binding.id,
        binding_generation: binding.generation,
        external_task_id: attrs.external_task_id,
        source_task_uri: attrs.source_task_uri,
        source_revision: nil,
        requested_head_ref: nil
      })

    {:ok, run} = Store.accept(intent)
    {:ok, authorized} = Store.transition(run.id, run.state_version, "accepted", "authorized")

    on_exit(fn -> ExecutionSeamTestDelegate.clear_backend() end)

    {:ok, policy} = PolicyDerivation.derive(authorized, binding)

    %{binding: binding, run: authorized, policy: policy}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp changes(contents) do
    Enum.map(contents, fn {path, content} ->
      {:ok, change} = FileChange.new(%{path: path, operation: :upsert, content: content})
      change
    end)
  end

  defp default_changes, do: changes([{"README.md", "p4c"}])

  defp change_request(head_ref) do
    %ChangeRequest{
      external_id: "cr-p4c-1",
      url: URI.parse("https://git.example.test/p4c/pull/1"),
      head_ref: head_ref,
      head_sha: @head_sha,
      base_ref: "main",
      state: :open
    }
  end

  defp provision_result do
    {:ok,
     %{
       status: :ready,
       provision_id: @provision_id,
       task_access_uri: Ezagent.URI.workspace("unused"),
       task_uri: Ezagent.URI.workspace("unused"),
       generation: 1,
       cwd: "/tmp/p4c",
       resolved_base_commit: @base_sha,
       local_branch_ref: "refs/heads/x",
       start_token: "SUPER-SECRET-START-TOKEN"
     }}
  end

  defp happy_script(policy, opts \\ []) do
    %{
      provision_workspace: Keyword.get(opts, :provision_workspace, provision_result()),
      collect_workspace_changes:
        Keyword.get(opts, :collect_workspace_changes, {:ok, default_changes()}),
      create_change_request:
        Keyword.get(
          opts,
          :create_change_request,
          {:ok, change_request(policy.allowed_head_ref)}
        )
    }
  end

  defp drive_to(run_id, policy, target, opts \\ []) do
    :ok = ScriptedExecutionSeam.install(happy_script(policy, opts))
    drive(run_id, target)
  end

  defp drive(run_id, target) do
    {:ok, run} = Store.read_run(run_id)

    if run.status == target or run.status == "blocked" do
      run
    else
      case StageRunner.advance(run_id) do
        {:ok, _advanced} -> drive(run_id, target)
        other -> other
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Stage: authorized → workspace_ready
  # ---------------------------------------------------------------------------

  describe "authorized → workspace_ready" do
    test "invokes :provision_workspace with exactly the action set's key pair", %{
      run: run,
      policy: policy
    } do
      :ok = ScriptedExecutionSeam.install(happy_script(policy))

      assert {:ok, %WorkflowRun{status: "workspace_ready", state_version: 3}} =
               StageRunner.advance(run.id)

      assert_receive {:seam_invoke, :provision_workspace, args}
      assert Map.keys(args) |> Enum.sort() == [:generation, :task_uri]
      assert args.task_uri == run.source_task_uri
      assert args.generation == run.binding_generation
    end

    test "writes workspace_provision_id and expected_base_sha from resolved_base_commit", %{
      run: run,
      policy: policy
    } do
      :ok = ScriptedExecutionSeam.install(happy_script(policy))
      assert {:ok, _} = StageRunner.advance(run.id)

      assert {:ok,
              %WorkflowFacts{
                workspace_provision_id: @provision_id,
                expected_base_sha: @base_sha
              }} = Store.read_facts(run.id)
    end

    test "start_token reaches NO persisted column", %{run: run, policy: policy} do
      :ok = ScriptedExecutionSeam.install(happy_script(policy))
      assert {:ok, _} = StageRunner.advance(run.id)

      # Scan the whole row, not the fields the runner happens to write: a
      # future stage adding a column must not be able to smuggle it in.
      %{rows: [row], columns: _} =
        Repo.query!("SELECT * FROM git_workflow_facts WHERE run_id = $1", [run.id])

      refute Enum.any?(row, fn value ->
               is_binary(value) and String.contains?(value, "SUPER-SECRET-START-TOKEN")
             end)

      %{rows: [run_row]} = Repo.query!("SELECT * FROM git_workflow_runs WHERE id = $1", [run.id])

      refute Enum.any?(run_row, fn value ->
               is_binary(value) and String.contains?(value, "SUPER-SECRET-START-TOKEN")
             end)
    end

    test "a provision result missing resolved_base_commit blocks without persisting facts", %{
      run: run,
      policy: policy
    } do
      :ok =
        ScriptedExecutionSeam.install(
          happy_script(policy,
            provision_workspace: {:ok, %{status: :ready, provision_id: @provision_id}}
          )
        )

      assert {:blocked, %{code: :internal_error, stage: :provision_workspace}} =
               StageRunner.advance(run.id)

      assert {:error, :not_found} = Store.read_facts(run.id)
      assert {:ok, %WorkflowRun{status: "blocked"}} = Store.read_run(run.id)
    end

    test "a non-SHA resolved_base_commit blocks rather than persisting it", %{
      run: run,
      policy: policy
    } do
      :ok =
        ScriptedExecutionSeam.install(
          happy_script(policy,
            provision_workspace:
              {:ok,
               %{status: :ready, provision_id: @provision_id, resolved_base_commit: "not-a-sha"}}
          )
        )

      assert {:blocked, %{code: :internal_error}} = StageRunner.advance(run.id)
      assert {:error, :not_found} = Store.read_facts(run.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Stage: workspace_ready → changes_ready
  # ---------------------------------------------------------------------------

  describe "workspace_ready → changes_ready" do
    test "writes change_digest and advances", %{run: run, policy: policy} do
      ready = drive_to(run.id, policy, "workspace_ready")
      assert ready.status == "workspace_ready"

      assert {:ok, %WorkflowRun{status: "changes_ready"}} = StageRunner.advance(run.id)

      assert {:ok, %WorkflowFacts{change_digest: digest}} = Store.read_facts(run.id)
      assert digest == StageRunner.change_digest(default_changes())
      assert String.starts_with?(digest, "sha256:")
    end

    test "the earlier stage's facts survive the later stage's write", %{run: run, policy: policy} do
      drive_to(run.id, policy, "changes_ready")

      assert {:ok,
              %WorkflowFacts{
                workspace_provision_id: @provision_id,
                expected_base_sha: @base_sha,
                change_digest: digest
              }} = Store.read_facts(run.id)

      assert is_binary(digest)
    end
  end

  # ---------------------------------------------------------------------------
  # change_digest
  # ---------------------------------------------------------------------------

  describe "change_digest/1" do
    test "is independent of the collector's order" do
      a = changes([{"a.txt", "1"}, {"b.txt", "2"}, {"c.txt", "3"}])
      b = changes([{"c.txt", "3"}, {"a.txt", "1"}, {"b.txt", "2"}])

      assert StageRunner.change_digest(a) == StageRunner.change_digest(b)
    end

    test "differs when any byte of any field differs" do
      base = changes([{"a.txt", "1"}])

      refute StageRunner.change_digest(base) == StageRunner.change_digest(changes([{"a.txt", "2"}]))
      refute StageRunner.change_digest(base) == StageRunner.change_digest(changes([{"b.txt", "1"}]))

      refute StageRunner.change_digest(base) ==
               StageRunner.change_digest(changes([{"a.txt", "1"}, {"b.txt", "2"}]))
    end

    test "framing makes a field-boundary shift a different digest" do
      # Without length framing, "ab" <> "c" and "a" <> "bc" would concatenate
      # to the same bytes and hash identically.
      refute StageRunner.change_digest(changes([{"ab", "c"}])) ==
               StageRunner.change_digest(changes([{"a", "bc"}]))
    end
  end

  # ---------------------------------------------------------------------------
  # Stage: changes_ready → pr_open, and THE ordering
  # ---------------------------------------------------------------------------

  describe "changes_ready → pr_open" do
    test "invokes :create_change_request with exactly the action set's three keys", %{
      run: run,
      policy: policy
    } do
      drive_to(run.id, policy, "changes_ready")

      assert {:ok, %WorkflowRun{status: "pr_open"}} = StageRunner.advance(run.id)

      assert_receive {:seam_invoke, :create_change_request, args}
      assert Map.keys(args) |> Enum.sort() == [:changes, :repository, :request]
      assert args.repository == policy.repository
      assert args.request.head_ref == policy.allowed_head_ref
    end

    test "commit_date is run.inserted_at, not the wall clock", %{run: run, policy: policy} do
      drive_to(run.id, policy, "changes_ready")
      assert {:ok, _} = StageRunner.advance(run.id)

      assert_receive {:seam_invoke, :create_change_request, args}
      {:ok, persisted} = Store.read_run(run.id)
      assert args.request.commit_date == persisted.inserted_at
      assert %DateTime{} = args.request.commit_date
    end

    test "persists every change-request fact and head_sha", %{run: run, policy: policy} do
      drive_to(run.id, policy, "changes_ready")
      assert {:ok, _} = StageRunner.advance(run.id)

      assert {:ok,
              %WorkflowFacts{
                change_request_id: "cr-p4c-1",
                change_request_url: "https://git.example.test/p4c/pull/1",
                change_request_state: "open",
                change_request_base_ref: "main",
                change_request_head_ref: head_ref,
                head_sha: @head_sha
              }} = Store.read_facts(run.id)

      assert head_ref == policy.allowed_head_ref
    end

    # THE ordering claim (design §5.3 / the GitHub adapter's KNOWN LIMITATION).
    # A test that only checked the happy-path final state could not tell
    # "written before" from "written after" — this one makes the provider call
    # RAISE at exactly the point the ordering is about, so the fact can only be
    # there if it was written first.
    test "deterministic_head_ref is persisted BEFORE :create_change_request is invoked", %{
      run: run,
      policy: policy
    } do
      drive_to(run.id, policy, "changes_ready")

      :ok =
        ScriptedExecutionSeam.rescript(
          happy_script(policy,
            create_change_request: fn _args -> raise "provider call exploded mid-flight" end
          )
        )

      assert_raise RuntimeError, "provider call exploded mid-flight", fn ->
        StageRunner.advance(run.id)
      end

      assert {:ok, %WorkflowFacts{deterministic_head_ref: head_ref}} = Store.read_facts(run.id)
      assert head_ref == policy.allowed_head_ref

      # And the run did NOT advance — the fact is durable ahead of the state.
      assert {:ok, %WorkflowRun{status: "changes_ready"}} = Store.read_run(run.id)
    end

    test "a returning-but-failing provider call still leaves the ref fact behind", %{
      run: run,
      policy: policy
    } do
      drive_to(run.id, policy, "changes_ready")

      :ok =
        ScriptedExecutionSeam.rescript(
          happy_script(policy, create_change_request: {:error, :provider_unavailable})
        )

      assert {:retry, %{code: :provider_unavailable, retryable: true}} =
               StageRunner.advance(run.id)

      assert {:ok, %WorkflowFacts{deterministic_head_ref: head_ref}} = Store.read_facts(run.id)
      assert head_ref == policy.allowed_head_ref
    end

    test "the ref the runner records equals PolicyDerivation's allowed_head_ref", %{
      run: run,
      binding: binding,
      policy: policy
    } do
      drive_to(run.id, policy, "pr_open")

      assert {:ok, %WorkflowFacts{deterministic_head_ref: recorded}} = Store.read_facts(run.id)

      assert recorded ==
               EzagentPluginGitWorkflow.DeterministicRef.derive(
                 binding.allowed_head_namespace,
                 run.id
               )

      assert recorded == policy.allowed_head_ref
    end

    test "a re-collected change set that no longer matches the digest blocks", %{
      run: run,
      policy: policy
    } do
      drive_to(run.id, policy, "changes_ready")

      :ok =
        ScriptedExecutionSeam.rescript(
          happy_script(policy,
            collect_workspace_changes: {:ok, changes([{"README.md", "SOMETHING ELSE"}])}
          )
        )

      assert {:blocked, %{code: :change_digest_mismatch, retryable: false}} =
               StageRunner.advance(run.id)

      refute_receive {:seam_invoke, :create_change_request, _args}
      assert {:ok, %WorkflowRun{status: "blocked"}} = Store.read_run(run.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Wrong-state discipline
  # ---------------------------------------------------------------------------

  describe "a stage invoked in the wrong state" do
    test "does nothing and names the status", %{run: run, policy: policy} do
      :ok = ScriptedExecutionSeam.install(happy_script(policy))
      {:ok, accepted} = Store.transition(run.id, run.state_version, "authorized", "blocked")

      assert {:error, {:unexpected_status, "blocked"}} = StageRunner.advance(run.id)

      refute_receive {:seam_invoke, _action, _args}
      assert {:ok, %WorkflowRun{status: "blocked", state_version: version}} = Store.read_run(run.id)
      assert version == accepted.state_version
    end

    test "an accepted run owes no stage — authorization is P4b's transition", %{
      run: run,
      policy: policy
    } do
      :ok = ScriptedExecutionSeam.install(happy_script(policy))
      {:ok, _} = Store.record_error_code(run.id, nil)

      # Rewind by accepting a SECOND run that is still `accepted`.
      {:ok, intent} =
        AcceptIntent.new(%{
          binding_id: "bnd_p4b",
          binding_generation: 1,
          external_task_id: "task-p4c-accepted",
          source_task_uri: GitTaskAccessFixture.run_attrs().source_task_uri,
          source_revision: nil,
          requested_head_ref: nil
        })

      {:ok, fresh} = Store.accept(intent)

      assert {:error, {:unexpected_status, "accepted"}} = StageRunner.advance(fresh.id)
      refute_receive {:seam_invoke, _action, _args}
    end

    test "an unknown run id is not_found" do
      assert {:error, :not_found} = StageRunner.advance("run_nope")
    end
  end
end
