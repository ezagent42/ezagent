defmodule EzagentPluginGitWorkflow.AcceptIntentTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.AcceptIntent

  @valid %{
    binding_id: "bnd-1",
    binding_generation: 1,
    external_task_id: "task-ext-1",
    source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task1"),
    source_revision: "abc123",
    requested_head_ref: "feature/test"
  }

  describe "valid construction" do
    test "accepts all required fields" do
      assert {:ok, %AcceptIntent{}} = AcceptIntent.new(@valid)
    end

    test "nil source_revision and requested_head_ref are ok" do
      attrs = %{@valid | source_revision: nil, requested_head_ref: nil}
      assert {:ok, %AcceptIntent{source_revision: nil, requested_head_ref: nil}} =
               AcceptIntent.new(attrs)
    end
  end

  describe "missing fields" do
    for field <- AcceptIntent.__struct__() |> Map.keys() |> Enum.reject(&(&1 == :__struct__)) do
      @field field

      test "rejects missing #{field}" do
        attrs = Map.delete(@valid, @field)
        assert {:error, {:missing_field, @field}} = AcceptIntent.new(attrs)
      end
    end
  end

  describe "server-owned field rejection" do
    test "rejects id" do
      assert {:error, {:server_owned_field, :id}} =
               AcceptIntent.new(Map.put(@valid, :id, "run-123"))
    end

    test "rejects status" do
      assert {:error, {:server_owned_field, :status}} =
               AcceptIntent.new(Map.put(@valid, :status, "accepted"))
    end

    test "rejects state_version" do
      assert {:error, {:server_owned_field, :state_version}} =
               AcceptIntent.new(Map.put(@valid, :state_version, 1))
    end

    test "rejects input_digest" do
      assert {:error, {:server_owned_field, :input_digest}} =
               AcceptIntent.new(Map.put(@valid, :input_digest, "sha256:abc"))
    end

    test "rejects last_error_code" do
      assert {:error, {:server_owned_field, :last_error_code}} =
               AcceptIntent.new(Map.put(@valid, :last_error_code, "E001"))
    end
  end

  describe "unknown fields" do
    test "rejects arbitrary extra fields" do
      assert {:error, {:unknown_fields, [:extra_field]}} =
               AcceptIntent.new(Map.put(@valid, :extra_field, "nope"))
    end
  end

  describe "invalid values" do
    test "rejects empty binding_id" do
      assert {:error, {:invalid_field, :binding_id}} =
               AcceptIntent.new(%{@valid | binding_id: ""})
    end

    test "rejects non-string binding_id" do
      assert {:error, {:invalid_field, :binding_id}} =
               AcceptIntent.new(%{@valid | binding_id: 123})
    end

    test "rejects zero binding_generation" do
      assert {:error, {:invalid_field, :binding_generation}} =
               AcceptIntent.new(%{@valid | binding_generation: 0})
    end

    test "rejects non-URI source_task_uri" do
      assert {:error, {:invalid_field, :source_task_uri}} =
               AcceptIntent.new(%{@valid | source_task_uri: "not-a-uri"})
    end

    test "rejects non-canonical source_task_uri" do
      bad_uri = URI.parse("resource://test-ws/kanban-task/task1")
      refute Ezagent.URI.canonical?(bad_uri)
      assert {:error, {:invalid_field, :source_task_uri}} =
               AcceptIntent.new(%{@valid | source_task_uri: bad_uri})
    end
  end
end
