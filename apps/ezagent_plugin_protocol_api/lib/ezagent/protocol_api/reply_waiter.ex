defmodule Ezagent.ProtocolApi.ReplyWaiter do
  @moduledoc """
  Per-request reply waiter.
  Blocks in receive loop, matches Publisher events by ref_id + sender.
  """
  alias Ezagent.Publisher.Event
  @default_deadline_ms 120_000

  @spec wait_for_reply(String.t(), URI.t(), pos_integer()) :: {:ok, Ezagent.Message.t()} | {:error, :timeout}
  def wait_for_reply(request_id, %URI{} = target_agent_uri, deadline_ms \\ @default_deadline_ms)
      when is_binary(request_id) and is_integer(deadline_ms) and deadline_ms > 0 do
    deadline = :erlang.monotonic_time(:millisecond) + deadline_ms
    do_wait(request_id, target_agent_uri, deadline)
  end

  defp do_wait(request_id, target_agent_uri, deadline) do
    remaining = deadline - :erlang.monotonic_time(:millisecond)
    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:publisher_event, %Event{slice_key: :session, payload: payload}} ->
          # Publisher event payload: %{new_slice: %{state: <slice_map>}}
          # where slice_map has :last_message
          case get_in(payload, [:new_slice, :state, :last_message]) do
            %Ezagent.Message{} = msg ->
              if msg.ref_id == request_id and msg.sender == target_agent_uri do
                {:ok, msg}
              else
                do_wait(request_id, target_agent_uri, deadline)
              end
            _ ->
              do_wait(request_id, target_agent_uri, deadline)
          end
        {:publisher_event, _} -> do_wait(request_id, target_agent_uri, deadline)
        _ -> do_wait(request_id, target_agent_uri, deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end
end
