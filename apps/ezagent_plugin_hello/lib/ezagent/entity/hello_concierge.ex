defmodule Ezagent.Entity.HelloConcierge do
  @moduledoc """
  Hello CONCIERGE Kind — a READ-ONLY session-member agent that answers visitor
  questions about the site (navigation / Q&A), NEVER editing the page. One per
  hello session, named `entity://<ws>/agent/concierge_<name>`, spawned + joined
  alongside the builder (`EzagentPluginHello.App`).

  Composes only `Ezagent.Behavior.HelloConcierge` (the read-only `:receive` hook)
  plus the identity behaviors — the smallest Kind that drives an LLM answer with
  NO Surface-write path (contrast `Ezagent.Entity.HelloBuilder`, which drives the
  page).
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :hello_concierge,
    supervisor: EzagentDomainInstanceMessage.AgentSupervisor

  @behaviour Ezagent.Kind

  attach(Ezagent.Behavior.HelloConcierge)

  # Keep identity behaviors so tests/tools can inspect any explicit caps granted
  # to the concierge (mirrors the builder).
  attach(Ezagent.Behavior.Identity)
  attach(Ezagent.Behavior.IdentityAdmin)

  # Kind.Server still reads behaviors/0; keep the legacy callback.
  def behaviors,
    do: [
      Ezagent.Behavior.HelloConcierge,
      Ezagent.Behavior.Identity,
      Ezagent.Behavior.IdentityAdmin
    ]

  # Snapshot on change so any explicit caps survive a cold restart.
  def persistence, do: {:snapshot, :on_change}
end
