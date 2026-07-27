defmodule EzagentDomainInstanceMessage.Integration.SessionInstallsBehaviorSetTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.KindBase
  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.KindRegistry
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}
  alias EzagentDomainInstanceMessage.SessionCreator

  defp uniq, do: System.unique_integer([:positive])

  setup do
    :ok = seed_builtins()
  end

  test "create_session uses template installs to spawn a socialware session" do
    template_name = "install-socialware-#{uniq()}"
    persist_template(template_content(template_name, ["socialware"]))

    assert {:ok, session_uri, %{}} =
             SessionCreator.create_session("soc-#{uniq()}", User.admin_uri(),
               template_name: template_name
             )

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionSupervisor, session_uri)
    end)

    assert captured_behaviors(session_uri) == Session.socialware_behaviors()
    assert Installation.installed?(session_uri, "socialware")
  end

  test "create_session keeps chat installs out of Turn and Surface" do
    template_name = "install-chat-#{uniq()}"
    persist_template(template_content(template_name, ["chat"]))

    assert {:ok, session_uri, %{}} =
             SessionCreator.create_session("chat-#{uniq()}", User.admin_uri(),
               template_name: template_name
             )

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionSupervisor, session_uri)
    end)

    assert captured_behaviors(session_uri) == Session.chat_behaviors()
    assert Installation.installed?(session_uri, "chat")
  end

  defp template_content(name, installs) do
    %{
      name: name,
      description: "install catalog regression",
      default_workspace_uri: Ezagent.URI.workspace(:system),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: nil,
      members: [],
      prompt_templates: %{},
      legends: %{},
      routing_rules: [],
      installs: installs
    }
  end

  defp persist_template(content) do
    hash = SessionTemplate.compute_version_hash(content)
    uri = SessionTemplate.build_uri(content.name, hash, workspace: "system")
    :ok = KindSnapshot.delete(URI.to_string(uri))

    {:ok, uri} = SessionTemplate.persist_version_as_system(content, "system")

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionTemplateSupervisor, uri)
    end)

    uri
  end

  defp captured_behaviors(session_uri) do
    {:ok, slice} = Ezagent.Kind.read(session_uri, :kind_base, spawn: :never)
    KindBase.behaviors_in_slice(slice)
  end

  defp terminate_if_alive(supervisor, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)

      :error ->
        :ok
    end
  end

  defp seed_builtins do
    case DefinitionRegistry.seed_builtin_definitions() do
      :ok -> :ok
      {:error, {:socialware_definition_seed_collision, _}} -> :ok
    end
  end
end
