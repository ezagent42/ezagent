defmodule EzagentDomainExternalMirror.Application do
  @moduledoc """
  ExternalMirror Domain OTP application.

  ## PR-EM-0 scope

  PR-EM-0 ships the Publisher contract + Event struct only:

  - `Ezagent.Behavior.Publisher` — the `@behaviour` contract (4
    callbacks) any publishing Kind declares it implements.
  - `Ezagent.Publisher.Event` — the typed event struct subscribers
    receive on `{:publisher_event, _}`.

  The Session-side IMPLEMENTATION (`Ezagent.Behavior.Publisher.SessionImpl`
  + the `subscribe_from/3`/`snapshot/1`/`history/3` module functions
  on `Ezagent.Entity.Session`) lives in `apps/ezagent_domain_chat/`
  — chat depends on this Domain for the contract module name;
  external_mirror has zero reverse references to chat. The Kind ↔
  Behavior registration happens in `EzagentDomainChat.Application`
  (per the existing convention: Kind ↔ Behavior binding lives in
  the app that defines the Kind — see `Domain.Pty PR-B` precedent).

  Per SPEC §9 PR-EM-0 acceptance: "Application supervisor is empty
  (no children yet — PR-EM-1 adds AdapterRegistry + BindingRegistry
  + per-binding Worker supervisor topology)".
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: EzagentDomainExternalMirror.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
