defmodule Ezagent.Cap.Verifier do
  @moduledoc """
  Single framework verifier that dominates every Kind handler invocation.

  A cap-gated dispatch is accepted only when a capability is signed by the
  current target Kind authority and binds the concrete target, action, and
  authenticated presenter. Unsigned, malformed, tampered, retargeted, or
  wrong-key artifacts fail loudly.

  The fixed non-cap allowlist is an interim structural split. Every entry has
  its own in-handler predicate; Behavior-authored exemption flags are not
  consulted here.

  This boundary implements the reviewed-code (Path A) threat model. Malicious
  code already executing in the BEAM is explicitly out of scope.
  """

  alias Ezagent.{Cap, Capability}
  alias Ezagent.Cap.Authority

  @non_cap_actions %{
    Ezagent.ActionSet.Identity => MapSet.new([:cascade_notify_managers]),
    Ezagent.ActionSet.IdentityAdmin =>
      MapSet.new([:absorb_cap, :persist_caps, :store_cap, :remove_cap]),
    Ezagent.ActionSet.Agent.Receive => MapSet.new([:receive]),
    Ezagent.ActionSet.User.Receive => MapSet.new([:receive]),
    Ezagent.ActionSet.SocialwarePublisherRead => MapSet.new([:snapshot, :history]),
    Ezagent.ActionSet.Session =>
      MapSet.new([
        :approve_admission,
        :deny_admission,
        :withdraw_admission,
        :composition_consent
      ])
  }

  @type result :: {:ok, Capability.t() | nil} | {:error, term()}

  @doc false
  @spec authorize(module(), module(), atom(), URI.t(), map()) :: result()
  def authorize(kind_module, behavior_module, action, %URI{} = target, ctx) do
    if non_cap_action?(behavior_module, action) do
      emit(:non_cap, kind_module, behavior_module, action, target, ctx)
      {:ok, nil}
    else
      verify_cap(kind_module, behavior_module, action, target, ctx)
    end
  end

  @doc false
  @spec non_cap_action?(module(), atom()) :: boolean()
  def non_cap_action?(behavior_module, action) do
    @non_cap_actions
    |> Map.get(behavior_module, MapSet.new())
    |> MapSet.member?(action)
  end

  defp verify_cap(
         kind_module,
         behavior_module,
         action,
         target,
         %{caller: %URI{} = presenter} = ctx
       ) do
    needed = %{
      kind: kind_module.type_name(),
      behavior: behavior_module,
      action: action,
      instance: Ezagent.URI.instance(target),
      workspace_uri: Capability.workspace_of(target)
    }

    candidates = candidate_caps(ctx, presenter, target)

    case Enum.find(candidates, &valid_for?(&1, needed, presenter)) do
      %Capability{} = cap ->
        emit(:accepted, kind_module, behavior_module, action, target, ctx)
        {:ok, cap}

      nil ->
        reason = if Enum.empty?(candidates), do: :missing_cap, else: :invalid_cap_signature
        emit(:rejected, kind_module, behavior_module, action, target, ctx, reason)
        {:error, reason}
    end
  end

  defp verify_cap(kind_module, behavior_module, action, target, ctx) do
    emit(:rejected, kind_module, behavior_module, action, target, ctx, :presenter_required)
    {:error, :presenter_required}
  end

  defp candidate_caps(ctx, presenter, target) do
    inline = Map.get(ctx, :caps, MapSet.new()) || MapSet.new()

    held =
      if same_instance?(presenter, target) do
        MapSet.new()
      else
        try do
          {caps, _context} = Cap.authorization_context({:held_by, presenter})
          caps
        rescue
          _ -> MapSet.new()
        catch
          _, _ -> MapSet.new()
        end
      end

    inline
    |> Enum.concat(held)
    |> Enum.uniq()
  end

  defp valid_for?(%Capability{} = cap, needed, presenter) do
    Capability.matches?(cap, needed) and Authority.verify_current(cap, presenter)
  rescue
    _ -> false
  end

  defp valid_for?(_cap, _needed, _presenter), do: false

  defp same_instance?(presenter, target),
    do: Ezagent.URI.stable_key(presenter) == Ezagent.URI.stable_key(Ezagent.URI.instance(target))

  defp emit(outcome, kind, behavior, action, target, ctx, reason \\ nil) do
    :telemetry.execute(
      [:ezagent, :cap, :verify, outcome],
      %{count: 1},
      %{
        kind_module: kind,
        behavior_module: behavior,
        action: action,
        target: target,
        presenter: Map.get(ctx, :caller),
        reason: reason
      }
    )
  end
end
