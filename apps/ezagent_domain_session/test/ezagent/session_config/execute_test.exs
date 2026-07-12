defmodule Ezagent.Session.Config.ExecuteTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Session.Config, as: SessionConfig
  alias Ezagent.Session.Config.ExtensionRegistry

  setup do
    ExtensionRegistry.reset_for_test!()

    on_exit(fn ->
      ExtensionRegistry.reset_for_test!()
      ExtensionRegistry.assemble!(ExtensionRegistry.discover_loaded_extensions())
    end)

    :ok
  end

  test "execute/4 rejects unknown operations and malformed addressed targets at the domain boundary" do
    principal = User.admin_uri()
    session_uri = Ezagent.URI.new!("session://system/default/session-config-boundary")

    assert SessionConfig.execute("not_real", %{}, principal, session_uri) ==
             {:error, {:unknown_operation, "not_real"}}

    assert SessionConfig.execute("remove_member", %{}, principal, :request_supplied_context) ==
             {:error, {:invalid_addressed_target, :request_supplied_context}}
  end

  test "operation names are normalized without converting request strings to atoms" do
    assert SessionConfig.operation("list_templates").name == "list_templates"
    assert SessionConfig.operation(:list_templates).name == "list_templates"
    refute Enum.any?(Ezagent.Session.Config.Catalog.core_operations(), &(&1.name == "kb_query"))
  end

  test "equal principal and addressed target inputs derive one canonical context" do
    :ok =
      ExtensionRegistry.assemble!([
        %{
          name: "context_probe",
          description: "test probe",
          input_schema: %{"type" => "object", "properties" => %{}, "required" => []},
          target_scope: :workspace,
          admission_gate: :workspace_caps,
          route: {:mfa, __MODULE__, :capture_context}
        }
      ])

    principal = User.admin_uri()
    workspace_uri = Ezagent.URI.new!("workspace://system")

    assert {:ok, opts} = SessionConfig.execute("context_probe", %{}, principal, workspace_uri)
    assert opts[:caller] == principal
    assert opts[:owner] == principal
    assert opts[:workspace_uri] == workspace_uri
    assert opts[:session_uri] == nil
    assert %MapSet{} = opts[:caps]
  end

  def capture_context(_args, opts), do: {:ok, opts}
end
