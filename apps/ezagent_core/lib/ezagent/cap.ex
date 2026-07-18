defmodule Ezagent.Cap do
  @moduledoc """
  Capability artifact seam.

  The artifact remains an `Ezagent.Capability` struct. `issue/3` stamps
  accountable entity provenance and its receiving grantee, then asks the
  concrete target Kind authority to sign the immutable grant intent.

  `issue/3` loads the issuer's held authority through the dependency-inverted
  durable loader and runs the complete grantor-authorization algorithm before
  returning a signed artifact. Downstream handlers only store issued artifacts;
  authorization happens only in the target Kind's central verifier.
  """

  alias Ezagent.Capability

  @type artifact :: Capability.t()
  @type authorization ::
          {:held_by, URI.t()}
          | {:admin, URI.t()}

  @doc """
  Authorize the issuer, stamp issuer provenance, and produce an artifact.
  """
  @spec issue(authorization(), URI.t(), Capability.t()) ::
          {:ok, artifact()} | {:error, term()}
  def issue(authorization, %URI{} = grantee_uri, %Capability{} = cap) do
    {caps, context} = authorization_context(authorization)

    with {:ok, target} <- Ezagent.Cap.Authority.target_uri(cap),
         :ok <- ensure_issue_target(target),
         {:ok, authority_caps} <- authority_caps(authorization, target, caps) do
      grant_target = Ezagent.URI.with_action(target, :cap, :grant)

      ctx = %{
        caller: Map.fetch!(context, :caller),
        caps: authority_caps,
        reply: {:caller_inbox, self()}
      }

      if Ezagent.Cap.Authority.current_target?(target) do
        with {:ok, kind_type} <- Ezagent.Cap.Authority.current_kind_type() do
          Ezagent.Cap.Grant.authorize_and_issue_current(
            kind_type,
            grant_target,
            :trusted_internal,
            ctx,
            grantee_uri,
            cap
          )
        end
      else
        dispatch_grant(target, %Ezagent.Invocation{
          target: grant_target,
          mode: :call,
          args: %{grantee: grantee_uri, cap: cap},
          ctx: ctx,
          origin: :trusted_internal
        })
      end
    end
  end

  @doc """
  Ask the concrete target Kind to mint the capability required for `target`.

  This is the reviewed-code convenience seam for framework/operator paths that
  previously injected an ambient wildcard. It derives the immutable capability
  shape from the live target's registered Kind/action pair, then delegates to
  `issue/3`; signing still happens only inside the target's `K.grant` path.

  When invoked from the target Kind process, it reuses the live authority
  compartment and still runs the same grant verifier + frozen-intent issuance
  function, avoiding a synchronous self-call without creating a second signer.
  """
  @spec issue_for_action(authorization(), URI.t(), URI.t()) ::
          {:ok, artifact()} | {:error, term()}
  def issue_for_action(authorization, %URI{} = grantee_uri, %URI{} = target) do
    instance = Ezagent.URI.instance(target)

    with {:ok, {_behavior, action}} <- Ezagent.URI.behavior_action(target),
         {:ok, pid} <- Ezagent.LocalRuntime.ensure_started(instance),
         {:ok, {kind_module, behavior_module}} <- action_context(pid, instance, action),
         needed <-
           Ezagent.Cap.Verifier.required_cap(kind_module, behavior_module, action, target),
         requested <-
           Capability.cap(
             needed.kind,
             needed.behavior,
             needed.action,
             needed.instance,
             needed.workspace_uri
           ) do
      issue(authorization, grantee_uri, requested)
    end
  end

  defp action_context(pid, instance, action) when pid == self() do
    with true <- Ezagent.Cap.Authority.current_target?(instance),
         {:ok, kind_type} <- Ezagent.Cap.Authority.current_kind_type(),
         {:ok, {kind_module, behavior_module}} <- self_target_subject(kind_type, action) do
      {:ok, {kind_module, behavior_module}}
    else
      false -> {:error, :self_target_without_authority}
      :error -> {:error, {:unknown_action, action}}
      {:error, _reason} = error -> error
    end
  end

  defp action_context(pid, _instance, action) do
    with {:ok, %{kind: kind_module, state: slice_state}} <-
           GenServer.call(pid, :ezagent_runtime_view),
         {:ok, behavior_module} <-
           Ezagent.Kind.BehaviorSet.resolve_action(kind_module, action, slice_state) do
      {:ok, {kind_module, behavior_module}}
    end
  end

  # Resolve a SELF-target action's `{kind_module, behavior_module}`. INSTANCE-FIRST:
  # when a live in-process runtime view is in scope (we are inside THIS instance's
  # own dispatch — `Ezagent.Kind.Runtime.do_handle_dispatch/4` installs it), resolve
  # against the instance's OWN effective behavior set via
  # `Ezagent.Kind.BehaviorSet.resolve_action/3` — the SAME authoritative truth the
  # cross-process branch (`action_context/3` with `pid != self()`) reads from the
  # live `slice_state` — WITHOUT a self `GenServer.call` (which would deadlock the
  # Kind process). This lets a flavor-only, per-instance action (e.g.
  # `:hello_sync_result`, mounted via a role recipe but NOT globally registered)
  # resolve exactly like a globally-registered sibling (py's `:py_sync_result`).
  #
  # Falls back to the GLOBAL `BehaviorRegistry` (`registered_subject/2`, the prior
  # self-target resolver) when there is no runtime view (framework/genesis paths
  # outside a dispatch) OR the instance set does not resolve the action. That
  # fallback is byte-identical to the previous behavior, so nothing that resolves
  # today can regress. No authorization hole: an action the instance does NOT host
  # still resolves to nothing (`:error` → `{:unknown_action, _}`); the
  # `current_target?/1` authority gate in the caller still holds; and the resolved
  # pair feeds the UNCHANGED `Ezagent.Cap.Verifier`.
  defp self_target_subject(kind_type, action) do
    case Ezagent.Cap.RuntimeView.current() do
      {:ok, {kind_module, slice_state}} ->
        case Ezagent.Kind.BehaviorSet.resolve_action(kind_module, action, slice_state) do
          {:ok, behavior_module} -> {:ok, {kind_module, behavior_module}}
          {:error, {:unknown_action, _}} -> registered_subject(kind_type, action)
        end

      :error ->
        registered_subject(kind_type, action)
    end
  end

  defp registered_subject(kind_type, action) do
    Ezagent.BehaviorRegistry.list_all()
    |> Enum.find_value(:error, fn
      {{kind_module, ^action}, behavior_module} ->
        if function_exported?(kind_module, :type_name, 0) and
             kind_module.type_name() == kind_type,
           do: {:ok, {kind_module, behavior_module}},
           else: false

      _entry ->
        false
    end)
  end

  defp ensure_issue_target(%URI{} = target) do
    if Ezagent.Cap.Authority.current_target?(target) do
      :ok
    else
      case Ezagent.LocalRuntime.ensure_started(Ezagent.URI.instance(target)) do
        {:ok, _pid} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  # Authority genesis precedes application readiness. Framework materializers
  # may therefore need K.grant while a transport-backed target intentionally
  # remains not-ready. The same positively stamped Invocation still enters the
  # Kind.Server verifier; this only avoids the public readiness wait and does
  # not introduce a Behavior hook or alternate signer.
  defp dispatch_grant(%URI{} = target, %Ezagent.Invocation{} = invocation) do
    instance = Ezagent.URI.instance(target)

    case Ezagent.ReadyGate.status(instance) do
      :not_ready ->
        with {:ok, pid} <- Ezagent.KindRegistry.lookup(instance) do
          GenServer.call(
            pid,
            {:ezagent_dispatch, invocation},
            Ezagent.Invocation.activate_budget_ms()
          )
        end

      _ ->
        Ezagent.Invocation.dispatch(invocation)
    end
  end

  @doc """
  The single authorization chokepoint (unified-revocation Phase F-1).

  Takes an explicit authenticated `holder`, the presented `candidate_caps`,
  and the `needed` cap shape. The principal gate is resolved from the
  holder's independently-loaded caps (never from `candidate_caps`), then each
  candidate is verified against its target's CURRENT active authority row
  (`Ezagent.Cap.Authority.verify_against_current/3`). See
  `Ezagent.Cap.Authorize` for the full contract.
  """
  @spec authorize(URI.t(), Enumerable.t(), map()) ::
          {:ok, Capability.t()} | Ezagent.Cap.Authorize.denial()
  defdelegate authorize(holder_uri, candidate_caps, needed), to: Ezagent.Cap.Authorize

  @doc """
  Return born-signed, receiver-bound artifacts that may enter a cap store.

  This is deliberately a structural storage filter, not an authorization
  decision. Only the target Kind's central verifier performs cryptographic
  verification, using its private live key immediately before handler entry.
  Unsigned legacy artifacts and artifacts bound to another receiver are
  discarded; malformed or tampered signed artifacts may remain opaque at rest
  but can never authorize an action because the central verifier rejects them.
  """
  @spec verified_set(term(), term()) :: MapSet.t(Capability.t())
  def verified_set(caps, %URI{} = receiver_uri) when is_list(caps) or is_struct(caps, MapSet) do
    Enum.reduce(caps, MapSet.new(), fn cap, verified ->
      if storable_for?(cap, receiver_uri), do: MapSet.put(verified, cap), else: verified
    end)
  end

  def verified_set(_caps, _receiver_uri), do: MapSet.new()

  @doc """
  Validate a signed artifact against the current target authority and receiver.

  This validates an artifact only; it does not authorize or invoke an action.
  """
  @spec validate_for_current_target(artifact(), URI.t()) ::
          :ok | {:error, :invalid_cap_signature | :wrong_grantee}
  def validate_for_current_target(
        %Capability{grantee_uri: %URI{} = grantee} = artifact,
        %URI{} = receiver
      ) do
    if Ezagent.URI.stable_key(grantee) == Ezagent.URI.stable_key(receiver) do
      if Ezagent.Cap.Authority.verify_current(artifact, receiver),
        do: :ok,
        else: {:error, :invalid_cap_signature}
    else
      {:error, :wrong_grantee}
    end
  end

  def validate_for_current_target(%Capability{}, %URI{}), do: {:error, :wrong_grantee}

  @doc false
  @spec storable_for?(term(), URI.t()) :: boolean()
  def storable_for?(
        %Capability{
          signature: signature,
          key_id: key_id,
          grantee_uri: %URI{} = grantee,
          instance: %URI{}
        },
        %URI{} = receiver
      )
      when is_binary(signature) and byte_size(signature) > 0 and is_binary(key_id) and
             byte_size(key_id) > 0 do
    Ezagent.URI.stable_key(grantee) == Ezagent.URI.stable_key(receiver)
  end

  def storable_for?(_artifact, _receiver), do: false

  @doc """
  Ask the artifact's target Kind whether it is signed by that Kind's current
  authority and bound to `presenter`.

  This is the target-aware validity check for reconciliation/idempotency. A
  storage boundary cannot perform this check because the verification key is
  deliberately confined to the target Kind process.
  """
  @spec valid_for_target?(artifact(), URI.t()) :: boolean()
  def valid_for_target?(%Capability{} = artifact, %URI{} = presenter) do
    with {:ok, target} <- Ezagent.Cap.Authority.target_uri(artifact),
         :ok <- ensure_issue_target(target) do
      if Ezagent.Cap.Authority.current_target?(target) do
        Ezagent.Cap.Verifier.valid_artifact?(artifact, presenter)
      else
        case Ezagent.KindRegistry.lookup(Ezagent.URI.instance(target)) do
          {:ok, pid} ->
            GenServer.call(
              pid,
              {:ezagent_verify_cap_artifact, artifact, presenter},
              Ezagent.Invocation.activate_budget_ms()
            )

          :error ->
            false
        end
      end
    else
      _ -> false
    end
  catch
    :exit, _reason -> false
  end

  def valid_for_target?(_artifact, _presenter), do: false

  @doc false
  @spec prepare_provenance(authorization(), Capability.t()) ::
          {:ok, artifact()} | {:error, term()}
  def prepare_provenance(authorization, %Capability{} = cap) do
    granted_by = issuer(authorization)
    artifact = %{cap | granted_by: granted_by, granted_at: DateTime.utc_now()}

    if match?(%URI{scheme: "entity"}, granted_by) do
      {:ok, artifact}
    else
      {:error, {:granter_not_entity, granted_by}}
    end
  end

  @doc false
  @spec prepare_provenance(authorization(), URI.t(), Capability.t()) ::
          {:ok, artifact()} | {:error, term()}
  def prepare_provenance(authorization, %URI{} = grantee_uri, %Capability{} = cap) do
    with {:ok, artifact} <- prepare_provenance(authorization, cap) do
      {:ok, %{artifact | grantee_uri: grantee_uri}}
    end
  end

  defp issuer({:held_by, %URI{} = actor}), do: actor
  defp issuer({:admin, %URI{} = admin}), do: admin

  @doc false
  @spec authorization_context(authorization()) :: {MapSet.t(Capability.t()), map()}
  def authorization_context({:held_by, %URI{} = actor}) do
    {load_held_caps(actor), %{caller: actor}}
  end

  def authorization_context({:admin, %URI{} = admin}) do
    canonical_admin = Ezagent.URI.user(:system, :admin)

    caps =
      if Ezagent.URI.stable_key(admin) == Ezagent.URI.stable_key(canonical_admin) do
        case Ezagent.Cap.Authority.anchor(canonical_admin) do
          {:ok, anchor} -> MapSet.new([anchor])
          {:error, _} -> MapSet.new()
        end
      else
        MapSet.new()
      end

    {caps, %{caller: admin}}
  end

  defp load_held_caps(actor) do
    loader =
      :ezagent_core
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.fetch!(:authority_loader)

    loader.read_held_caps(actor)
  end

  defp authority_caps({:admin, %URI{} = admin}, target, _caps) do
    if Ezagent.URI.stable_key(admin) ==
         Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin)) do
      case Ezagent.Cap.Authority.anchor(target) do
        {:ok, anchor} -> {:ok, MapSet.new([anchor])}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :canonical_admin_required}
    end
  end

  defp authority_caps(_authorization, _target, caps), do: {:ok, caps}
end
