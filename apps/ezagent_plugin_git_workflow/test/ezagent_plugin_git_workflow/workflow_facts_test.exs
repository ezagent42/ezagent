defmodule EzagentPluginGitWorkflow.WorkflowFactsTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.WorkflowFacts

  @moduletag :workflow_facts

  @minimal %{
    id: "wf_test",
    run_id: "run_test",
    workspace_uri: Ezagent.URI.workspace("test-ws")
  }

  describe "new/1" do
    test "accepts the minimal required fields, defaults the rest to nil" do
      assert {:ok, %WorkflowFacts{id: "wf_test", run_id: "run_test", head_sha: nil}} =
               WorkflowFacts.new(@minimal)
    end

    test "rejects missing id" do
      assert {:error, {:missing_field, :id}} = WorkflowFacts.new(Map.delete(@minimal, :id))
    end

    test "rejects missing run_id" do
      assert {:error, {:missing_field, :run_id}} =
               WorkflowFacts.new(Map.delete(@minimal, :run_id))
    end

    test "rejects missing workspace_uri" do
      assert {:error, {:missing_field, :workspace_uri}} =
               WorkflowFacts.new(Map.delete(@minimal, :workspace_uri))
    end

    test "rejects a non-canonical workspace_uri" do
      bad = %{@minimal | workspace_uri: "not-a-uri-struct"}
      assert {:error, {:invalid_field, :workspace_uri}} = WorkflowFacts.new(bad)
    end

    test "rejects unknown fields" do
      assert {:error, {:unknown_fields, [:token]}} =
               WorkflowFacts.new(Map.put(@minimal, :token, "secret"))
    end

    test "accepts every design §5.3 fact field" do
      attrs =
        Map.merge(@minimal, %{
          workspace_provision_id: "prov_1",
          deterministic_head_ref: "feature/run-abc123",
          change_digest: "sha256:deadbeef",
          expected_base_sha: "abc123",
          head_sha: "def456",
          change_request_id: "cr_1",
          change_request_url: "https://github.com/o/r/pull/1",
          change_request_state: "open",
          change_request_head_ref: "feature/run-abc123",
          change_request_base_ref: "main",
          checks_revision: 1,
          checks_summary: "all passing",
          checks_observed_at: DateTime.utc_now(),
          reviews_revision: 1,
          reviews_summary: "1 approval",
          reviews_observed_at: DateTime.utc_now()
        })

      assert {:ok, %WorkflowFacts{}} = WorkflowFacts.new(attrs)
    end
  end

  describe "struct field contract" do
    test "no secret-shaped keys" do
      keys =
        WorkflowFacts.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))

      forbidden =
        ~w(token credential secret password authorization private_key installation_id raw_response header)a

      for key <- keys do
        ks = Atom.to_string(key)

        refute Enum.any?(forbidden, &String.contains?(ks, Atom.to_string(&1))),
               "WorkflowFacts key #{key} forbidden"
      end
    end
  end
end
