defmodule Ezagent.ProtocolApi.ConversationRegistryTest do
  @moduledoc """
  Covers the protocol_api session-spawn path after the #99 C migration: the
  inbound API materializes a session through the owner-gated
  `Ezagent.LocalRuntime.ensure_started/1` (was a direct `SpawnRegistry.spawn/1`).

  Single-node the workspace owner gate is a no-op, so `resolve/3` must still
  start a live session. This is the runnable complement to the (pre-existing,
  `@tag :skip`) full-plug `openai_chat_plug_integration_test`, which additionally
  needs a seeded echo agent + a multi-second activation wait.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.ProtocolApi.ConversationRegistry
  alias Ezagent.Workspace

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    ws_name = "protocol-conv-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    {:ok, workspace_uri: workspace_uri}
  end

  test "stateless resolve/3 starts a fresh live session via LocalRuntime.ensure_started",
       %{workspace_uri: workspace_uri} do
    bound_by = User.admin_uri()

    assert {:ok, %URI{} = session_uri} =
             ConversationRegistry.resolve(nil, workspace_uri, bound_by)

    # ensure_started actually materialized the session Kind (the migrated line:
    # SpawnRegistry.spawn → LocalRuntime.ensure_started). Owner gate is a no-op
    # single-node, so the freshly-resolved session must read alive HERE.
    assert Ezagent.LocalRuntime.kind_alive?(session_uri),
           "stateless resolve must leave the session live via LocalRuntime.ensure_started"
  end

  test "durable resolve/3 reuses the same bound session across calls",
       %{workspace_uri: workspace_uri} do
    bound_by = User.admin_uri()
    conversation_id = "conv-#{System.unique_integer([:positive])}"

    assert {:ok, %URI{} = first} =
             ConversationRegistry.resolve(conversation_id, workspace_uri, bound_by)

    assert Ezagent.LocalRuntime.kind_alive?(first)

    # Same conversation_id → same session URI (durable binding), no second spawn.
    assert {:ok, ^first} =
             ConversationRegistry.resolve(conversation_id, workspace_uri, bound_by)
  end
end
