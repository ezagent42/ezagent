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

  alias Ezagent.Capability
  alias Ezagent.Cap.Authority

  @non_cap_actions %{
    Ezagent.ActionSet.Identity => MapSet.new([:cascade_notify_managers]),
    Ezagent.ActionSet.IdentityAdmin =>
      MapSet.new([
        :absorb_cap,
        :persist_caps,
        :store_cap,
        :remove_cap,
        :sync_recipe_binding
      ]),
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

  @doc false
  @spec non_cap_actions() :: %{module() => MapSet.t(atom())}
  def non_cap_actions, do: @non_cap_actions

  defp verify_cap(
         kind_module,
         behavior_module,
         action,
         target,
         %{caller: %URI{} = presenter} = ctx
       ) do
    needed = resolve_required_cap(kind_module, behavior_module, action, target)

    candidates = candidate_caps(ctx)

    verified = Enum.filter(candidates, &verified_artifact?(&1, presenter))

    case Enum.find(verified, &Capability.matches?(&1, needed)) do
      %Capability{} = cap ->
        emit(:accepted, kind_module, behavior_module, action, target, ctx)
        {:ok, cap}

      nil ->
        reason =
          cond do
            Enum.empty?(candidates) -> :missing_cap
            Enum.empty?(verified) -> :invalid_cap_signature
            true -> :missing_cap
          end

        emit(:rejected, kind_module, behavior_module, action, target, ctx, reason)
        {:error, reason}
    end
  end

  defp verify_cap(kind_module, behavior_module, action, target, ctx) do
    emit(:rejected, kind_module, behavior_module, action, target, ctx, :presenter_required)
    {:error, :presenter_required}
  end

  defp candidate_caps(ctx), do: Map.get(ctx, :caps, MapSet.new()) || MapSet.new()

  defp verified_artifact?(%Capability{} = cap, presenter) do
    Authority.verify_current(cap, presenter)
  rescue
    _ -> false
  end

  defp verified_artifact?(_cap, _presenter), do: false

  defp resolve_required_cap(kind_module, behavior_module, action, target) do
    with true <- function_exported?(behavior_module, :required_caps, 0),
         required when is_map(required) <- behavior_module.required_caps(),
         %Capability{} = declared <- Map.get(required, action) do
      %{
        kind: if(declared.kind == :any, do: kind_type(kind_module), else: declared.kind),
        behavior: declared.behavior,
        action: action,
        instance:
          if(declared.instance == :any,
            do: Ezagent.URI.instance(target),
            else: declared.instance
          ),
        workspace_uri:
          if(declared.workspace_uri == :any,
            do: Capability.workspace_of(target),
            else: declared.workspace_uri
          )
      }
    else
      _ ->
        %{
          kind: kind_type(kind_module),
          behavior: behavior_module,
          action: action,
          instance: Ezagent.URI.instance(target),
          workspace_uri: Capability.workspace_of(target)
        }
    end
  rescue
    _ ->
      %{
        kind: kind_type(kind_module),
        behavior: behavior_module,
        action: action,
        instance: Ezagent.URI.instance(target),
        workspace_uri: Capability.workspace_of(target)
      }
  end

  defp kind_type(kind_module) when is_atom(kind_module) do
    if function_exported?(kind_module, :type_name, 0),
      do: kind_module.type_name(),
      else: kind_module
  end

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
