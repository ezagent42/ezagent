defmodule EzagentPluginGitWorkflow.ExecutionSeam.CapBackedTest do
  use EzagentPluginGitWorkflow.GitDispatchCase

  alias Ezagent.DomainGit.CommitSha
  alias EzagentPluginGitWorkflow.AuthorizedTask
  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.GitAdapterProbe

  @moduletag :execution_seam

  describe "authorize/2" do
    test "returns an AuthorizedTask whose four fields match the derived policy", %{
      run: run,
      binding: binding,
      policy: policy,
      task_access_uri: task_access_uri
    } do
      assert {:ok, %AuthorizedTask{} = task} = CapBacked.authorize(run, binding)

      assert task.policy == policy
      assert task.task_access_uri == task_access_uri
      assert task.task_uri == run.source_task_uri
      assert task.generation == run.binding_generation
    end

    test "starts NO Kind — on the SUCCESS path", %{
      run: run,
      binding: binding,
      task_access_uri: task_access_uri
    } do
      refute Ezagent.Kind.alive?(task_access_uri)

      assert {:ok, %AuthorizedTask{}} = CapBacked.authorize(run, binding)

      # Without this the "authorize/2 answers a question, it does not begin
      # work" contract is a comment. A backend that called
      # `TaskAccessSupervisor.ensure_started/1` here would still return
      # `{:ok, task}` and pass every other assertion in this file.
      refute Ezagent.Kind.alive?(task_access_uri)
    end

    test "starts NO Kind — on the DENIAL path", %{
      run: run,
      binding: binding,
      task_access_uri: task_access_uri
    } do
      refute Ezagent.Kind.alive?(task_access_uri)

      assert {:error, :not_authorized} = CapBacked.authorize(run, %{binding | enabled: false})

      refute Ezagent.Kind.alive?(task_access_uri)
    end

    test "denials return the documented atom and leak neither binding nor policy", %{
      run: run,
      binding: binding
    } do
      denials = [
        CapBacked.authorize(run, %{binding | enabled: false}),
        CapBacked.authorize(%{run | binding_generation: 99}, binding),
        CapBacked.authorize(%{run | binding_id: "bnd_other"}, binding),
        CapBacked.authorize(:not_a_run, binding),
        CapBacked.authorize(run, :not_a_binding)
      ]

      # A bare atom cannot carry a repository coordinate, a receiver URI or a
      # policy — the shape IS the leak-freedom proof.
      for denial <- denials, do: assert(denial == {:error, :not_authorized})
    end

    test "never raises, whatever it is handed" do
      assert {:error, :not_authorized} = CapBacked.authorize(nil, nil)
      assert {:error, :not_authorized} = CapBacked.authorize(%{}, %{})
      assert {:error, :not_authorized} = CapBacked.authorize("run", "binding")
    end
  end

  describe "invoke/3" do
    setup %{run: run, binding: binding} do
      {:ok, task} = CapBacked.authorize(run, binding)
      %{task: task}
    end

    test "reaches the adapter THROUGH the real Kind runtime", %{task: task, policy: policy} do
      assert {:ok, change_request} =
               CapBacked.invoke(task, :create_change_request, create_change_request_args(policy))

      assert change_request.head_ref == policy.allowed_head_ref
      assert change_request.head_sha == GitAdapterProbe.head_sha()

      # The probe only ever fires from inside the action set's handler, which
      # is only reachable through `Ezagent.Invocation.dispatch/1` — a backend
      # that called the action set directly would never produce this message.
      assert_receive {:git_p4b_adapter_call, :create_change_request, _context}
    end

    test "ctx.caller is the policy's grantee, and is NOT the admin", %{
      task: task,
      policy: policy
    } do
      assert {:ok, _change_request} =
               CapBacked.invoke(task, :create_change_request, create_change_request_args(policy))

      assert_receive {:git_p4b_adapter_call, :create_change_request, context}

      # `OperationContext.caller_uri` is built from `ctx.caller`
      # (`git_task_access.ex` `operation_context/3`), so this reads the value
      # the backend actually dispatched, not the backend's source.
      assert context.caller_uri == policy.grantee_uri
      assert context.grantee_uri == policy.grantee_uri
      refute context.caller_uri == admin_uri()
    end

    test "ctx.authenticated_principal is the grantee — the admin variant cannot pass", %{
      task: task,
      policy: policy,
      task_access_uri: task_access_uri
    } do
      # Rebuild the SAME invocation the backend builds, changing only
      # `authenticated_principal` to the issuance anchor: the grantee-bound
      # cap then fails the target gate for a different holder. So had the
      # backend put the admin in that field, the happy path below could not
      # be green.
      :ok = start_task_access(policy)
      target = action_target(task_access_uri, :create_change_request)
      cap = mint_cap(policy.grantee_uri, target)

      assert {:error, :missing_cap} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(target, create_change_request_args(policy),
                   caller: policy.grantee_uri,
                   authenticated_principal: admin_uri(),
                   caps: [cap]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}

      assert {:ok, _change_request} =
               CapBacked.invoke(task, :create_change_request, create_change_request_args(policy))

      assert_receive {:git_p4b_adapter_call, :create_change_request, _context}
    end

    test "two invocations mint two caps — a cached one could not match the second action", %{
      task: task,
      policy: policy
    } do
      assert {:ok, _change_request} =
               CapBacked.invoke(task, :create_change_request, create_change_request_args(policy))

      assert_receive {:git_p4b_adapter_call, :create_change_request, _context}

      # A cached `create_change_request` cap presented for `list_checks` fails
      # the shape gate (`:missing_cap`), so a green second call is positive
      # proof that a NEW cap was minted for the second action target.
      assert {:ok, [_check]} =
               CapBacked.invoke(task, :list_checks, %{
                 repository: policy.repository,
                 commit_sha: %CommitSha{value: String.duplicate("d", 40)}
               })

      assert_receive {:git_p4b_adapter_call, :list_checks, _context}
    end

    test "a policy denial leaves as a stable Blocker code, never a raw error term", %{
      task: task,
      policy: policy
    } do
      # `:action_not_allowed` is the action set's own denial for an action
      # outside `policy.allowed_actions`; the seam normalizes it into §7.1's
      # vocabulary instead of letting the raw atom through.
      assert {:error, :not_authorized} =
               CapBacked.invoke(task, :resolve_repository, %{repository: policy.repository})

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "an excluded workspace action is denied by the policy, not by the seam guard", %{
      task: task,
      policy: policy
    } do
      # `:cleanup_workspace` IS in the seam's eight-action vocabulary but NOT
      # in this policy's six, so it reaches the backend and the POLICY denies
      # it. The seam's own guard is proven separately in
      # `execution_seam_test.exs`.
      assert {:error, :not_authorized} =
               CapBacked.invoke(task, :cleanup_workspace, %{
                 task_uri: policy.task_uri,
                 generation: policy.generation
               })
    end
  end
end
