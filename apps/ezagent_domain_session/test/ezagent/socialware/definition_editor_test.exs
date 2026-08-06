defmodule Ezagent.Socialware.DefinitionEditorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Definition, DefinitionEditor, DefinitionRegistry}

  @workspace_uri Ezagent.URI.workspace(:system)
  @actor_uri Ezagent.Entity.User.admin_uri()

  test "an install-level flavor override preserves credential admission policy" do
    name = "credential-admission-overlay-#{System.unique_integer([:positive])}"

    assert {:ok, definition} =
             Definition.new(%{
               name: name,
               roles: [
                 %{
                   role_name: "llm",
                   fill: :agent,
                   recipe: "hello.llm",
                   flavor: "cc",
                   credential_admission: :before_session_join
                 }
               ]
             })

    assert {:ok, _object} =
             DefinitionRegistry.write_definition(definition,
               workspace_uri: @workspace_uri,
               caller_workspace_uri: @workspace_uri,
               actor_uri: @actor_uri
             )

    assert {:ok, %{roles: [role]}} =
             DefinitionEditor.config_for_template(
               %{
                 installs: [
                   %{
                     ref: name,
                     config: %{role_slots: [%{role_name: "llm", flavor: "codex"}]}
                   }
                 ]
               },
               @workspace_uri
             )

    assert role.flavor == "codex"
    assert role.credential_admission == :before_session_join
  end

  test "the installed definition ingress is part of the materialized session config" do
    name = "session-ingress-#{System.unique_integer([:positive])}"

    ingress = %{
      behavior: EzagentDomainInstanceMessage.SessionIngressTestBehavior,
      action: :capture_inbound,
      protected_roles: ["llm"]
    }

    assert {:ok, definition} =
             Definition.new(%{
               name: name,
               bases: [EzagentDomainInstanceMessage.SessionIngressTestBehavior],
               roles: [
                 %{
                   role_name: "llm",
                   fill: :agent,
                   recipe: "hello.llm",
                   flavor: "echo"
                 }
               ],
               ingress: ingress
             })

    assert {:ok, _object} =
             DefinitionRegistry.write_definition(definition,
               workspace_uri: @workspace_uri,
               caller_workspace_uri: @workspace_uri,
               actor_uri: @actor_uri
             )

    assert {:ok, %{ingress: ^ingress}} =
             DefinitionEditor.config_for_template(%{installs: [name]}, @workspace_uri)
  end

  test "rejects conflicting ingress declarations in one composition" do
    suffix = System.unique_integer([:positive])
    first_name = "first-ingress-#{suffix}"
    second_name = "second-ingress-#{suffix}"

    first_ingress = %{
      behavior: EzagentDomainInstanceMessage.SessionIngressTestBehavior,
      action: :capture_inbound,
      protected_roles: []
    }

    second_ingress = %{
      behavior: Ezagent.ActionSet.Session,
      action: :attach,
      protected_roles: []
    }

    for {name, ingress} <- [
          {first_name, first_ingress},
          {second_name, second_ingress}
        ] do
      assert {:ok, definition} = Definition.new(%{name: name, ingress: ingress})

      assert {:ok, _object} =
               DefinitionRegistry.write_definition(definition,
                 workspace_uri: @workspace_uri,
                 caller_workspace_uri: @workspace_uri,
                 actor_uri: @actor_uri
               )
    end

    assert {:error, {:conflicting_socialware_ingress, [^first_ingress, ^second_ingress]}} =
             DefinitionEditor.config_for_template(
               %{installs: [first_name, second_name]},
               @workspace_uri
             )
  end

  test "rejects session.send as a recursively configured ingress" do
    name = "recursive-session-ingress-#{System.unique_integer([:positive])}"

    assert {:ok, definition} =
             Definition.new(%{
               name: name,
               ingress: %{
                 behavior: Ezagent.ActionSet.Session,
                 action: :send,
                 protected_roles: []
               }
             })

    assert {:ok, _object} =
             DefinitionRegistry.write_definition(definition,
               workspace_uri: @workspace_uri,
               caller_workspace_uri: @workspace_uri,
               actor_uri: @actor_uri
             )

    assert {:error, {:recursive_session_ingress, Ezagent.ActionSet.Session, :send}} =
             DefinitionEditor.config_for_template(%{installs: [name]}, @workspace_uri)
  end
end
