defmodule Ezagent.Entity.System do
  @moduledoc """
  System Kind — `system://*` platform sentinels.

  PR #146 (SPEC v2 §5.6 + §5.7 + §5.10) introduces this Kind so the
  dissolution of `routing-admin://default` has a real home for the
  **global-scope** routing rule mutations. The canonical singleton
  per SPEC §5.10 is `system://routing/default`; future sentinels
  (`system://bootstrap/default`, `system://migration-<id>`) reuse the
  same Kind module.

  Carries `Ezagent.ActionSet.Routing` so global routing rule mutations
  dispatch through the regular CapBAC pipeline. Non-admin operators
  who should manage global rules receive a cap of
  `%Ezagent.Capability{kind: :system, behavior: Ezagent.ActionSet.Routing,
  instance: system://routing/default}`. Admin's triple-`:any`
  satisfies by default.

  Persistence `:ephemeral` — the Behavior's slice is a trivial
  counter; rules themselves live in Postgres via `Ezagent.Routing.RuleStore`.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :system

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.ActionSet.Routing]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def uri_from_args(args), do: Map.fetch!(args, :uri)

  # V1 prevention (Allen 2026-05-21): system Kinds live under the
  # core singleton supervisor. `Ezagent.Kind.spawn/2` reads this.
  @impl Ezagent.Kind
  def supervisor, do: Ezagent.Core.SingletonSupervisor

  @doc """
  Canonical URI for the global routing-rule sentinel:
  `system://routing/default` (SPEC §5.10).
  """
  @spec routing_default_uri() :: URI.t()
  def routing_default_uri, do: Ezagent.URI.system(:routing, :default)
end
