defmodule Ezagent.Kind.Ports.DispatchPolicyPort do
  @moduledoc """
  §3.4 DispatchPolicyPort — the actor framework's dispatch-policy surface,
  resolved via `Application.fetch_env!(:ezagent_actor, :dispatch_policy)`.

  Owner (core spine): `Ezagent.DispatchOrigin` + `Ezagent.WorkspaceOwnerGate`
  + `Ezagent.Cap` (ONE core adapter,
  `Ezagent.Kind.Adapters.DispatchPolicyAdapter`). The invocation crosses as
  `term()`; the adapter owns the origin-validate + owner-gate + admin-cap
  materialization policy (`materialize_admin_action_cap` +
  `globally_non_cap_action?` MOVED out of `Ezagent.Invocation` — policy, not
  mechanics). Moves with the framework to `apps/ezagent_actor`.
  """

  @doc """
  Pre-delivery policy fold for `Invocation.dispatch/1`: origin validation +
  canonical-admin action-cap materialization + workspace owner gate.
  Returns the (possibly cap-enriched) invocation or the policy error.
  """
  @callback before_delivery(inv :: term()) :: {:ok, term()} | {:error, term()}

  @doc "Re-dispatch origin check inside the actor (dispatch step 5)."
  @callback validate_origin(origin :: term(), ctx :: map()) :: :ok | {:error, term()}

  @doc "Workspace owner gate on the SPAWN/LIVENESS path (per-URI, not per-invocation)."
  @callback assert_local_owner(uri :: term(), tag :: term()) :: :ok | {:error, term()}
end
