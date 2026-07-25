defmodule Ezagent.Kind.Adapters.DispatchPolicyAdapter do
  @moduledoc """
  Core-side adapter for `Ezagent.Kind.Ports.DispatchPolicyPort` (§3.4) —
  folds the three pre-delivery policy checks of `Ezagent.Invocation.dispatch/1`
  (origin validation → canonical-admin action-cap materialization →
  workspace owner gate) behind ONE hook, and fronts the per-URI owner gate
  for the spawn/liveness path.

  Owns the `materialize_admin_action_cap` + `globally_non_cap_action?`
  policy MOVED OUT of `Ezagent.Invocation` (policy, not mechanics — §3.4
  "Also moving OUT of moved files into core"). STAYS in core when the
  framework moves to `apps/ezagent_actor`.
  """

  @behaviour Ezagent.Kind.Ports.DispatchPolicyPort

  # The process-local admin-operator scope key. The WRITER is
  # `Ezagent.Invocation.with_admin_operator/2` (stays with the framework);
  # the key is `{Ezagent.Invocation, :admin_operator_presenter}` there
  # (`{__MODULE__, :admin_operator_presenter}`), so the literal module atom
  # is load-bearing here — the reader moved, the key must not change.
  @admin_operator_scope_key {Ezagent.Invocation, :admin_operator_presenter}

  @impl true
  def before_delivery(%Ezagent.Invocation{target: %URI{} = target} = inv) do
    instance_uri = Ezagent.URI.instance(target)

    with :ok <- Ezagent.DispatchOrigin.validate(inv.origin, inv.ctx),
         {:ok, inv} <- materialize_admin_action_cap(inv),
         :ok <-
           Ezagent.WorkspaceOwnerGate.assert_local_owner_for_uri(
             instance_uri,
             {:dispatch, target}
           ) do
      {:ok, inv}
    end
  end

  @impl true
  def validate_origin(origin, ctx), do: Ezagent.DispatchOrigin.validate(origin, ctx)

  @impl true
  def assert_local_owner(uri, tag),
    do: Ezagent.WorkspaceOwnerGate.assert_local_owner_for_uri(uri, tag)

  # Canonical-admin operator traffic is still least-authority on the wire: after
  # the positive origin stamp has authenticated the presenter, ask the concrete
  # target's K.grant path for the exact action artifact and replace no caller
  # identity. This is the reviewed-code Path A convenience seam for UI/CLI and
  # framework operator paths; the target verifier still sees and verifies an
  # ordinary target-signed, receiver-bound capability. K.grant itself is the
  # recursion bottom and already carries the target authority anchor.
  defp materialize_admin_action_cap(
         %Ezagent.Invocation{
           target: %URI{} = target,
           ctx: %{caller: %URI{} = caller} = ctx,
           origin: origin
         } = inv
       )
       when origin in [:trusted_internal, :authenticated_external] do
    with true <- canonical_admin?(caller),
         true <- admin_operator_scope?(caller),
         true <- is_nil(target.authority),
         # Liveness via the §2.2 public surface (`Kind.alive?/1`) — never a
         # `KindRegistry.lookup` reach into actor internals (§4.2 forward
         # gate; this module is core-side, post-move core→actor).
         true <- Ezagent.Kind.alive?(Ezagent.URI.instance(target)),
         {:ok, {_behavior, action}} <- Ezagent.URI.behavior_action(target),
         false <- globally_non_cap_action?(action),
         false <- action == :grant do
      case Ezagent.Cap.issue_for_action({:admin, caller}, caller, target) do
        {:ok, cap} ->
          caps = Map.get(ctx, :caps, MapSet.new()) || MapSet.new()
          {:ok, %{inv | ctx: Map.put(ctx, :caps, MapSet.put(MapSet.new(caps), cap))}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:ok, inv}
    end
  end

  defp materialize_admin_action_cap(%Ezagent.Invocation{} = inv), do: {:ok, inv}

  # Admin convenience minting must not turn an explicitly cap-exempt action
  # into a synchronous K.grant round-trip. In-handler gates such as
  # `session.add_self` deliberately carry no presented cap; minting one here is
  # both semantically wrong and can deadlock when the action is a post-commit
  # convergence cast back into a busy target Kind.
  defp globally_non_cap_action?(action) do
    registered_handlers =
      Ezagent.BehaviorRegistry.list_all()
      |> Enum.flat_map(fn
        {{_kind, ^action}, behavior} -> [behavior]
        _entry -> []
      end)
      |> Enum.uniq()

    exempt_handlers =
      Ezagent.Cap.Verifier.non_cap_actions()
      |> Enum.flat_map(fn {behavior, actions} ->
        if MapSet.member?(actions, action), do: [behavior], else: []
      end)

    exempt_handlers != [] and
      Enum.all?(registered_handlers, &(&1 in exempt_handlers))
  end

  defp admin_operator_scope?(%URI{} = caller) do
    Process.get(@admin_operator_scope_key) == Ezagent.URI.stable_key(caller)
  end

  defp canonical_admin?(%URI{} = caller) do
    Ezagent.URI.stable_key(caller) ==
      Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin))
  end
end
