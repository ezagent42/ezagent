defmodule Ezagent.Entity.Salesperson do
  @moduledoc """
  The `@salesperson` Kind — a session-member agent that replies to a user request
  with a json-render fragment (table/card) in a chat bubble, without touching the
  page. Composes `Ezagent.Behavior.Salesperson` (the `:receive` card-reply hook);
  the counterpart to `Ezagent.Entity.HelloBuilder`.

  One per hello session, named `entity://<ws>/agent/salesperson_<name>`, spawned +
  joined alongside the builder when the hello app session is instantiated
  (`EzagentPluginHello.App`). `@hello` edits the page; `@salesperson` replies
  json-render data cards.
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :salesperson,
    supervisor: EzagentDomainInstanceMessage.AgentSupervisor

  @behaviour Ezagent.Kind

  attach(Ezagent.Behavior.Salesperson)

  # Narrow hello-owned member; keep identity behaviors so explicit caps are
  # inspectable, mirroring the builder.
  attach(Ezagent.Behavior.Identity)
  attach(Ezagent.Behavior.IdentityAdmin)

  def behaviors,
    do: [
      Ezagent.Behavior.Salesperson,
      Ezagent.Behavior.Identity,
      Ezagent.Behavior.IdentityAdmin
    ]

  def persistence, do: {:snapshot, :on_change}
end
