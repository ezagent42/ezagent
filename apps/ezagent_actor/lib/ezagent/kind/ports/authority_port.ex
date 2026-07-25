defmodule Ezagent.Kind.Ports.AuthorityPort do
  @moduledoc """
  §3.4 AuthorityPort — the actor framework's signing-authority surface,
  resolved via `Application.fetch_env!(:ezagent_actor, :authority)`.

  Owner (core spine): `Ezagent.Cap.Authority`; the core adapter
  (`Ezagent.Kind.Adapters.AuthorityAdapter`) also fronts `Ezagent.Cap` /
  `Ezagent.Cap.Verifier` / `Ezagent.Cap.RuntimeView` for the artifact/view
  rows. The authority crosses as an OPAQUE token (`term()`) — the framework
  never reads its fields (`generation/1` is the single accessor). Artifacts
  cross as OPAQUE `term()`; the ADAPTER validates the representation
  (`validate_artifact/2` rejects a non-Capability input as
  `{:error, :invalid_artifact}`). Moves with the framework to
  `apps/ezagent_actor`.
  """

  @doc "Open the per-Kind signing authority; returns an OPAQUE token."
  @callback open(uri :: term(), kind_type :: atom(), freshness :: term()) ::
              {:ok, token :: term()} | {:error, term()}

  @doc "Run `fun` inside the token's sealed custody compartment (process-local)."
  @callback with_authority(token :: term(), fun :: (-> result)) :: result when result: var

  @doc "Target-wide generation bump (unified revocation); returns the new OPAQUE token."
  @callback regenesis(uri :: term(), kind_type :: atom(), ctx :: map()) ::
              {:ok, token :: term()} | {:error, term()}

  @doc "Retire the active authority row for `uri` (destroy/teardown path)."
  @callback retire(uri :: term()) :: :ok

  @doc """
  Validate a presented artifact for the current target. `artifact` is
  OPAQUE (`term()`); the ADAPTER validates the representation and rejects a
  non-Capability input as `{:error, :invalid_artifact}`.
  """
  @callback validate_artifact(artifact :: term(), receiver :: term()) ::
              :ok | {:error, term()}

  @doc """
  Boolean artifact verification for a presenter. OPAQUE `artifact`; the
  ADAPTER's representation check answers `false` for a non-Capability input
  (the boolean-path rejection).
  """
  @callback verify_artifact(artifact :: term(), presenter :: term()) :: boolean()

  @doc "Current generation of an OPAQUE authority token."
  @callback generation(token :: term()) :: non_neg_integer()

  @doc "Filter a persisted cap set down to the entries verified for `receiver_uri`."
  @callback verified_set(caps :: term(), receiver_uri :: term()) :: term()

  @doc """
  Install the in-process runtime view for SELF-target issuance during a
  dispatch. KEPT AS-IS (full `state` passed — the self-issue hatch; a later
  chunk narrows/deletes it — faithful port, do NOT narrow here).
  """
  @callback with_runtime_view(kind_module :: module(), state :: term(), fun :: (-> result)) ::
              result
            when result: var
end
