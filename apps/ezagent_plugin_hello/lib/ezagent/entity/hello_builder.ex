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

  # Kind.Server still reads behaviors/0; keep the legacy callback.
  def behaviors, do: [Ezagent.Behavior.HelloBuilder]

  # Phase 0 holds no durable builder state (`create/1` is empty, the prompt is
  # static, API config comes from env), so the builder is ephemeral — like echo.
  # When the builder grows durable state (per-session catalog refs, conversation),
  # switch to `{:snapshot, :on_change}`.
  def persistence, do: :ephemeral
end
