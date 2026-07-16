defmodule EzagentDomainSocialware.Integration.SurfaceDispatchIntegrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, User}

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "surface-dispatch-#{System.unique_integer([:positive])}"
    )
  end

  defp agent_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{origin: :trusted_internal,
      target: target(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  setup do
    session_uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(session_uri))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok =
      Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

    %{session_uri: session_uri}
  end

  test "turn.compose dispatches surface.put_version into the runtime-visible :surface slice", %{
    session_uri: session_uri
  } do
    page_tree = %{
      type: "container",
      children: [%{type: "text", props: %{text: "hello page"}}]
    }

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(session_uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{expected: [:page]}} =
             dispatch(session_uri, :turn, :dispatch, %{
               turn_id: turn_id,
               subtasks: [%{id: :page, mention: agent_uri("page"), prompt: "render"}]
             })

    assert {:ok, %{collected: [:page]}} =
             dispatch(session_uri, :turn, :deliver, %{
               turn_id: turn_id,
               subtask_id: :page,
               card_ref: %{kind: :page, tree: page_tree}
             })

    assert {:ok, %{status: :composing, version: 1}} =
             dispatch(session_uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})

    wait_until(fn ->
      {:ok, surface} = Ezagent.Kind.get_slice(session_uri, :surface)
      surface.versions[1] == %{tree: page_tree, by_turn: turn_id}
    end)

    {:ok, surface} = Ezagent.Kind.get_slice(session_uri, :surface)
    assert surface.approved == nil
  end

  test "turn.settle dispatches surface.approve in auto mode", %{session_uri: session_uri} do
    page_tree = %{type: "text", props: %{text: "approved page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(session_uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, _result} =
             dispatch(session_uri, :turn, :dispatch, %{
               turn_id: turn_id,
               subtasks: [%{id: :page, mention: agent_uri("page"), prompt: "render"}]
             })

    assert {:ok, _result} =
             dispatch(session_uri, :turn, :deliver, %{
               turn_id: turn_id,
               subtask_id: :page,
               card_ref: %{kind: :page, tree: page_tree}
             })

    assert {:ok, %{version: version}} =
             dispatch(session_uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})

    wait_until(fn ->
      {:ok, surface} = Ezagent.Kind.get_slice(session_uri, :surface)
      Map.has_key?(surface.versions, version)
    end)

    assert {:ok, %{status: :settled}} =
             dispatch(session_uri, :turn, :settle, %{turn_id: turn_id})

    wait_until(fn ->
      {:ok, surface} = Ezagent.Kind.get_slice(session_uri, :surface)
      surface.approved == version
    end)

    {:ok, surface} = Ezagent.Kind.get_slice(session_uri, :surface)
    assert Ezagent.ActionSet.Surface.internal_tree(surface) == page_tree
    assert Ezagent.ActionSet.Surface.external_tree(surface) == page_tree
  end
end
