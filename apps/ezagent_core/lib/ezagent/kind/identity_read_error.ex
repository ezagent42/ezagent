defmodule Ezagent.Kind.IdentityReadError do
  @moduledoc """
  Raised by `Ezagent.Kind.default_holds_cap?/2` when the caller's `:identity`
  slice could NOT be read for a **transient** reason (the identity Kind is alive
  but its `GenServer.call` timed out / exited under DB-pool starvation or a
  mid-restart window, or the Kind is not-yet-registered while a durable snapshot
  for it still exists).

  ## Why this exists — fail-loud, not fail-closed

  CapBAC authorization is a security decision. A transient inability to read a
  KNOWN entity's held caps is NOT the same as "the entity holds no such cap":
  the former is an infrastructure blip, the latter is a real denial. Collapsing
  the two — the historical `_ -> false` deny-by-default — converted a DB blip
  into a spurious `:unauthorized`, which surfaced as a non-deterministic CI flake
  (WorldConversationTest `session.create` / `workspace.template.save` under a
  starved Ecto sandbox pool) AND as a latent production correctness bug (a Kind
  restart / DB failover spuriously denying a legitimate user).

  Raising here (after a bounded retry) makes the transient LOUD: the enclosing
  dispatch crashes / the caller retries, instead of a wrong security answer being
  returned silently. A genuinely-absent cap, and a genuinely non-existent entity,
  still deny cleanly (return `false`) — see `default_holds_cap?/2`.

  > **Contract for the future `cbac-done-right` cap-layer refactor:** the
  > fail-LOUD-not-DENY semantics MUST be preserved. A transient identity-read
  > failure must never be converted into a capability denial in any successor
  > implementation.
  """
  defexception [:entity_uri, :reason]

  @impl true
  def message(%{entity_uri: entity_uri, reason: reason}) do
    "transient failure reading the :identity slice for #{inspect(entity_uri)} " <>
      "(#{inspect(reason)}). Authorization refuses to convert an unreadable KNOWN " <>
      "entity into a denial — the caller must retry (fail-loud, not fail-closed)."
  end
end
