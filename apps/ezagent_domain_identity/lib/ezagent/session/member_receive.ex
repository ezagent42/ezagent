defmodule Ezagent.Session.MemberReceive do
  @moduledoc """
  The SHARED, live, fail-closed RECEIVE authorization predicate (membership-cap
  unification A2.1 / spec R1.1 + R1.2 + R2.3).

  This is the SINGLE source of truth for "may this recipient receive a fan-out
  message from source session `S`?" — the receive twin of
  `Ezagent.Session.Membership.authorize/2` (the socialware READ predicate). Both
  receive entry points (`Ezagent.ActionSet.User.Receive` and
  `Ezagent.ActionSet.Agent.Receive`) route through THIS ONE predicate so a
  security boundary is never copy-pasted (no drift on a re-check that decides who
  may receive a conversation).

  ## The roster ⟂ authorization split (R1.1)

  Delivery fan-out targets the session's `:members` ROSTER (a
  staleness-tolerant delivery target), but it presents **NO** receive cap in
  `ctx.caps` — the ephemeral `member_receive_caps/1` bearer token is DELETED
  (A2.2). Receive AUTHORIZATION is instead the recipient's **actually-held**
  member-cap `cap(:session, Session, :receive, S)`, checked HERE in-handler
  against the recipient's OWN `:identity` slice. A revoked member no longer holds
  the cap ⇒ **denied immediately, before any reconcile, with zero bearer
  window** (the §14.5 step-5 defense-in-depth guarantee).

  ## Where this lives (dep-graph placement)

  The two receive sites live in DIFFERENT domain apps —
  `Ezagent.ActionSet.User.Receive` in `ezagent_domain_session`,
  `Ezagent.ActionSet.Agent.Receive` in `ezagent_domain_agent` — and the agent
  domain deliberately does NOT depend on the session domain (the #53 im→session→agent
  acyclic split). The ONLY domain BOTH receive sites depend on (besides core) is
  `ezagent_domain_identity`, and this predicate's whole job is reading the
  recipient's OWN `:identity` caps — so it lives here. To keep this app free of a
  session-domain compile edge (`undeclared_umbrella_dep_test`), the member-cap is
  matched by its stable identifying FIELDS (`kind: :session`, `action: :receive`,
  concrete session instance) rather than pinning the concrete
  `Ezagent.ActionSet.Session` behavior module: the at-join grant is the SOLE
  minter of any `{kind: :session, action: :receive}` cap, so matching those
  fields + the instance uniquely identifies the member-cap over S — and it is
  strictly TIGHTER than the deleted `cap(:any, :any, :receive, instance: recipient)`
  bearer it replaces.

  ## Shape

  `authorize/1` takes the dispatch `ctx` and returns `:ok` ONLY when the
  recipient HOLDS a real-entity-granted member-cap over `ctx.caller` (the source
  session S) — else `{:error, :unauthorized}`. It reads the recipient's own held
  caps from the **pre-loaded** `ctx[:siblings][:identity]` slice (declared via
  `reads_siblings([:identity])` at each receive site), so there is:

    * NO `GenServer.call` / no self-slice deadlock (the `runtime.ex:393-407`
      hazard is avoided by construction — the sibling is already loaded);
    * NO per-message cross-process read (the sibling is loaded once for the
      dispatch).

  ## Provenance filter (K4)

  A held cap counts only if it traces to a REAL entity
  (`Ezagent.Capability.granted_by_entity?/1`) — a `system://`-granted cap is
  filtered out BEFORE the field match, byte-for-byte the runtime step-5.5
  `authorizes?/2` discipline (`runtime.ex:555-566`).

  ## `ctx.caller` is always a session (guarded invariant, R1.2)

  The ONLY `:receive` dispatch in `apps/` is the session fan-out
  (`Delivery.dispatch_receive_call/3`), which always sets `ctx.caller =
  session_uri`. `receive_authz_parity_test.exs` guards that no other `:receive`
  dispatch site is introduced, so this predicate may safely identify the member
  cap from `ctx.caller`.
  """

  @doc """
  Authorize the recipient to receive a fan-out message from `ctx.caller` (the
  source session). Fail-closed: `{:error, :unauthorized}` on any unmet
  condition.
  """
  @spec authorize(map()) :: :ok | {:error, :unauthorized}
  def authorize(ctx) when is_map(ctx) do
    with %URI{} = session <- Map.get(ctx, :caller),
         %URI{} = holder <- Map.get(ctx, :self_uri),
         true <- holds_member_cap_over?(holder, sibling_identity_caps(ctx), session) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(_), do: {:error, :unauthorized}

  @doc """
  True iff `held` (a list of `%Capability{}`) contains a real-entity-granted
  member-cap over `session`: `kind: :session`, `action: :receive`, concrete
  instance == `session`. The at-join grant is the SOLE minter of any
  `{:session, :receive}` cap, so these fields + the instance uniquely identify
  the member-cap (behavior is intentionally not pinned — see moduledoc).

  Public so the socialware READ predicate (`Ezagent.Session.Membership.authorize/3`)
  shares this EXACT held-cap check with the receive predicate — one security
  boundary, no copy-paste drift (R1.1: coherent "held-cap, not projection" story
  across delivery AND read).
  """
  @spec holds_member_cap_over?(URI.t(), [Ezagent.Capability.t()] | term(), URI.t()) :: boolean()
  def holds_member_cap_over?(%URI{} = holder, held, %URI{} = session) when is_list(held) do
    session_key = instance_key(session)
    workspace_uri = Ezagent.Capability.workspace_of(session)

    Enum.any?(held, fn
      %Ezagent.Capability{kind: :session} = cap ->
        Ezagent.Capability.granted_by_entity?(cap) and
          Ezagent.Capability.action_of(cap) == :receive and
          instance_key(cap.instance) == session_key and
          match?(
            {:ok, %Ezagent.Capability{}},
            Ezagent.Cap.authorize(holder, [cap], %{
              kind: :session,
              behavior: cap.behavior,
              action: :receive,
              instance: session,
              workspace_uri: workspace_uri
            })
          )

      _ ->
        false
    end)
  end

  def holds_member_cap_over?(_holder, _held, _session), do: false

  # The comparable key for a cap instance. A concrete `%URI{}` instance (the
  # member-cap's shape) normalizes to its bare-instance `%URI{}` (query/fragment
  # dropped) and is compared by STRUCT equality — the same opaque-instance
  # comparison `Ezagent.ActionSet.Agent.Receive.same_instance?/2` uses, never a
  # stringified key (unify-uri-query: a URI is an opaque id, not parsed/serialized
  # for keying). A scope-tuple / `:any` instance (a broad admin cap, NOT the
  # membership signal) yields a sentinel atom that never equals a `%URI{}` key.
  defp instance_key(%URI{} = uri), do: Ezagent.URI.instance(uri)
  defp instance_key(_), do: :__non_uri_instance__

  # Read the recipient's OWN held caps from the PRE-LOADED `:identity` sibling
  # slice (`reads_siblings([:identity])`) — no cross-process read, no deadlock.
  # Normalizes the two-container slice view (mirrors `MemberCap.member_snapshot_caps/1`)
  # then coerces the `:caps` container (list / MapSet / scalar) to a plain list.
  @spec sibling_identity_caps(map()) :: [Ezagent.Capability.t()]
  defp sibling_identity_caps(ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:identity, %{})
    |> Ezagent.Kind.normalize_slice_view()
    |> Map.get(:caps)
    |> caps_to_list()
  end

  defp caps_to_list(caps) do
    cond do
      is_list(caps) -> caps
      is_struct(caps, MapSet) -> MapSet.to_list(caps)
      is_nil(caps) -> []
      true -> List.wrap(caps)
    end
  end
end
