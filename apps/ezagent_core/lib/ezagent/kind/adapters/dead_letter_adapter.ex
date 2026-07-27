defmodule Ezagent.Kind.Adapters.DeadLetterAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.DeadLetterPort` (§3.4) —
  delegates 1:1 to the `Ezagent.DLQ` spine. STAYS in core when the framework
  moves to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.DeadLetterPort

  @impl true
  def put(reason, inv), do: Ezagent.DLQ.put(reason, inv)
end
