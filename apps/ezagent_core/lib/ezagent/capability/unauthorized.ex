defmodule Ezagent.Capability.Unauthorized do
  @moduledoc """
  Raised by cap-gated APIs (e.g. `Ezagent.Presence.subscribe/2`) when
  the caller's `ctx.caps` does not match the needed cap shape.

  The `:needed` field carries the 4-field needed-cap map (as returned
  by `Ezagent.CapabilityRegistry.needed_for/3` or
  `Ezagent.Capability.cap_for_action/3`) so operators / tests can
  inspect what was missing.
  """

  defexception [:needed, :message]

  @impl true
  def exception(opts) do
    needed = Keyword.get(opts, :needed)
    message = Keyword.get(opts, :message) || default_message(needed)

    %__MODULE__{needed: needed, message: message}
  end

  defp default_message(nil), do: "capability check failed"

  defp default_message(needed) do
    "capability check failed; needed: #{inspect(needed)}"
  end
end
