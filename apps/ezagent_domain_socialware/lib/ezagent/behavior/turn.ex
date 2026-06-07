defmodule Ezagent.Behavior.Turn do
  @moduledoc """
  Socialware orchestration state machine.

  Owns the `:turns` slice. Surface approval and customer visibility are
  layered in later phases; P1 records the durable turn lifecycle and emits
  worker delegation through dispatch.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :turns

  alias Ezagent.{Cmd, Message}

  @terminal_statuses [:settled, :cancelled]

  action(:open,
    args: %{trigger: :map, opened_at: :integer},
    returns: %{turn_id: :string},
    caps: [:open],
    modes: [:call],
    description: "Open a new socialware turn"
  )

  action(:dispatch,
    args: %{turn_id: :string, subtasks: {:list, :map}},
    returns: %{expected: {:list, :atom}},
    caps: [:dispatch],
    modes: [:call],
    description: "Record expected subtasks and delegate work through chat.send"
  )

  action(:deliver,
    args: %{turn_id: :string, subtask_id: :atom, card_ref: :map},
    returns: %{collected: {:list, :atom}},
    caps: [:deliver],
    modes: [:call],
    description: "Collect a worker deliverable for a turn"
  )

  action(:compose,
    args: %{turn_id: :string, result_refs: {:list, :map}},
    returns: %{status: :atom},
    caps: [:compose],
    modes: [:call],
    description: "Compose collected deliverables into a turn result"
  )

  action(:claim,
    args: %{turn_id: :string, by: :uri},
    returns: %{status: :atom},
    caps: [:claim],
    modes: [:call],
    description: "Move a composed turn into human review"
  )

  action(:settle,
    args: %{turn_id: :string},
    returns: %{status: :atom},
    caps: [:settle],
    modes: [:call],
    description: "Mark a composed or approved turn as settled"
  )

  action(:cancel,
    args: %{turn_id: :string},
    returns: %{status: :atom},
    caps: [:cancel],
    modes: [:call],
    description: "Cancel a non-terminal turn"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{turns: %{}, turn_seq: 0}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @spec handle_open(map(), map()) :: {:ok, map(), [term()]}
  def handle_open(%{trigger: trigger, opened_at: opened_at}, ctx) do
    turns = ctx.read.(:turns, %{})
    turn_no = ctx.read.(:turn_seq, 0) + 1
    turn_id = turn_id(ctx.self_uri, turn_no)

    turn = %{
      trigger: trigger,
      owner: ctx.caller,
      mode: :auto,
      expected: MapSet.new(),
      collected: %{},
      result: [],
      status: :open,
      turn_no: turn_no,
      opened_at: opened_at
    }

    {:ok, %{turn_id: turn_id},
     [
       {:set, :turns, Map.put(turns, turn_id, turn)},
       {:set, :turn_seq, turn_no}
     ]}
  end

  @spec handle_dispatch(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_dispatch(%{turn_id: turn_id, subtasks: subtasks}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      if terminal?(turn.status) do
        {:error, {:illegal_transition, turn.status}}
      else
        subtask_ids = Enum.map(subtasks, &subtask_id!/1)
        expected = MapSet.new(subtask_ids)
        updated = %{turn | expected: expected, status: :delegating}
        dispatches = Enum.map(subtasks, &dispatch_subtask(&1, turn_id, ctx))

        {:ok, updated, %{expected: subtask_ids}, dispatches}
      end
    end)
  end

  @spec handle_deliver(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_deliver(%{turn_id: turn_id, subtask_id: subtask_id, card_ref: card_ref}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      cond do
        not MapSet.member?(turn.expected, subtask_id) ->
          {:error, :unexpected_subtask}

        terminal?(turn.status) ->
          {:error, {:illegal_transition, turn.status}}

        true ->
          collected = Map.put(turn.collected, subtask_id, card_ref)
          updated = %{turn | collected: collected, status: :aggregating}
          {:ok, updated, %{collected: Map.keys(collected)}, []}
      end
    end)
  end

  @spec handle_compose(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_compose(%{turn_id: turn_id, result_refs: result_refs}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      case compose_allowed?(turn) do
        :ok ->
          updated = %{turn | result: result_refs, status: :composing}
          {:ok, updated, %{status: :composing}, []}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec handle_claim(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_claim(%{turn_id: turn_id, by: by}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      case transition(turn.status, :awaiting_human) do
        :ok ->
          updated = %{turn | owner: by, mode: :copilot, status: :awaiting_human}
          {:ok, updated, %{status: :awaiting_human}, []}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec handle_settle(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_settle(%{turn_id: turn_id}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      case transition(turn.status, :settled) do
        :ok ->
          updated = %{turn | status: :settled}
          {:ok, updated, %{status: :settled}, []}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec handle_cancel(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_cancel(%{turn_id: turn_id}, ctx) do
    update_turn(ctx, turn_id, fn turn ->
      case transition(turn.status, :cancelled) do
        :ok ->
          updated = %{turn | status: :cancelled}
          {:ok, updated, %{status: :cancelled}, []}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp update_turn(ctx, turn_id, fun) do
    turns = ctx.read.(:turns, %{})

    case Map.fetch(turns, turn_id) do
      {:ok, turn} ->
        case fun.(turn) do
          {:ok, updated_turn, result, effects} ->
            {:ok, result, [{:set, :turns, Map.put(turns, turn_id, updated_turn)} | effects]}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :unknown_turn}
    end
  end

  defp turn_id(%URI{} = session_uri, turn_no) do
    URI.to_string(session_uri) <> "#turn-" <> Integer.to_string(turn_no)
  end

  defp dispatch_subtask(subtask, turn_id, ctx) do
    subtask_id = subtask_id!(subtask)
    mention = fetch_subtask!(subtask, :mention)
    prompt = fetch_subtask!(subtask, :prompt)

    message =
      Message.new(
        ctx.caller,
        %{
          text: prompt,
          attachments: [],
          metadata: %{
            correlation: %{
              turn_id: turn_id,
              subtask_id: Atom.to_string(subtask_id)
            }
          }
        },
        mentions: [mention]
      )

    {:dispatch, Cmd.new(ctx.self_uri, :send, %{message: message}, dispatch_ctx(ctx))}
  end

  defp dispatch_ctx(ctx) do
    %{
      caller: ctx.caller,
      caps: Map.get(ctx, :caps, MapSet.new()),
      reply: :ignore,
      trace_id: Map.get(ctx, :trace_id),
      deadline_ms: Map.get(ctx, :deadline_ms)
    }
  end

  defp subtask_id!(subtask), do: fetch_subtask!(subtask, :id)

  defp fetch_subtask!(subtask, key) do
    case Map.fetch(subtask, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(subtask, Atom.to_string(key))
    end
  end

  defp compose_allowed?(%{status: :aggregating}), do: :ok

  defp compose_allowed?(%{status: :open, expected: expected}) do
    if MapSet.size(expected) == 0 do
      :ok
    else
      {:error, {:illegal_transition, :open}}
    end
  end

  defp compose_allowed?(%{status: status}), do: {:error, {:illegal_transition, status}}

  defp transition(status, _to) when status in @terminal_statuses,
    do: {:error, {:illegal_transition, status}}

  defp transition(:composing, :awaiting_human), do: :ok
  defp transition(:composing, :settled), do: :ok
  defp transition(:awaiting_human, :settled), do: :ok
  defp transition(status, :cancelled) when status not in @terminal_statuses, do: :ok
  defp transition(status, _to), do: {:error, {:illegal_transition, status}}

  defp terminal?(status), do: status in @terminal_statuses
end
