defmodule Ezagent.Identity.CapAbsorbAwait do
  @moduledoc """
  Short-lived operator-process durability barrier for capability self-store.

  Long-lived producers deliberately return when every `absorb_cap` cast is
  accepted or buffered. A standalone Mix task cannot exit while the only copy
  still lives in an in-memory delivery buffer, so it calls `await_exact/3`
  before reporting success. Exact artifact equality (including issuance
  metadata) prevents an older logical capability from satisfying the barrier.
  """

  @doc """
  Wait until every exact issued artifact is visible in `entity_uri`'s verified
  capability set, or return the artifacts still missing at `timeout_ms`.

  This is an operator-process durability barrier for short-lived Mix tasks;
  long-lived runtime producers remain non-blocking after the absorb handoff.
  """
  @spec await_exact(URI.t(), [Ezagent.Capability.t()], non_neg_integer()) ::
          :ok | {:error, {:absorb_not_committed, [Ezagent.Capability.t()]}}
  def await_exact(%URI{} = entity_uri, issued_caps, timeout_ms)
      when is_list(issued_caps) and is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_exact(Ezagent.URI.instance(entity_uri), issued_caps, deadline)
  end

  defp do_await_exact(entity_uri, issued_caps, deadline) do
    stored_caps = Ezagent.IdentityCaps.load(entity_uri)
    missing = Enum.reject(issued_caps, &Enum.member?(stored_caps, &1))

    cond do
      missing == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:absorb_not_committed, missing}}

      true ->
        Process.sleep(10)
        do_await_exact(entity_uri, issued_caps, deadline)
    end
  end
end
