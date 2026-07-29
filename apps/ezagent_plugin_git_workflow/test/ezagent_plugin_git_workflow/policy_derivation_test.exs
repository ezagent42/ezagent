defmodule EzagentPluginGitWorkflow.PolicyDerivationTest do
  # Pure: no DB, no processes, no dispatch. If this file ever needs a sandbox,
  # `PolicyDerivation` stopped being the pure function design §3.1 requires.
  use ExUnit.Case, async: true

  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.Blocker
  alias EzagentPluginGitWorkflow.DeterministicRef
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture
  alias EzagentPluginGitWorkflow.PolicyDerivation
  alias EzagentPluginGitWorkflow.TaskBinding

  @moduletag :policy_derivation

  # The eight `Ezagent.Entity.GitTaskAccess` declares. Restated rather than
  # read from the entity so a narrowing THERE surfaces here as a failure
  # instead of silently agreeing with itself.
  @all_actions [
    :resolve_repository,
    :create_change_request,
    :read_change_request,
    :list_checks,
    :list_reviews,
    :provision_workspace,
    :cleanup_workspace,
    :collect_workspace_changes
  ]

  describe "determinism" do
    test "the same two rows derive a byte-identical policy AND task-access URI" do
      run = GitTaskAccessFixture.run()
      binding = GitTaskAccessFixture.binding()

      assert {:ok, first} = PolicyDerivation.derive(run, binding)
      assert {:ok, second} = PolicyDerivation.derive(run, binding)

      assert first == second

      # The URI is the assertion that actually catches a random `id`: the
      # struct could compare equal on the fields a reader thinks about while
      # `id` still varied, but the URI is a digest of the WHOLE struct.
      assert GitTaskAccess.uri_from_args(first) == GitTaskAccess.uri_from_args(second)
    end

    test "two runs of the same binding derive DIFFERENT task-access URIs" do
      binding = GitTaskAccessFixture.binding()
      run_one = GitTaskAccessFixture.run(%{external_task_id: "task-a"})
      run_two = GitTaskAccessFixture.run(%{external_task_id: "task-b"})

      assert {:ok, policy_one} = PolicyDerivation.derive(run_one, binding)
      assert {:ok, policy_two} = PolicyDerivation.derive(run_two, binding)

      refute policy_one.id == policy_two.id
      refute GitTaskAccess.uri_from_args(policy_one) == GitTaskAccess.uri_from_args(policy_two)
    end

    test "id is the run id verbatim, so it survives a re-read of the same durable row" do
      run = GitTaskAccessFixture.run()
      assert {:ok, policy} = PolicyDerivation.derive(run, GitTaskAccessFixture.binding())
      assert policy.id == run.id
    end
  end

  describe "the acting principal" do
    test "grantee_uri TRACKS binding.task_receiver_uri" do
      run = GitTaskAccessFixture.run()
      workspace = GitTaskAccessFixture.workspace()
      other_receiver = Ezagent.URI.agent(workspace, "other-worker")

      assert {:ok, default} = PolicyDerivation.derive(run, GitTaskAccessFixture.binding())

      assert {:ok, changed} =
               PolicyDerivation.derive(
                 run,
                 GitTaskAccessFixture.binding(%{task_receiver_uri: other_receiver})
               )

      # Asserted by CHANGING the source column and observing the derived field
      # move with it — comparing two values both read from the same column
      # would pass even if the derivation ignored the column entirely.
      refute default.grantee_uri == changed.grantee_uri
      assert changed.grantee_uri == other_receiver
    end

    test "credential_owner_uri and grantee_uri do not collapse into one another" do
      workspace = GitTaskAccessFixture.workspace()
      owner = Ezagent.URI.user(workspace, "lender")
      receiver = Ezagent.URI.agent(workspace, "actor")

      binding =
        GitTaskAccessFixture.binding(%{
          credential_owner_uri: owner,
          task_receiver_uri: receiver
        })

      assert {:ok, policy} = PolicyDerivation.derive(GitTaskAccessFixture.run(), binding)

      assert policy.credential_owner_uri == owner
      assert policy.grantee_uri == receiver
      refute policy.credential_owner_uri == policy.grantee_uri
    end
  end

  describe "the derived policy" do
    setup do
      {:ok, policy} =
        PolicyDerivation.derive(GitTaskAccessFixture.run(), GitTaskAccessFixture.binding())

      %{policy: policy, run: GitTaskAccessFixture.run(), binding: GitTaskAccessFixture.binding()}
    end

    test "passes the entity's own revalidation chokepoint", %{policy: policy} do
      assert {:ok, ^policy} = GitTaskAccess.revalidate(policy)
    end

    test "carries the run's task coordinates", %{policy: policy, run: run} do
      assert policy.task_uri == run.source_task_uri
      assert policy.generation == run.binding_generation

      assert policy.idempotency_inputs == %{
               task_uri: run.source_task_uri,
               generation: run.binding_generation
             }
    end

    test "carries the binding's workspace, credential owner and repository", %{
      policy: policy,
      binding: binding
    } do
      assert policy.workspace_uri == binding.workspace_uri
      assert policy.credential_owner_uri == binding.credential_owner_uri
      assert policy.provider_adapter == binding.provider_adapter
      assert policy.repository.repository_uri == binding.repository_uri
      assert policy.repository.external_id == binding.external_id
      assert policy.repository.base_ref == binding.base_ref
      assert policy.repository.visibility == binding.visibility
    end

    test "allowed_head_ref is exactly DeterministicRef.derive/2's output", %{
      policy: policy,
      run: run,
      binding: binding
    } do
      assert policy.allowed_head_ref ==
               DeterministicRef.derive(binding.allowed_head_namespace, run.id)
    end
  end

  describe "allowed_actions" do
    test "is the documented six and a STRICT subset of the entity's eight" do
      assert PolicyDerivation.allowed_actions() == [
               :provision_workspace,
               :collect_workspace_changes,
               :create_change_request,
               :read_change_request,
               :list_checks,
               :list_reviews
             ]

      assert Enum.all?(PolicyDerivation.allowed_actions(), &(&1 in @all_actions))

      assert @all_actions -- PolicyDerivation.allowed_actions() == [
               :resolve_repository,
               :cleanup_workspace
             ]
    end

    test "the derived policy carries exactly that list" do
      assert {:ok, policy} =
               PolicyDerivation.derive(GitTaskAccessFixture.run(), GitTaskAccessFixture.binding())

      assert policy.allowed_actions == PolicyDerivation.allowed_actions()
    end
  end

  describe "denials" do
    test "a disabled binding denies, and does not raise" do
      assert {:error, :not_authorized} =
               PolicyDerivation.derive(
                 GitTaskAccessFixture.run(),
                 GitTaskAccessFixture.binding(%{enabled: false})
               )
    end

    test "a generation disagreement between the two rows denies" do
      assert {:error, :not_authorized} =
               PolicyDerivation.derive(
                 GitTaskAccessFixture.run(%{binding_generation: 2}),
                 GitTaskAccessFixture.binding(%{generation: 1})
               )
    end

    test "a run naming a DIFFERENT binding denies" do
      assert {:error, :not_authorized} =
               PolicyDerivation.derive(
                 GitTaskAccessFixture.run(%{binding_id: "bnd_other"}),
                 GitTaskAccessFixture.binding(%{id: "bnd_p4b"})
               )
    end

    test "a run whose workspace disagrees with the binding's is a workspace identity mismatch" do
      assert {:error, :workspace_identity_mismatch} =
               PolicyDerivation.derive(
                 GitTaskAccessFixture.run(%{workspace_uri: Ezagent.URI.workspace("other-ws")}),
                 GitTaskAccessFixture.binding()
               )
    end

    test "a non-agent task receiver denies rather than minting a policy for a resource" do
      workspace = GitTaskAccessFixture.workspace()

      {:ok, binding} =
        TaskBinding.new(
          GitTaskAccessFixture.binding_attrs(%{
            task_receiver_uri: Ezagent.URI.resource(workspace, "kanban-task", "task-recv")
          })
        )

      assert {:error, :not_authorized} =
               PolicyDerivation.derive(GitTaskAccessFixture.run(), binding)
    end

    test "a task URI outside the binding's workspace denies" do
      assert {:error, :not_authorized} =
               PolicyDerivation.derive(
                 GitTaskAccessFixture.run(%{
                   source_task_uri: Ezagent.URI.resource("elsewhere", "task", "task-p4b")
                 }),
                 GitTaskAccessFixture.binding()
               )
    end

    test "a run id that did not come from generate_id/3 denies instead of raising" do
      assert {:error, :not_authorized} =
               PolicyDerivation.derive(
                 GitTaskAccessFixture.run(%{id: "hand-written"}),
                 GitTaskAccessFixture.binding()
               )
    end

    test "anything that is not the two durable structs denies" do
      assert {:error, :not_authorized} = PolicyDerivation.derive(%{}, %{})
      assert {:error, :not_authorized} = PolicyDerivation.derive(nil, nil)

      assert {:error, :not_authorized} =
               PolicyDerivation.derive(GitTaskAccessFixture.run(), :not_a_binding)
    end

    test "every denial reason is a member of the Blocker vocabulary" do
      denials = [
        PolicyDerivation.derive(
          GitTaskAccessFixture.run(),
          GitTaskAccessFixture.binding(%{enabled: false})
        ),
        PolicyDerivation.derive(
          GitTaskAccessFixture.run(%{workspace_uri: Ezagent.URI.workspace("other-ws")}),
          GitTaskAccessFixture.binding()
        ),
        PolicyDerivation.derive(nil, nil)
      ]

      for {:error, reason} <- denials do
        assert reason in Blocker.codes(),
               "#{inspect(reason)} is outside the stable blocker vocabulary"

        assert Blocker.classify(reason) == :terminal_blocker
      end
    end
  end
end
