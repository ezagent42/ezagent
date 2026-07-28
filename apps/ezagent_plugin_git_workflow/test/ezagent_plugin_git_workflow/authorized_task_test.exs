defmodule EzagentPluginGitWorkflow.AuthorizedTaskTest do
  use ExUnit.Case, async: true

  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.AuthorizedTask
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture

  @moduletag :authorized_task

  describe "new/1 happy path" do
    test "returns an AuthorizedTask for a mutually consistent set" do
      attrs = GitTaskAccessFixture.authorized_task_attrs()

      assert {:ok, %AuthorizedTask{} = task} = AuthorizedTask.new(attrs)
      assert task.policy == attrs.policy
      assert task.task_access_uri == attrs.task_access_uri
      assert task.task_uri == attrs.task_uri
      assert task.generation == attrs.generation
    end
  end

  describe "the struct is closed" do
    # Design §3.1/§3.2: the struct's ENTIRE defence against carrying a
    # credential is that it has nowhere to put one. Asserting the exact sorted
    # key set (rather than "the four are present") is what makes ADDING a field
    # — `:caps`, `:token`, a free-form `:metadata` map — turn this red.
    test "has exactly the four fields design §3.1 names, and no others" do
      {:ok, task} = AuthorizedTask.new(GitTaskAccessFixture.authorized_task_attrs())

      assert task |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:generation, :policy, :task_access_uri, :task_uri]
    end
  end

  describe "new/1 rejects the named leak vectors" do
    # §3.2 names these by name as what must never ride through the seam. Each
    # gets its own assertion rather than one generic "unknown key" test, so a
    # future widening that re-admits exactly one of them cannot pass.
    for field <- [:caps, :cap, :token, :invocation, :ctx] do
      test "rejects #{inspect(field)}" do
        attrs =
          GitTaskAccessFixture.authorized_task_attrs()
          |> Map.put(unquote(field), :anything)

        assert {:error, :unknown_fields} = AuthorizedTask.new(attrs)
      end
    end

    test "rejects a string key" do
      attrs =
        GitTaskAccessFixture.authorized_task_attrs()
        |> Map.put("token", "ghp_secret")

      assert {:error, :unknown_fields} = AuthorizedTask.new(attrs)
    end
  end

  describe "new/1 requires every field" do
    for field <- [:policy, :task_access_uri, :task_uri, :generation] do
      test "rejects a missing #{inspect(field)}" do
        attrs = Map.delete(GitTaskAccessFixture.authorized_task_attrs(), unquote(field))

        assert {:error, {:missing_field, unquote(field)}} = AuthorizedTask.new(attrs)
      end
    end
  end

  describe "new/1 proves the four fields describe one authorization" do
    test "rejects a task_uri that is not the policy's own" do
      attrs = GitTaskAccessFixture.authorized_task_attrs()
      other = Ezagent.URI.resource("git-p4a", "task", "some-other-task")
      refute other == attrs.task_uri

      assert {:error, {:invalid_field, :task_uri}} =
               AuthorizedTask.new(%{attrs | task_uri: other})
    end

    test "rejects a generation that is not the policy's own" do
      attrs = GitTaskAccessFixture.authorized_task_attrs()

      assert {:error, {:invalid_field, :generation}} =
               AuthorizedTask.new(%{attrs | generation: attrs.generation + 1})
    end

    test "rejects a task_access_uri that is not derived from the policy" do
      attrs = GitTaskAccessFixture.authorized_task_attrs()
      # A real, well-formed task-access URI — just one belonging to a
      # DIFFERENT policy. The check must be derivation, not shape.
      other = GitTaskAccess.uri_from_args(GitTaskAccessFixture.policy(generation: 7))
      refute other == attrs.task_access_uri

      assert {:error, {:invalid_field, :task_access_uri}} =
               AuthorizedTask.new(%{attrs | task_access_uri: other})
    end
  end

  describe "new/1 revalidates the policy" do
    test "rejects a policy that would be rejected downstream" do
      attrs = GitTaskAccessFixture.authorized_task_attrs()
      # `allowed_actions: []` is rejected by GitTaskAccess.revalidate/1 — the
      # same chokepoint ActionSet.GitTaskAccess runs before dispatching. A
      # policy that dies there must die here instead of travelling further.
      tampered = %{attrs.policy | allowed_actions: []}
      assert {:error, _} = GitTaskAccess.revalidate(tampered)

      assert {:error, {:invalid_field, :policy}} =
               AuthorizedTask.new(%{attrs | policy: tampered})
    end

    test "rejects a non-policy value in the policy field" do
      attrs = GitTaskAccessFixture.authorized_task_attrs()

      assert {:error, {:invalid_field, :policy}} =
               AuthorizedTask.new(%{attrs | policy: %{allowed_actions: [:resolve_repository]}})
    end
  end

  test "new/1 rejects a non-map" do
    assert {:error, :invalid_attributes} = AuthorizedTask.new(:not_a_map)
  end
end
