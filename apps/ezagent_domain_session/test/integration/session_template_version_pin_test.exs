defmodule EzagentDomainInstanceMessage.Integration.SessionTemplateVersionPinTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.TemplateTags
  alias EzagentDomainInstanceMessage.SessionCreator

  defp uniq, do: System.unique_integer([:positive])

  defp content(name, description) do
    %{
      name: name,
      description: description,
      members: [],
      routing_rules: [],
      prompt_templates: %{},
      legends: %{},
      orchestrator_template_uri: nil,
      default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-21 00:00:00Z]
    }
  end

  defp hash_of(%URI{} = uri) do
    uri
    |> Ezagent.URI.name!()
    |> String.split("@", parts: 2)
    |> List.last()
  end

  test "new sessions resolve the current tag at create time while existing sessions stay pinned" do
    template_name = "pin-team-#{uniq()}"
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

    {:ok, h1_uri} =
      SessionTemplate.persist_version_as_system(content(template_name, "h1"), workspace_uri)

    {:ok, h2_uri} =
      SessionTemplate.persist_version_as_system(content(template_name, "h2"), workspace_uri)

    :ok =
      TemplateTags.put(workspace_uri, template_name, "current", hash_of(h1_uri), User.admin_uri())

    {:ok, session_a, _meta} =
      SessionCreator.create_session("a-#{uniq()}", User.admin_uri(),
        workspace_uri: workspace_uri,
        template_name: template_name
      )

    assert Session.read_template_working_copy(session_a).session_template_uri == h1_uri

    :ok =
      TemplateTags.move(workspace_uri, template_name, "current", hash_of(h1_uri), hash_of(h2_uri))

    {:ok, session_b, _meta} =
      SessionCreator.create_session("b-#{uniq()}", User.admin_uri(),
        workspace_uri: workspace_uri,
        template_name: template_name
      )

    assert Session.read_template_working_copy(session_b).session_template_uri == h2_uri
    assert Session.read_template_working_copy(session_a).session_template_uri == h1_uri
  end

  test "recreating the same session after the current template moves preserves its original pin" do
    template_name = "pin-idempotent-#{uniq()}"
    workspace_uri = Ezagent.URI.new!("workspace://system")
    short_name = "same-#{uniq()}"

    {:ok, h1_uri} =
      SessionTemplate.persist_version_as_system(content(template_name, "h1"), workspace_uri)

    {:ok, h2_uri} =
      SessionTemplate.persist_version_as_system(content(template_name, "h2"), workspace_uri)

    :ok =
      TemplateTags.put(workspace_uri, template_name, "current", hash_of(h1_uri), User.admin_uri())

    assert {:ok, session_uri, _meta} =
             SessionCreator.create_session(short_name, User.admin_uri(),
               workspace_uri: workspace_uri,
               template_name: template_name
             )

    :ok =
      TemplateTags.move(workspace_uri, template_name, "current", hash_of(h1_uri), hash_of(h2_uri))

    assert {:ok, ^session_uri, _meta} =
             SessionCreator.create_session(short_name, User.admin_uri(),
               workspace_uri: workspace_uri,
               template_name: template_name
             )

    assert Session.read_template_working_copy(session_uri).session_template_uri == h1_uri
  end
end
