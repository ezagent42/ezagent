defmodule Ezagent.Entity.Echo do
  @moduledoc """
  Echo Kind — instance type for the Phase 1 demo flow.

  `entity://agent/system/echo_default` is the default instance spawned by
  `EzagentPluginEcho.Application.start/2` (PR #141 SPEC v2 — flavor
  prefix on name). Composing only the Echo Behavior, it's the
  smallest possible Kind that exercises dispatch + audit +
  (eventually) LiveView render.

  ## Phase 2-g r3 migration (2026-05-28)

  Adopts the `use Ezagent.Kind, pattern: :entity, ...` macro per
  SPEC §2.3 + §3 composition patterns. The `attach Ezagent.Behavior.Echo`
  declaration provides OQ-2 / OQ-5 compile-time checks
  (action-collision detection, pattern compatibility). Legacy
  `behaviors/0`, `persistence/0`, `type_name/0`, `supervisor/0`
  callbacks remain — `Ezagent.Kind.Server` still reads them — but
  are now declared inline alongside the macro.
  """

  use Ezagent.Kind,
    pattern: :entity,
    uri_scheme: "entity://agent/",
    type_name: :echo,
    supervisor: EzagentDomainChat.AgentSupervisor

  @behaviour Ezagent.Kind

  attach Ezagent.Behavior.Echo

  # Kind.Server still reads behaviors/0; keep the legacy callback.
  def behaviors, do: [Ezagent.Behavior.Echo]

  # Kind.Server still reads persistence/0; keep the legacy callback.
  def persistence, do: :ephemeral
end
