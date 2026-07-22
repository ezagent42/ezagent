defmodule EzagentDomainInstanceMessage.Behavior.TurnTest do
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Turn
  alias Ezagent.Cmd
  alias EzagentDomainInstanceMessage.Test.BehaviorInvoker, as: Invoker

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "unit-#{System.unique_integer([:positive])}")
  end

  defp agent_uri(name \\ "orchestrator") do
    Ezagent.URI.entity(:team_alpha, :agent, name)
  end

  defp worker_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp msg_ref, do: %{message_id: "msg-1"}

  defp ctx(overrides \\ []) do
    session = Keyword.get(overrides, :self_uri, session_uri())

    %{
      self_uri: session,
      caller: Keyword.get(overrides, :caller, agent_uri()),
      authenticated_principal: Keyword.get(overrides, :authenticated_principal, session),
      caps: MapSet.new(),
      reply: :ignore
    }
  end

  defp open_turn(slice \\ %{turns: %{}, turn_seq: 0}) do
    {:ok, slice, %{turn_id: turn_id}, _effects} =
      Invoker.invoke_with_effects(Turn, :open, slice, %{trigger: msg_ref(), opened_at: 1}, ctx())

    {slice, turn_id}
  end

  test "create initializes an empty :turns slice" do
    assert {:ok, state} = Turn.create(%{})
    assert state.turns == %{}
    assert state.turn_seq == 0
  end

  test "turn.open creates an :open turn with a monotonic turn_no" do
    slice = %{turns: %{}, turn_seq: 0}
    caller = agent_uri()

    assert {:ok, slice2, %{turn_id: turn_id}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :open,
               slice,
               %{trigger: msg_ref(), opened_at: 1},
               ctx(caller: caller)
             )

    turn = slice2.turns[turn_id]
    assert turn.status == :open
    assert turn.turn_no == 1
    assert turn.owner == caller
    assert slice2.turn_seq == 1

    assert {:ok, slice3, %{turn_id: turn_id2}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :open,
               slice2,
               %{trigger: %{message_id: "msg-2"}, opened_at: 2},
               ctx(caller: caller)
             )

    assert slice3.turns[turn_id2].turn_no == 2
    assert slice3.turn_seq == 2
  end

  test "turn.dispatch records expected subtasks and emits correlated chat sends" do
    {slice, turn_id} = open_turn()

    subtasks = [
      %{id: :nl, mention: worker_uri("nl"), prompt: "answer"},
      %{id: :page, mention: worker_uri("page"), prompt: "render"}
    ]

    assert {:ok, slice2, %{expected: [:nl, :page]}, effects} =
             Invoker.invoke_with_effects(
               Turn,
               :dispatch,
               slice,
               %{turn_id: turn_id, subtasks: subtasks},
               ctx()
             )

    turn = slice2.turns[turn_id]
    assert turn.status == :delegating
    assert turn.expected == MapSet.new([:nl, :page])

    dispatches =
      for {:dispatch, %Cmd{} = cmd} <- effects, do: cmd

    assert length(dispatches) == 2
    assert Enum.all?(dispatches, &(&1.action == :send))

    correlations =
      Enum.map(dispatches, fn cmd ->
        message = cmd.args.message
        assert message.body.text in ["answer", "render"]
        assert message.sender == ctx().caller
        message.body.metadata.correlation
      end)

    assert %{turn_id: turn_id, subtask_id: "nl"} in correlations
    assert %{turn_id: turn_id, subtask_id: "page"} in correlations
  end

  test "turn.dispatch rejects unknown turns" do
    assert {:error, :unknown_turn} =
             Invoker.invoke_with_effects(
               Turn,
               :dispatch,
               %{turns: %{}, turn_seq: 0},
               %{turn_id: "missing", subtasks: []},
               ctx()
             )
  end

  test "turn.deliver records collected cards and stays aggregating" do
    {slice, turn_id} = open_turn()

    {:ok, slice, _result, _effects} =
      Invoker.invoke_with_effects(
        Turn,
        :dispatch,
        slice,
        %{
          turn_id: turn_id,
          subtasks: [
            %{id: :nl, mention: worker_uri("nl"), prompt: "answer"},
            %{id: :page, mention: worker_uri("page"), prompt: "render"}
          ]
        },
        ctx()
      )

    assert {:ok, slice, %{collected: [:nl]}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :deliver,
               slice,
               %{turn_id: turn_id, subtask_id: :nl, card_ref: %{kind: "text"}},
               ctx()
             )

    assert slice.turns[turn_id].status == :aggregating
    assert slice.turns[turn_id].collected[:nl] == %{kind: "text"}

    assert {:ok, slice, %{collected: [:nl, :page]}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :deliver,
               slice,
               %{turn_id: turn_id, subtask_id: :page, card_ref: %{kind: "page"}},
               ctx()
             )

    assert slice.turns[turn_id].status == :aggregating
  end

  test "turn.deliver rejects unknown turn and unexpected subtask" do
    {slice, turn_id} = open_turn()

    assert {:error, :unexpected_subtask} =
             Invoker.invoke_with_effects(
               Turn,
               :deliver,
               slice,
               %{turn_id: turn_id, subtask_id: :ghost, card_ref: %{}},
               ctx()
             )

    assert {:error, :unknown_turn} =
             Invoker.invoke_with_effects(
               Turn,
               :deliver,
               slice,
               %{turn_id: "missing", subtask_id: :nl, card_ref: %{}},
               ctx()
             )
  end

  test "two open turns collect out-of-order replies independently" do
    {slice, turn_a} = open_turn()
    {slice, turn_b} = open_turn(slice)

    {:ok, slice, _result, _effects} =
      Invoker.invoke_with_effects(
        Turn,
        :dispatch,
        slice,
        %{turn_id: turn_a, subtasks: [%{id: :nl, mention: worker_uri("nl"), prompt: "a"}]},
        ctx()
      )

    {:ok, slice, _result, _effects} =
      Invoker.invoke_with_effects(
        Turn,
        :dispatch,
        slice,
        %{turn_id: turn_b, subtasks: [%{id: :page, mention: worker_uri("page"), prompt: "b"}]},
        ctx()
      )

    {:ok, slice, _result, _effects} =
      Invoker.invoke_with_effects(
        Turn,
        :deliver,
        slice,
        %{turn_id: turn_b, subtask_id: :page, card_ref: %{turn: "b"}},
        ctx()
      )

    {:ok, slice, _result, _effects} =
      Invoker.invoke_with_effects(
        Turn,
        :deliver,
        slice,
        %{turn_id: turn_a, subtask_id: :nl, card_ref: %{turn: "a"}},
        ctx()
      )

    assert slice.turns[turn_a].collected == %{nl: %{turn: "a"}}
    assert slice.turns[turn_b].collected == %{page: %{turn: "b"}}
  end

  test "compose, settle, claim, and cancel enforce legal transitions" do
    {slice, turn_id} = open_turn()

    assert {:ok, slice, %{status: :composing}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :compose,
               slice,
               %{turn_id: turn_id, result_refs: [%{kind: "text"}]},
               ctx()
             )

    assert slice.turns[turn_id].result.refs == [%{kind: "text"}]
    assert slice.turns[turn_id].result.message_ids == []

    assert {:ok, slice, %{status: :awaiting_human}, _effects} =
             Invoker.invoke_with_effects(
               Turn,
               :claim,
               slice,
               %{turn_id: turn_id, by: agent_uri("operator")},
               ctx()
             )

    assert slice.turns[turn_id].owner == agent_uri("operator")
    assert slice.turns[turn_id].mode == :copilot

    assert {:ok, slice, %{status: :settled}, _effects} =
             Invoker.invoke_with_effects(Turn, :settle, slice, %{turn_id: turn_id}, ctx())

    assert {:error, {:illegal_transition, :settled}} =
             Invoker.invoke_with_effects(
               Turn,
               :compose,
               slice,
               %{turn_id: turn_id, result_refs: []},
               ctx()
             )

    assert {:error, {:illegal_transition, :settled}} =
             Invoker.invoke_with_effects(Turn, :settle, slice, %{turn_id: turn_id}, ctx())

    {slice, cancel_id} = open_turn(slice)

    assert {:ok, slice, %{status: :cancelled}, _effects} =
             Invoker.invoke_with_effects(Turn, :cancel, slice, %{turn_id: cancel_id}, ctx())

    assert {:error, {:illegal_transition, :cancelled}} =
             Invoker.invoke_with_effects(Turn, :settle, slice, %{turn_id: cancel_id}, ctx())
  end

  test "compose rejects illegal non-aggregating turns with expected subtasks" do
    {slice, turn_id} = open_turn()

    {:ok, slice, _result, _effects} =
      Invoker.invoke_with_effects(
        Turn,
        :dispatch,
        slice,
        %{turn_id: turn_id, subtasks: [%{id: :nl, mention: worker_uri("nl"), prompt: "a"}]},
        ctx()
      )

    assert {:error, {:illegal_transition, :delegating}} =
             Invoker.invoke_with_effects(
               Turn,
               :compose,
               slice,
               %{turn_id: turn_id, result_refs: []},
               ctx()
             )
  end
end
