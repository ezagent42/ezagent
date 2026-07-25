defmodule Ezagent.Kind.Adapters.AuthzAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.AuthzPort` (§3.4) — delegates
  to the `Ezagent.Cap.Verifier` / `Ezagent.Cap.Grant` /
  `Ezagent.CapabilityRegistry` spine and the RELOCATED holds-cap spine
  `Ezagent.Cap.HoldsCap`. Owns the representation check for
  `authorize_and_issue_grant/6` (§3.4 opacity rule: the framework passes
  the cap as OPAQUE `term()`; a non-`Ezagent.Capability` input is rejected
  as `{:error, :invalid_artifact}`). STAYS in core when the framework moves
  to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.AuthzPort

  @impl true
  def authorize_dispatch(kind_module, behavior_module, action, target, holder, ctx),
    do:
      Ezagent.Cap.Verifier.authorize(
        kind_module,
        behavior_module,
        action,
        target,
        holder,
        ctx
      )

  @impl true
  def authorize_and_issue_grant(kind_module, target, origin, ctx, grantee, cap) do
    if is_struct(cap, Ezagent.Capability) do
      Ezagent.Cap.Grant.authorize_and_issue_current(
        kind_module,
        target,
        origin,
        ctx,
        grantee,
        cap
      )
    else
      {:error, :invalid_artifact}
    end
  end

  @impl true
  def data_owner_of(behavior, instance),
    do: Ezagent.CapabilityRegistry.data_owner_of(behavior, instance)

  @impl true
  def holds_cap?(kind_module, entity_uri, needed),
    do: Ezagent.Cap.HoldsCap.holds_cap?(kind_module, entity_uri, needed)

  @impl true
  def default_holds_cap?(entity_uri, needed),
    do: Ezagent.Cap.HoldsCap.default_holds_cap?(entity_uri, needed)
end
