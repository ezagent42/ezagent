defmodule EzagentPluginHello.Integration.HelloOrchestratorDeliveryTest do
  @moduledoc """
  Regression for the `:no_sandbox_respawn_state` chat-drop bug.

  The orchestrator is a role × `"hello"` flavor agent. Chat delivery
  (`Agent.Receive` → `Agent.Delivery.deliver_agent_receive`) must resolve the
  `"hello"` flavor's in-process adapter (`EzagentPluginHello.BridgeAdapter`) and
  hand the message's session + sender + text to the `:sync_result` seam — NOT drop
  it (which is what a `native` agent, with no AgentBridge adapter, does).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Agent.Delivery
  alias Ezagent.{Message, Workspace}
  alias EzagentPluginHello.App
  alias EzagentPluginHello.Application, as: HelloApp

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

    Enum.each(HelloApp.roles(), fn recipe ->
      {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok
  end

  test "chat to the hello-flavor orchestrator resolves the hello adapter (not dropped)" do
    ws = "hello-deliver-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(ws, %{})

    # ensure_app creates the session + the "hello"-flavor orchestrator synchronously
    # (defer_orchestrator defaults false off the workspace process).
    {:ok, session_uri, orch_uri} = App.ensure_app(ws, "main")

    sender = Ezagent.URI.entity(ws, :user, "operator")
    msg = Message.new(sender, %{text: "make the title blue", attachments: []})

    ctx = %{self_uri: orch_uri, caller: session_uri}

    # The hello adapter (`:in_process_sync`) returns the routing inputs, tagged with
    # the flavor — the delivery is NOT dropped. `deliver_agent_receive` wraps it as
    # `{:sync, "hello", <adapter result>}`.
    assert {:sync, "hello", {:ok, extracted}} = Delivery.deliver_agent_receive(msg, ctx)
    assert extracted.session_uri == session_uri
    assert extracted.sender == sender
    assert extracted.text == "make the title blue"
  end

  test "a user message mentioning the role-resolved orchestrator (web channel's " <>
         "dispatch_post shape) reaches the role-materialized orchestrator, not a " <>
         "convention URI" do
    ws = "hello-deliver-role-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(ws, %{})

    {:ok, session_uri, orch_uri} = App.ensure_app(ws, "main")

    # `EzagentWeb.Socialware.SessionFeedChannel.dispatch_post/3` resolves the
    # mention through exactly this call — assert it lands on the SAME
    # orchestrator `App.ensure_app/2` joined (the role_name facet, not a
    # `orch_<name>` convention URI, which would resolve to a phantom entity now
    # that members are PLANNED-URI / framework-materialized).
    assert {:ok, ^orch_uri} = EzagentPluginHello.Members.role_uri(session_uri, "front-desk")

    sender = Ezagent.URI.entity(ws, :user, "operator")

    msg =
      Message.new(sender, %{text: "make the title blue", attachments: []}, mentions: [orch_uri])

    ctx = %{self_uri: orch_uri, caller: session_uri}

    assert {:sync, "hello", {:ok, extracted}} = Delivery.deliver_agent_receive(msg, ctx)
    assert extracted.session_uri == session_uri
    assert extracted.sender == sender
    assert extracted.text == "make the title blue"
  end
end
