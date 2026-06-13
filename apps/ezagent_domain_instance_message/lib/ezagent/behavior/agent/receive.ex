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

  # lifecycle:state_slice_override
  #
  # codex P3 (PR-2): the macro would auto-derive `:receive` from the module
  # name, but `Entity.Agent` has no `:receive` slice — so the runtime would
  # fetch `%{}` and commit `Map.put(state, :receive, %{})`, leaving a durable
  # ORPHAN slice on snapshot-on-change Agents after the first inbound message.
  # Pin to `:session` — the EXISTING receive-state slice that `Entity.Agent`
  # already materializes via `Ezagent.Behavior.Session` in its `behaviors/0`
  # (the same slice the pre-split Agent branch used, and that `User.Receive`
  # pins to). This handler emits NO effects, so the slice is read + committed
  # UNCHANGED — no orphan, no write.
  use Ezagent.Lifecycle, state_slice: :session
  reads_siblings([:sandbox])

  require Logger

  alias Ezagent.{Cmd, Message}
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
  (self-healing a vanished bridge); a same-process side effect.

  ## Two transport classes — one flavor-blind handler

    * `:subprocess_ws` (cc / codex) → `deliver` returns `:ok`; the agent's
      reply is ASYNC (bridge → `session.send`). The handler emits NO
      effects (the Agent Kind has no receive slice).

    * `:in_process_sync` (curl, PR-6 §3.5 / §9 tension 3) → `deliver`
      returns `{:sync, result}` SYNCHRONOUSLY (`result` is the adapter's
      `{:ok, _}` / `{:error, _}`). The handler re-dispatches that result to
      the SAME agent URI's `:sync_result` action via a `{:dispatch, %Cmd{}}`
      effect, so the flavor's STATE Behavior (curl) persists the conversation
      + replies. The branch is on the `{:sync, _}` CLASS TAG, not the flavor
      name — `agent.receive` stays flavor-blind (any future
      `:in_process_sync` flavor whose Behavior owns a `:sync_result` action
      gets the same treatment), and a `:subprocess_ws` `{:error, :no_bridge}`
      is never mistaken for a sync result.
  """
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    # AgentBridge PR-D / PR-6: keep receive flavor-neutral. Payload build +
    # self-healing bridge delivery live in `Session.Delivery` (the shared
    # helper). The CLASS-TAGGED delivery result decides whether we re-dispatch.
    case Delivery.deliver_agent_receive(msg, ctx) do
      :ok ->
        # :subprocess_ws — async reply through the bridge; nothing to do.
        {:ok, %{}, []}

      {:sync, sync_result} ->
        # :in_process_sync — re-dispatch the result into the flavor's
        # :sync_result Behavior to persist + reply.
        {:ok, %{}, [sync_result_effect(msg, ctx, sync_result)]}
    end
  end

  # Build the `{:dispatch, %Cmd{}}` that hands the `:in_process_sync`
  # delivery result to the agent's own `:sync_result` action. Runs under
  # the `system://chat-router` principal (same as the `:receive` dispatch
  # the result came from) so the in-process re-dispatch carries no ambient
  # authority.
  defp sync_result_effect(%Message{} = msg, ctx, sync_result) do
    self_uri = ctx[:self_uri]
    source_session = ctx[:caller]
    user_text = Delivery.body_text(msg.body)

    target = Ezagent.URI.with_action(self_uri, :sync_result, :sync_result)

    cmd =
      Cmd.new(
        target,
        :sync_result,
        %{result: sync_result, source_session: source_session, user_text: user_text},
        %{
          caller: source_session,
          caps: "chat-router" |> Ezagent.SystemPrincipal.uri() |> Ezagent.SystemPrincipal.caps(),
          reply: :ignore
        }
      )

    {:dispatch, cmd}
  end
end
