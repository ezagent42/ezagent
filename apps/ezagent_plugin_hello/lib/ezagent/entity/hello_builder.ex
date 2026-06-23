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

  # The builder is a narrow hello-owned member, not a cc-style orchestrator.
  # Keep identity behaviors so tests/tools can inspect any explicit caps granted
  # to the builder without composing the broader Entity.Agent behavior set.
  attach(Ezagent.Behavior.Identity)
  attach(Ezagent.Behavior.IdentityAdmin)

  # Kind.Server still reads behaviors/0; keep the legacy callback.
  def behaviors,
    do: [
      Ezagent.Behavior.HelloBuilder,
      Ezagent.Behavior.Identity,
      Ezagent.Behavior.IdentityAdmin
    ]

  # The builder can hold durable identity state; snapshot on change so any
  # explicit caps survive a cold restart.
  def persistence, do: {:snapshot, :on_change}
end
