defmodule Ezagent.Behavior.Agent.Receive do
  @moduledoc """
  `agent.receive` — the Agent Kind's active live-process delivery
  `:receive` Behavior.

  ## Why this exists (im/session/agent decomposition — PR-2)

  The single `Ezagent.Behavior.Session.handle_receive/2` used to branch
  internally on `ctx[:kind_module]` (`Entity.User` → inbox slice;
  `Entity.Agent` → AgentBridge). SPEC
  `docs/superpowers/specs/2026-06-12-im-session-agent-decomposition-design.md`
  §OQ-4 / §3.3 splits that one action into TWO first-class Behaviors —
  `user.receive` (`Ezagent.Behavior.User.Receive`, passive inbox) and
  `agent.receive` (this module, active live-process delivery) — each
  registered for `:receive` on its own Kind. They are genuinely different
  (passive inbox vs active process delivery) and are NOT merged. The
  internal `case kind_module` is retired.

  ## Where this lives (PR-2 vs PR-9)

  Conceptually this is the **agent domain's** transport seam (§3.3 — it
  hands DOWN to a flavor-blind `AgentBridge.deliver`). Physically it
  STAYS in `ezagent_domain_instance_message` until PR-9 carves out
  `domain.agent`; the extraction in PR-2 is the action split, not the app
  move. The delivery mechanics remain in
  `Ezagent.Behavior.Session.Delivery.deliver_agent_receive/2` (the shared
  helper both PR-2 and the future PR-9 reuse), so PR-9 relocates one
  module, not a re-derivation.

  ## What `agent.receive` does (extracted VERBATIM from the Agent branch)

  Builds a flavor-neutral `Ezagent.AgentBridge.Payload` from the message
  + ctx and delivers it via `Ezagent.AgentBridge`, self-healing a
  vanished bridge (cc / codex subprocess relaunch + rebind await). This
  is a same-process side effect (no slice state); the handler emits no
  effects (`{:ok, %{}, []}`). The bridge resolves the bound channel +
  per-flavor adapter; a missing bridge/adapter is best-effort (logged by
  AgentBridge), because `:receive` is a `:cast`.

  ## Slice ownership

  NONE. The Agent Kind carries no `:receive` slice — delivery is a live
  side effect, not durable state. (The agent's OWN durable state, e.g.
  the cc/codex bridge or the curl conversation, lives on its flavor
  Behavior, not here.) `reads_siblings([:sandbox])` is declared because
  the delivery helper resolves the agent's flavor from the sibling
  `:sandbox` slice (`ctx[:siblings][:sandbox]` →
  `UriQueryResolvers.resolve_flavor_from_sandbox/1`) to pick the right
  AgentBridge adapter (cc / codex / …).

  ## Naming (§11 NP-1/NP-2/NP-3 audit)

  `Ezagent.Behavior.Agent.Receive` — a domain module naming its own
  concept; the name tracks the single action's intent (`receive`) at the
  narrowest accurate scope (NP-1), in its own layer's vocabulary (NP-2),
  with a width that matches its one action (NP-3). No violation.
  """

  use Ezagent.Lifecycle
  reads_siblings([:sandbox])

  require Logger

  alias Ezagent.Message
  alias Ezagent.Behavior.Session.Delivery

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Deliver an inbound session message to this Agent via AgentBridge"
  )

  # --- :receive ----------------------------------------------------------

  @doc """
  Deliver an inbound session message to the live agent via AgentBridge
  (extracted VERBATIM from the Agent branch of
  `Ezagent.Behavior.Session.handle_receive/2`).

  Builds the flavor-neutral payload and pushes it through AgentBridge
  (self-healing a vanished bridge); a same-process side effect. The
  Agent Kind has no receive slice, so this returns `{:ok, %{}, []}`.
  """
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    # AgentBridge PR-D: keep receive flavor-neutral. Payload build +
    # self-healing bridge delivery live in `Session.Delivery` (the shared
    # helper) — same-process side-effect, the handler emits no effects.
    _ = Delivery.deliver_agent_receive(msg, ctx)
    {:ok, %{}, []}
  end
end
