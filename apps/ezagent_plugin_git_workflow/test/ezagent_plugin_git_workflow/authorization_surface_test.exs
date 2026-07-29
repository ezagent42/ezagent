defmodule EzagentPluginGitWorkflow.AuthorizationSurfaceTest do
  @moduledoc """
  The adversarial half of Slice P4b (design §3.4.2, §10).

  Until this slice, `Ezagent.Entity.GitTaskAccess`'s POLICY layer was
  untested: deleting `authorize_receiver/3` from
  `apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex` left
  `mix test apps/ezagent_domain_git/test` at 170 tests / 0 failures. Every cap
  in every existing test was issued TO the fixture's own grantee, so
  `caller == policy.grantee_uri` was always true, and the one test that
  dispatches as an attacker is denied by the CAP gate before the policy layer
  is reached.

  That gap matters far more now that the seam backend mints the cap on demand
  for whatever principal it computed: if the computation is wrong, the minted
  cap matches, the cap gate waves it through, and the policy layer is the only
  thing left.

  Every test here therefore dispatches through the REAL runtime with a REAL,
  signed, current capability, and names which of the two layers is expected to
  answer. `refute_receive` on the adapter probe proves the denial landed
  before any adapter effect.
  """

  use EzagentPluginGitWorkflow.GitDispatchCase

  alias Ezagent.DomainGit.CommitSha

  @moduletag :authorization_surface

  setup %{policy: policy, workspace: workspace} do
    # The Kind must be live before a cap can be minted against it —
    # `Cap.issue_for_action/3` resolves the required shape from the RUNNING
    # instance. This is the same first step `CapBacked.invoke/3` takes.
    :ok = start_task_access(policy)

    # A workspace agent, so the principal gate admits it as a current
    # principal — the attacker must clear that gate, or the denial under test
    # would be `:holder_revoked` rather than the policy's answer.
    %{attacker_uri: Ezagent.URI.agent(workspace, "attacker")}
  end

  describe "policy layer — the guard that had no test" do
    test "a caller holding a GENUINELY VALID cap of its own is denied when it is not the grantee",
         %{policy: policy, task_access_uri: task_access_uri, attacker_uri: attacker_uri} do
      target = action_target(task_access_uri, :create_change_request)

      # A real, signed, current cap — issued through the SAME call the seam
      # backend makes, for the attacker, against the exact action target. The
      # cap gate has nothing to object to: right target, right action, right
      # workspace, bound to the authenticated presenter, current generation.
      cap = mint_cap(attacker_uri, target)

      assert {:error, :unauthorized} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(target, create_change_request_args(policy),
                   caller: attacker_uri,
                   caps: [cap]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "the same attacker IS admitted by the cap gate — so the denial above came from the policy",
         %{policy: policy, task_access_uri: task_access_uri, attacker_uri: attacker_uri} do
      # The control for the test above. `git_task_dispatch_test.exs:106`'s
      # attacker carries the GRANTEE's cap and is stopped at `:missing_cap`,
      # never reaching the policy layer. This one carries its own cap and gets
      # a different answer — which is only possible if it got past the cap
      # gate.
      target = action_target(task_access_uri, :create_change_request)
      args = create_change_request_args(policy)

      grantee_cap = mint_cap(policy.grantee_uri, target)

      assert {:error, :missing_cap} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(target, args,
                   caller: attacker_uri,
                   caps: [grantee_cap]
                 )
               )

      own_cap = mint_cap(attacker_uri, target)

      assert {:error, :unauthorized} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(target, args, caller: attacker_uri, caps: [own_cap])
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "the ISSUANCE ANCHOR is not a principal: the admin as caller is denied too", %{
      policy: policy,
      task_access_uri: task_access_uri
    } do
      # `{:admin, ...}` may only appear as `Cap.issue_for_action/3`'s first
      # argument. A backend that also wrote it into `ctx.caller` would be
      # denied here — which is what makes "the admin is never the principal"
      # an enforced property rather than a convention.
      target = action_target(task_access_uri, :list_checks)
      cap = mint_cap(admin_uri(), target)

      assert {:error, :unauthorized} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(
                   target,
                   %{
                     repository: policy.repository,
                     commit_sha: %CommitSha{value: String.duplicate("e", 40)}
                   },
                   caller: admin_uri(),
                   caps: [cap]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "an action outside policy.allowed_actions is denied THROUGH real dispatch", %{
      policy: policy,
      task_access_uri: task_access_uri
    } do
      # `:resolve_repository` is one of the two actions `PolicyDerivation`
      # withholds. Until now this was covered only as an Entity unit test
      # (`entity/git_task_access_test.exs:79-82`) — never through the dispatch
      # path, and never with a cap the framework was happy with.
      target = action_target(task_access_uri, :resolve_repository)
      cap = mint_cap(policy.grantee_uri, target)

      assert {:error, :action_not_allowed} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(target, %{repository: policy.repository},
                   caller: policy.grantee_uri,
                   caps: [cap]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "the withheld workspace action is denied the same way", %{
      policy: policy,
      task_access_uri: task_access_uri
    } do
      target = action_target(task_access_uri, :cleanup_workspace)
      cap = mint_cap(policy.grantee_uri, target)

      assert {:error, :action_not_allowed} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(
                   target,
                   %{task_uri: policy.task_uri, generation: policy.generation},
                   caller: policy.grantee_uri,
                   caps: [cap]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "an allowed action with the SAME cap and the grantee as caller does reach the adapter",
         %{policy: policy, task_access_uri: task_access_uri} do
      # The positive control for the four denials above: same construction,
      # same helpers, only the principal / action changed. Without it, every
      # denial above could be passing because the invocation was malformed.
      target = action_target(task_access_uri, :create_change_request)
      cap = mint_cap(policy.grantee_uri, target)

      assert {:ok, _change_request} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(target, create_change_request_args(policy),
                   caller: policy.grantee_uri,
                   caps: [cap]
                 )
               )

      assert_receive {:git_p4b_adapter_call, :create_change_request, _context}
    end
  end

  describe "cap layer — the framework gates apply to the invocation THIS backend builds" do
    setup %{policy: policy, task_access_uri: task_access_uri} do
      target = action_target(task_access_uri, :create_change_request)

      %{
        target: target,
        args: create_change_request_args(policy),
        valid_cap: mint_cap(policy.grantee_uri, target)
      }
    end

    test "wrong receiver: the grantee's cap replayed by another caller", ctx do
      # Target gate: the cap is genuinely signed and current, but bound to a
      # different holder than the authenticated presenter.
      assert {:error, :missing_cap} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(ctx.target, ctx.args,
                   caller: ctx.attacker_uri,
                   caps: [ctx.valid_cap]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "wrong action: a genuinely signed cap for a DIFFERENT action of the same instance", ctx do
      # Shape gate, and the strongest of the five: the cap is signed by the
      # right authority, bound to the right holder, targets the right
      # instance — only the action axis is wrong.
      other_action_cap =
        mint_cap(ctx.policy.grantee_uri, action_target(ctx.task_access_uri, :list_checks))

      assert {:error, :missing_cap} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(ctx.target, ctx.args,
                   caller: ctx.policy.grantee_uri,
                   caps: [other_action_cap]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "wrong workspace: the workspace axis retargeted", ctx do
      retargeted = %{ctx.valid_cap | workspace_uri: Ezagent.URI.workspace("other-workspace")}

      assert {:error, :missing_cap} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(ctx.target, ctx.args,
                   caller: ctx.policy.grantee_uri,
                   caps: [retargeted]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "wrong instance: the instance axis retargeted", ctx do
      # Same construction `git_task_dispatch_test.exs:123-125` uses. Both this
      # and the workspace case above are TAMPERS of a signed artifact, so they
      # are refused at the target gate rather than the shape gate — a signed
      # cap carrying a different workspace cannot be produced through
      # `issue_for_action/3`, which derives every axis from the live target.
      # The wrong-ACTION case above supplies the signed-but-wrong-axis
      # property those two cannot.
      elsewhere = Ezagent.URI.resource("other-workspace", "git-task-access", "other")
      retargeted = %{ctx.valid_cap | instance: Ezagent.URI.instance(elsewhere)}

      assert {:error, :missing_cap} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(ctx.target, ctx.args,
                   caller: ctx.policy.grantee_uri,
                   caps: [retargeted]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "unsigned: signature, key id and receiver binding stripped", ctx do
      unsigned = %{ctx.valid_cap | signature: nil, key_id: nil, grantee_uri: nil}

      assert {:error, :missing_cap} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(ctx.target, ctx.args,
                   caller: ctx.policy.grantee_uri,
                   caps: [unsigned]
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end

    test "no cap at all", ctx do
      assert {:error, :missing_cap} =
               Ezagent.Invocation.dispatch(
                 backend_shaped_invocation(ctx.target, ctx.args,
                   caller: ctx.policy.grantee_uri,
                   caps: []
                 )
               )

      refute_receive {:git_p4b_adapter_call, _action, _context}
    end
  end
end
