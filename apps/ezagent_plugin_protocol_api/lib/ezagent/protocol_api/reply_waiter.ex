defmodule Ezagent.ProtocolApi.ReplyWaiter do
  @moduledoc """
  Per-request reply waiter — the ONE delta from Feishu.
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
          case match_reply(payload, request_id, target_agent_uri) do
            {:ok, msg} -> {:ok, msg}
            :no_match -> do_wait(request_id, target_agent_uri, deadline)
          end
        {:publisher_event, _other} -> do_wait(request_id, target_agent_uri, deadline)
        _other -> do_wait(request_id, target_agent_uri, deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  defp match_reply(%{new_slice: %{last_message: %Ezagent.Message{} = msg}}, request_id, target_agent_uri) do
    if msg.ref_id == request_id and msg.sender == target_agent_uri, do: {:ok, msg}, else: :no_match
  end
  defp match_reply(_payload, _request_id, _target_agent_uri), do: :no_match
end
