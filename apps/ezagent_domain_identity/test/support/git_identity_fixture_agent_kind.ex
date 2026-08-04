defmodule Ezagent.Identity.Test.GitIdentityFixtureAgentKind do
  @moduledoc """
  Minimal live `:agent`-type Kind for `agent_git_identity_test.exs`.

  Exists purely so `Ezagent.Identity.absorb_cap/2` has somewhere to deliver
  to — a bare `entity://.../agent/...` URI that was never spawned resolves
  `:no_such_actor` (confirmed empirically: there is no live process AND no
  snapshot row, which is different from "not ready yet").

  Carries `Ezagent.ActionSet.Identity`, `Ezagent.ActionSet.IdentityAdmin`, AND
  `Ezagent.ActionSet.Sandbox` — confirmed empirically that `:absorb_cap` lives
  on `IdentityAdmin` (a SEPARATE module defined in the same `identity.ex`
  file, split out per PR-OWN-3 "cap-only, privileged actions"), not on
  `Identity` itself. The sibling fixture `Ezagent.Identity.Test.DeleteUserAgentKind`
  (used by `delete_user_completeness_test.exs`) only carries `Identity` and
  therefore cannot receive `absorb_cap` — reusing it here reproduced a real
  `{:unknown_action, :absorb_cap}` dispatch failure (RF-1's per-instance
  fallback in `Ezagent.Kind.BehaviorSet.resolve_action/3` only searches the
  Kind's OWN declared `behaviors/0`; `:absorb_cap` is registered in
  production only for `User` and the real `Ezagent.Entity.Agent`, neither of
  which this fixture is). Both production Kinds always carry `Identity` +
  `IdentityAdmin` together (`EzagentDomainIdentity.Application.
  register_identity_behaviors/0`: "Registered against the same Kinds as
  `Identity` since both share the `:identity` slice") — this fixture mirrors
  that pairing rather than depending on `ezagent_domain_agent`'s real
  `Ezagent.Entity.Agent` (`ezagent_domain_identity` does not depend on that
  app; see the 1b design doc §2 dependency-direction note).

  `Sandbox` is ADDED (B2' revoke-ordering fix, 2026-08-04): `identity.ex`'s
  `maybe_add_git_identity_wipe/3` / `maybe_add_recipe_binding_git_identity_wipe/4`
  now emit `{:dispatch_after_commit, %Ezagent.Cmd{action: :wipe_git_identity}}`
  targeting the SAME agent instance instead of running the wipe synchronously
  in-handler — without `Sandbox` mounted here, that deferred dispatch fails
  `{:unknown_action, :wipe_git_identity}` (empirically confirmed: the fixture
  Kind's OWN declared `behaviors/0` is what `BehaviorSet.resolve_action/3`
  searches, same RF-1 constraint as `:absorb_cap` above). `Sandbox` lives in
  `ezagent_core`, which `ezagent_domain_identity` already depends on — no new
  cross-app dependency. The real `Ezagent.Entity.Agent`
  (`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex` `base_behaviors/0`)
  always carries `Sandbox`; this fixture mirrors that too.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :agent

  @impl Ezagent.Kind
  def behaviors,
    do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.IdentityAdmin, Ezagent.ActionSet.Sandbox]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}
end
