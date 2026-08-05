defmodule EzagentDomainInstanceMessage.Integration.SessionCreatorIngressCompletenessTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.Socialware.{Definition, DefinitionRegistry}

  @workspace Ezagent.URI.workspace(:system)
  @owner User.admin_uri()

  setup do
    _ = Ezagent.SpawnRegistry.spawn(@owner)
    :ok
  end

  test "an existing session with missing ingress is rematerialized" do
    assert_corrupt_ingress_is_rematerialized(nil)
  end

  test "an existing session with stale ingress is rematerialized" do
    assert_corrupt_ingress_is_rematerialized(stale_ingress())
  end

  test "an existing session propagates conflicting composed ingress" do
    suffix = System.unique_integer([:positive])
    first_name = "existing-first-ingress-#{suffix}"
    second_name = "existing-second-ingress-#{suffix}"
    template_name = "existing-conflict-template-#{suffix}"
    session_name = "existing-conflict-session-#{suffix}"
    first_ingress = ingress()
    second_ingress = stale_ingress()

    write_definition(first_name, %{
      bases: [EzagentDomainInstanceMessage.SessionIngressTestBehavior],
      ingress: first_ingress
    })

    write_definition(second_name, %{})
    persist_template(template_name, [first_name, second_name])

    assert {:ok, session_uri, %{}} = create_session(session_name, template_name)
    cleanup_session(session_uri)
    assert {:ok, original_pid} = Ezagent.KindRegistry.lookup(session_uri)

    write_definition(second_name, %{ingress: second_ingress})

    assert {:error, {:conflicting_socialware_ingress, [^first_ingress, ^second_ingress]}} =
             create_session(session_name, template_name)

    assert {:ok, ^original_pid} = Ezagent.KindRegistry.lookup(session_uri)
  end

  defp ingress do
    %{
      behavior: EzagentDomainInstanceMessage.SessionIngressTestBehavior,
      action: :capture_inbound,
      protected_roles: []
    }
  end

  defp stale_ingress do
    %{
      behavior: Ezagent.ActionSet.Session,
      action: :attach,
      protected_roles: []
    }
  end

  defp assert_corrupt_ingress_is_rematerialized(corrupted_ingress) do
    expected_ingress = ingress()
    suffix = System.unique_integer([:positive])
    definition_name = "ingress-completeness-#{suffix}"
    template_name = "ingress-completeness-template-#{suffix}"
    session_name = "ingress-completeness-session-#{suffix}"

    write_definition(definition_name, %{
      bases: [EzagentDomainInstanceMessage.SessionIngressTestBehavior],
      ingress: expected_ingress
    })

    persist_template(template_name, [definition_name])

    assert {:ok, session_uri, %{}} = create_session(session_name, template_name)
    cleanup_session(session_uri)
    assert %{ingress: ^expected_ingress} = Session.read_template_working_copy(session_uri)
    assert {:ok, old_pid} = Ezagent.KindRegistry.lookup(session_uri)

    working_copy = Session.read_template_working_copy(session_uri)

    corrupted_working_copy =
      case corrupted_ingress do
        nil -> Map.delete(working_copy, :ingress)
        stale -> Map.put(working_copy, :ingress, stale)
      end

    assert {:ok, _} =
             Ezagent.ActionSet.Session.system_set_working_copy(
               session_uri,
               corrupted_working_copy
             )

    assert {:ok, ^session_uri, %{}} = create_session(session_name, template_name)

    assert {:ok, new_pid} = Ezagent.KindRegistry.lookup(session_uri)
    refute new_pid == old_pid
    assert %{ingress: ^expected_ingress} = Session.read_template_working_copy(session_uri)
  end

  defp write_definition(name, attrs) do
    assert {:ok, definition} = Definition.new(Map.put(attrs, :name, name))

    assert {:ok, _object} =
             DefinitionRegistry.write_definition(definition,
               workspace_uri: @workspace,
               caller_workspace_uri: @workspace,
               actor_uri: @owner
             )
  end

  defp persist_template(name, installs) do
    assert {:ok, template_uri} =
             SessionTemplate.persist_version_as_system(
               %{name: name, installs: installs},
               "system"
             )

    on_exit(fn ->
      terminate_if_alive(
        EzagentDomainInstanceMessage.SessionTemplateSupervisor,
        template_uri
      )
    end)
  end

  defp create_session(session_name, template_name) do
    EzagentDomainInstanceMessage.SessionCreator.create_session(session_name, @owner,
      template_name: template_name
    )
  end

  defp cleanup_session(session_uri) do
    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionSupervisor, session_uri)
    end)
  end

  defp terminate_if_alive(supervisor, uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)

      _ ->
        :ok
    end
  end
end
