defmodule EzagentDomainInstanceMessage.Behavior.TurnPublishPolicyTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Turn
  alias Ezagent.MessageStore
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}
  alias EzagentDomainInstanceMessage.Test.BehaviorInvoker, as: Invoker

  @workspace_uri URI.new!("workspace://team-alpha")
  @caller URI.new!("entity://team-alpha/agent/orchestrator")

  defp session_uri(name) do
    Ezagent.URI.new!("session://team-alpha/socialware/#{name}")
  end

  defp bind_workspace(session_uri) do
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
  end

  defp install_socialware(session_uri, policy) do
    name = "policy-#{policy}-#{System.unique_integer([:positive])}"

    attrs = %{
      name: name,
      bases: [Ezagent.ActionSet.Session],
      shape: [Ezagent.ActionSet.Turn],
      visibility_policy: %{publish_policy: policy, web_anon_access: false}
    }

    assert {:ok, object} =
             DefinitionRegistry.write_definition(attrs,
               workspace_uri: @workspace_uri,
               caller_workspace_uri: @workspace_uri,
               actor_uri: @caller
             )

    assert {:ok, definition, _object} = DefinitionRegistry.lookup(@workspace_uri, name)

    assert {:ok, _install} =
             Installation.point_session_install(
               session_uri,
               @workspace_uri,
               %{ref: name, config: %{}},
               definition,
               object,
               @caller
             )

    name
  end

  defp ctx(session_uri) do
    %{
      self_uri: session_uri,
      caller: @caller,
      authenticated_principal: session_uri,
      caps: MapSet.new(),
      reply: :ignore
    }
  end

  defp open_and_compose_chat(session_uri) do
    slice = %{turns: %{}, turn_seq: 0}

    assert {:ok, slice, %{turn_id: turn_id}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :open,
               slice,
               %{trigger: %{message_id: "incoming"}, opened_at: 1},
               ctx(session_uri)
             )

    assert {:ok, slice, %{status: :composing, message_ids: [message_id]}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :compose,
               slice,
               %{turn_id: turn_id, result_refs: [%{kind: "chat", text: "draft reply"}]},
               ctx(session_uri)
             )

    {slice, turn_id, message_id}
  end

  test "supervised publish_policy holds composed chat output internal until settle" do
    session_uri = session_uri("supervised-#{System.unique_integer([:positive])}")
    bind_workspace(session_uri)
    install_socialware(session_uri, :supervised)

    {slice, turn_id, message_id} = open_and_compose_chat(session_uri)

    assert slice.turns[turn_id].mode == :supervised
    assert {:ok, message} = MessageStore.by_id(message_id)
    assert message.visibility == :internal

    assert {:ok, _slice, %{status: :settled}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :settle,
               slice,
               %{turn_id: turn_id},
               ctx(session_uri)
             )

    assert {:ok, message} = MessageStore.by_id(message_id)
    assert message.visibility == :external_visible
  end

  test "auto publish_policy publishes composed chat output immediately" do
    session_uri = session_uri("auto-#{System.unique_integer([:positive])}")
    bind_workspace(session_uri)
    install_socialware(session_uri, :auto)

    {slice, turn_id, message_id} = open_and_compose_chat(session_uri)

    assert slice.turns[turn_id].mode == :auto
    assert {:ok, message} = MessageStore.by_id(message_id)
    assert message.visibility == :external_visible
  end
end
