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
end
