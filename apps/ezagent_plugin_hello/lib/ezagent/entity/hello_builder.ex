defmodule Ezagent.Entity.HelloBuilder do
  @moduledoc """
  Hello builder Kind — a session-member agent that generates `@json-render`
  pages. Composes only `Ezagent.Behavior.HelloBuilder` (the `:receive`
  page-generation hook); the smallest Kind that drives an LLM and lands a page
  on the session's `Behavior.Surface`.

  One hello builder per hello session, named `entity://<ws>/agent/hello_<name>`,
  spawned + joined when the hello app session is instantiated
  (`EzagentPluginHello.App`).
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :hello_builder,
    supervisor: EzagentDomainInstanceMessage.AgentSupervisor

  @behaviour Ezagent.Kind

  attach(Ezagent.Behavior.HelloBuilder)

  # Phase 1 — the builder is the session ORCHESTRATOR, so it must RECEIVE granted
  # caps (`{:within_session, S}` etc., via `App.grant_orchestrator_caps`) to fan
  # out to workers. The identity-cap machinery is split across two behaviors that
  # share the `:identity` slice: `Identity` holds the safe READ actions
  # (`:list_caps`/`:has_cap?`) and `IdentityAdmin` holds the privileged WRITE
  # actions (`:grant_cap`/`:revoke_cap`) — the latter is what actually receives a
  # grant. Both are registered on the `Agent` Kind too; here we compose them on the
  # hello-owned orchestrator Kind. The remaining `Entity.Agent` base behaviors
  # (Sandbox/ApiKeys/CredentialGrant/ConfigEvolve) are deliberately NOT composed —
  # the orchestrator needs none of them.
  attach(Ezagent.Behavior.Identity)
  attach(Ezagent.Behavior.IdentityAdmin)

  # Kind.Server still reads behaviors/0; keep the legacy callback.
  def behaviors,
    do: [
      Ezagent.Behavior.HelloBuilder,
      Ezagent.Behavior.Identity,
      Ezagent.Behavior.IdentityAdmin
    ]

  # The builder now holds DURABLE state — its granted orchestrator caps (the
  # `:caps` slice). Snapshot on change so the authority survives a cold restart.
  def persistence, do: {:snapshot, :on_change}
end
