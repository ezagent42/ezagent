defmodule Ezagent.Kind.Ports.AuthzPort do
  @moduledoc """
  §3.4 AuthzPort — the actor framework's authorization surface, resolved
  via `Application.fetch_env!(:ezagent_actor, :authz)`.

  Owner (core spine): `Ezagent.Cap.Verifier` + the RELOCATED holds-cap spine
  (`Ezagent.Cap.HoldsCap` — the `holds_cap?/default_holds_cap?` block moved
  OUT of `Ezagent.Kind`; dispatch reaches it via this port). Caps cross as
  OPAQUE `term()` — the framework never pattern-matches the struct; the
  core adapter (`Ezagent.Kind.Adapters.AuthzAdapter`) validates the
  representation where a cap is minted (`authorize_and_issue_grant/6`
  rejects a non-Capability input as `{:error, :invalid_artifact}`). Moves
  with the framework to `apps/ezagent_actor`.
  """

  @doc """
  Dispatch step 5.5 authorization: verify the holder's presented caps
  against the action's required cap. Returns the exact target-signed cap
  (`nil` for a closed non-cap action) or the denial.
  """
  @callback authorize_dispatch(
              kind_module :: module(),
              behavior_module :: module(),
              action :: atom(),
              target :: term(),
              holder :: term(),
              ctx :: map()
            ) :: {:ok, term() | nil} | {:error, term()}

  @doc """
  The `{:cap, :grant}` action path: authorize and issue the exact grant
  artifact for `grantee`. `cap` is OPAQUE (`term()`); the ADAPTER validates
  the representation and rejects a non-Capability input as
  `{:error, :invalid_artifact}`.
  """
  @callback authorize_and_issue_grant(
              kind_module :: module(),
              target :: term(),
              origin :: term(),
              ctx :: map(),
              grantee :: term(),
              cap :: term()
            ) :: {:ok, term()} | {:error, term()}

  @doc "Data-owner resolution for a behavior/instance (CapabilityRegistry)."
  @callback data_owner_of(behavior :: module(), instance :: term()) :: term()

  @doc """
  Does the entity at `entity_uri` hold a cap authorizing `needed`? Resolves
  the Kind's optional `holds_cap?/2` override, defaulting to
  `default_holds_cap?/2`.
  """
  @callback holds_cap?(kind_module :: module(), entity_uri :: term(), needed :: term()) ::
              boolean()

  @doc "Default `holds_cap?/2` impl (slice-read + predicate-A match, fail-LOUD on transient)."
  @callback default_holds_cap?(entity_uri :: term(), needed :: term()) :: boolean()
end
