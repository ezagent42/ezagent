defmodule Ezagent.Kind.CreatedWitness do
  @moduledoc """
  #201-cred (codex r2 NEW-HIGH-3) — the STRUCTURAL created-winner witness.

  An opaque token proving that a spawn attempt WON the atomic
  `DynamicSupervisor.start_child` race AND was the genuine logical create
  (`:started ∧ created?`). It is minted ONLY by `Ezagent.Kind.spawn_receipt/3`
  (the sole framework spawn chokepoint), returned inside the `:started ∧
  created?` receipt, and threaded by the plugin created-winner arm into
  `Ezagent.Credential.GrantMint.mint/3` (directly, or via the cascade map that
  `Ezagent.Credential.HomeRuntime` reads). `GrantMint` REFUSES to mint a durable
  credential grant without a witness that binds the exact agent being minted for.

  This makes grant-minting structurally confined to the created-winner arm: no
  exported mint path — `Ezagent.Credential.Resolver.authorize_and_mint_grant!/2`,
  the curl slice materializer, a future flavor plugin, a `curl`-driven RPC — can
  insert a grant for an agent URI it did not prove it just created, because it
  has no witness to supply and the argument is mandatory.

  Threat model (per `Ezagent.Cap.Authority`): this defends the reviewed-code
  (Path A) boundary. A hand-written `%CreatedWitness{}` literal is a review /
  dialyzer opacity red flag; code already executing maliciously inside the BEAM
  is explicitly out of scope. The witness is a transient spawn-time value — it is
  never persisted (respawn cascades are sanitized of the whole cascade map) and
  never crosses a process/serialization boundary on the grant path.
  """

  @enforce_keys [:agent_uri]
  defstruct [:agent_uri]

  @opaque t :: %__MODULE__{agent_uri: URI.t()}

  # TODO(path-b-hardening): #201-cred r3 HIGH-3 — this witness is FORGEABLE and
  # REPLAYABLE (Path-B / same-BEAM structural hardening, officially deferred):
  #   * `new/1` is public and the struct is literally constructible (`@opaque` /
  #     `@doc false` are review signals, not enforcement), so reviewed code (or a
  #     hand-written `%CreatedWitness{}`) can fabricate a create-winner proof;
  #   * a genuine witness has NO nonce / pid-incarnation binding / expiry /
  #     one-shot consumption, so a real receipt is replayable indefinitely.
  # Full close (deferred; cc to file a tracking issue): bind the witness to the
  # STARTED pid + a one-shot nonce recorded in a framework ETS table, and have
  # `GrantMint.mint/3` verify it DIRECTLY against the Kind's durable `:started ∧
  # created?` state (`Ezagent.Kind.create_freshness(uri, pid) == :created`) AND
  # atomically consume the nonce (`:ets.take`) so a forged/replayed witness
  # fails. Per the same-BEAM threat model (`Ezagent.Cap.Authority`), code already
  # executing maliciously inside the BEAM is out of scope; this hole is that
  # Path-B boundary.
  @doc false
  # FRAMEWORK-ONLY constructor. ONLY `Ezagent.Kind.spawn_receipt/3` may call
  # this — it is the single place that holds proof of a genuine `:started ∧
  # created?` outcome. Called anywhere else it would fabricate a create-winner
  # proof (a review red flag), so keep it `@doc false` and grep-guarded.
  @spec new(URI.t()) :: t()
  def new(%URI{} = agent_uri), do: %__MODULE__{agent_uri: Ezagent.URI.instance(agent_uri)}

  @doc """
  True iff `witness` is a genuine created-winner witness bound to `agent_uri`.

  The binding is checked on the INSTANCE stable key, so an action-qualified or
  sliced URI on either side still matches the underlying agent. Anything that is
  not a `%CreatedWitness{}` (notably `nil` — a caller that never went through the
  spawn winner arm) returns `false`, so `GrantMint.mint/3` fails closed.
  """
  @spec authorizes?(t() | term(), URI.t()) :: boolean()
  def authorizes?(%__MODULE__{agent_uri: %URI{} = witness_uri}, %URI{} = agent_uri) do
    Ezagent.URI.stable_key(Ezagent.URI.instance(witness_uri)) ==
      Ezagent.URI.stable_key(Ezagent.URI.instance(agent_uri))
  end

  def authorizes?(_witness, _agent_uri), do: false
end
