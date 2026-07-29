defmodule Ezagent.ActionSet.SelfLicense do
  @moduledoc """
  #189 PR-3 — minimal, NON-DISPATCHABLE self-license carrier.

  Gives a principal that carries no `Ezagent.ActionSet.Identity` (the Session) a
  DURABLE, URI-tied self-license WITHOUT the Identity behavior's cap surface.
  Declares NO actions, so it registers NO CapabilityRegistry subject (handoff §6:
  "the self-license carrier must not be an ordinary cap-only Behavior — registers
  a CapabilityRegistry subject even when non-dispatchable"). It owns the
  `:identity` slice (`%{caps: MapSet.t()}` — the exact shape the identity-caps
  store, the `Kind.read_durable(:identity)` projection, and `EntityCaps` already
  read), minting the self-license ONCE at genuine creation (`:created`).

  ## Restart = re-read, never re-mint

  The Session is a DURABLE Kind (`{:snapshot, :on_change}`): on restart it
  re-loads this persisted `:identity` slice (with its license) from the snapshot,
  and the store mirrors it via the snapshot dual-write — so the license is re-read
  on both the store-authoritative cold/self path AND the live-slice read. `create/1`
  is not called on `:existed` (the snapshot is loaded + `activate/2` runs), so the
  license is never re-minted; a revoked / generation-bumped principal is caught by
  `EntityCaps.verified/2` gen-gating on every read.

  ## kind axis

  Derived from the CURRENT Kind authority (`Ezagent.Cap.Authority.current_kind_type/0`,
  e.g. `:session`), NOT `Ezagent.URI.type/1` — for a Session `URI.type/1` is the
  TEMPLATE axis, and `String.to_existing_atom/1` on an arbitrary template name would
  crash (the exact hazard the handoff/brief names). The principal gate
  (`EntityCaps.verified/2`) checks only `action == :self_license` plus a
  current-generation signature (a fresh-read generation check), so the `kind` /
  `behavior` axes carry no authority and are free to be the carrier's own.
  Fail-loud: if no authority is in scope, the mint fails and init stops (a principal
  that cannot establish a durable identity must not silently boot license-less).
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :identity

  alias Ezagent.Capability

  @impl Ezagent.Lifecycle
  def create(%{create_freshness: :created, uri: %URI{} = uri}) do
    with {:ok, kind_type} <- Ezagent.Cap.Authority.current_kind_type(),
         requested <-
           Capability.cap(kind_type, __MODULE__, :self_license, uri, Ezagent.URI.workspace_of(uri)),
         intent <- Ezagent.Cap.Grant.freeze(uri, uri, uri, requested),
         {:ok, license} <- Ezagent.Cap.Authority.issue_self_license_current(intent) do
      {:ok, %{caps: MapSet.new([license])}}
    end
  end

  # Not a genuine creation (`:existed` / no freshness): never mint. For a durable
  # Kind this path is not even reached (the snapshot slice is loaded instead of
  # `create/1`); the empty default is the safe fallback.
  def create(_args), do: {:ok, %{caps: MapSet.new()}}

  @doc "The entity OWNS its own `:identity` slice (mirrors `Ezagent.ActionSet.Identity`)."
  def data_owner(%URI{} = uri), do: uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
