defmodule Ezagent.Identity do
  @moduledoc """
  Facade for reading Identity slice (caps) per principal URI.

  Phase 4-completion Spec 05 §A.2.3: LV mounts call `list_caps_for/1`
  to derive `ctx.caps` from the session cookie's `current_entity_uri`
  (renamed from `current_user_uri` in PR #142 — works for any Entity).

  Capability loading is dependency-inverted through `Ezagent.IdentityCaps.load/1`.
  That facade applies the principal-generation self-license gate before any
  caller can use the returned set as authority.
  """

  @behaviour Ezagent.Cap.AuthorityLoader

  alias Ezagent.{Cmd, Router}

  @doc """
  List the current verified capabilities held by `principal_uri`.

  The result is empty for an unknown principal, an unlicensed pre-G-3 fixture,
  or a principal whose generation has been bumped.
  """
  @spec list_caps_for(URI.t() | String.t()) :: MapSet.t(Ezagent.Capability.t())
  def list_caps_for(uri) do
    uri
    |> parse_uri()
    |> Ezagent.IdentityCaps.load()
    |> MapSet.new()
  end

  @doc """
  Phase 8c PR-F (Allen 2026-05-20) — does `entity_uri` belong to the
  admin principal?

  Used by the avatar dropdown to gate visibility of the "Admin" link
  (which opens the admin drawer at `/admin`). Returns `false` for
  `nil`, malformed URIs, or any non-admin entity.

  ## Current implementation

  Matches the seeded admin URI (`entity://user/system/admin`) exactly. This is
  honest: the route gate (`EzagentWeb.Plugs.RequireEntity`) currently
  only requires a logged-in entity, not admin caps — so /admin is open
  to anyone authenticated. The dropdown gate hides the link for
  non-admins purely for UX clarity, NOT as a security boundary.

  ## TODO Phase 8d

  Replace with a proper `cap:admin` check once the admin sub-pages
  enforce admin caps at the on_mount hook (see `EzagentWeb.LiveAuth`).
  At that point this helper becomes:

      caps = list_caps_for(entity_uri)
      Enum.any?(caps, &Ezagent.Capability.matches?(&1, {:admin, :any, :any}))
  """
  @spec admin?(URI.t() | String.t() | nil) :: boolean()
  def admin?(nil), do: false

  def admin?(entity_uri) do
    case parse_uri_safe(entity_uri) do
      %URI{} = uri ->
        URI.to_string(uri) == URI.to_string(Ezagent.Entity.User.admin_uri())

      :error ->
        false
    end
  end

  defp parse_uri_safe(%URI{} = u), do: u

  defp parse_uri_safe(s) when is_binary(s) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the `:error` atom-shape contract for
    # this private helper (caller pattern-matches on it).
    try do
      Ezagent.URI.new!(s)
    rescue
      ArgumentError -> :error
    end
  end

  defp parse_uri_safe(_), do: :error

  defp parse_uri(%URI{} = u), do: u
  defp parse_uri(s) when is_binary(s), do: Ezagent.URI.new!(s)

  @doc """
  Grant a capability to `entity_uri`. Dispatches `identity.grant_cap`
  on the target Entity Kind using `granter_uri`'s admin caps.

  Accepts either a fully-constructed `Ezagent.Capability` struct OR a
  plain params map. When a map is passed, missing keys are
  defaulted:

  - `workspace_uri` — defaults to the grantee's workspace via
    `Ezagent.URI.entity_workspace_uri/1` when the grantee URI is an
    `entity://` URI. Explicit `:any` requests a cross-workspace
    grant — Phase 9 PR-4 will add the `cross-workspace:dispatch`
    cap check at this point; PR-3 just plumbs the field.

  Returns `:ok` or `{:error, reason}`.

  Phase 9 PR-3 (SPEC v3 §4.3) — workspace dimension threading. The
  facade exists so callers don't have to know the dispatch URI shape
  (`?action=identity.grant_cap`) + admin-cap context.
  """
  @spec grant_cap(URI.t() | String.t(), Ezagent.Capability.t() | map(), URI.t() | String.t()) ::
          :ok | {:error, term()}
  def grant_cap(entity_uri, %Ezagent.Capability{} = cap, granter_uri) do
    target_uri = parse_uri(entity_uri)
    granter = parse_uri(granter_uri)

    # Grant-chokepoint shim (SPEC 2026-06-17 §3.1 / §3.5 site #1).
    # Behavior-preserving: this facade already loaded the granter's
    # REAL held caps into `ctx.caps` (`read_granter_caps/1`) and set
    # `ctx.caller`/`granted_by` to the granter — which is EXACTLY the
    # `{:held_by, actor}` tag's semantics. `Ezagent.Identity.Grant`
    # now owns the envelope construction (the single place a
    # grant/revoke dispatch is built) and derives + validates the
    # entity `granted_by`.
    Ezagent.Identity.Grant.grant_cap(target_uri, cap, {:held_by, granter})
  end

  # Read the granter's current Identity slice caps directly via
  # `Ezagent.Kind.get_slice/2` (added in PR-OWN-2). Skips dispatch
  # (which would itself need caps — chicken-and-egg). Falls back to
  # an EMPTY MapSet if the granter has no live Kind or no Identity
  # slice — that lets the §5.2 / dispatch CapBAC reject cleanly with
  # an authorization error instead of a confusing nil-deref.

  def grant_cap(entity_uri, %{workspace_uri: _} = cap_params, granter_uri) do
    cap = build_cap_from_params(cap_params, granter_uri)
    grant_cap(entity_uri, cap, granter_uri)
  end

  def grant_cap(entity_uri, cap_params, granter_uri) when is_map(cap_params) do
    # Default workspace_uri to grantee's workspace (SPEC v3 §4.3 —
    # intra-workspace grant is the common path). Caller asks for
    # cross-workspace explicitly by passing `workspace_uri: :any`.
    parsed = parse_uri(entity_uri)
    default_ws = Ezagent.URI.entity_workspace_uri(parsed)
    grant_cap(entity_uri, Map.put(cap_params, :workspace_uri, default_ws), granter_uri)
  end

  @doc """
  Hand an already-issued capability artifact to `entity_uri` for self-storage.

  This is the sole producer-side `absorb_cap` envelope. It canonicalizes the
  grantee and dispatches a VM-internal fire-and-forget cast without waiting for
  readiness. `Ezagent.Invocation` persists this operation in the capability
  delivery outbox before attempting the cast; a not-ready grantee therefore
  leaves a durable pending row instead of entering bounded `PendingDelivery`.
  Authorization already completed at `Ezagent.Cap.issue/3`.
  """
  @spec absorb_cap(URI.t() | String.t(), Ezagent.Capability.t()) ::
          :ok | {:error, term()}
  def absorb_cap(entity_uri, %Ezagent.Capability{} = artifact) do
    target = entity_uri |> parse_uri() |> Ezagent.URI.instance()

    cmd = %Cmd{
      target: Ezagent.URI.with_action(target, :identity, :absorb_cap),
      action: :absorb_cap,
      args: %{artifact: artifact},
      ctx: %{
        caller: :vm_internal,
        caps: MapSet.new(),
        mode: :cast,
        reply: :ignore,
        cap_delivery_producer: :identity_absorb
      },
      origin: :trusted_internal
    }

    case Router.dispatch(cmd) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_absorb_result, other}}
    end
  end

  defp build_cap_from_params(%{} = p, granter_uri) do
    %Ezagent.Capability{
      kind: Map.get(p, :kind, :any),
      behavior: Map.get(p, :behavior, :any),
      # SPEC 2026-05-27 capability-action-axis — propagate the action
      # axis from params; default `:any` (wildcard). Callers that
      # need narrow caps pass an explicit action.
      action: Map.get(p, :action, :any),
      instance: Map.get(p, :instance, :any),
      workspace_uri: Map.fetch!(p, :workspace_uri),
      granted_by: parse_uri(granter_uri),
      granted_at: Map.get(p, :granted_at, DateTime.utc_now())
    }
  end

  @doc """
  Read `actor`'s current Identity-slice caps as a `MapSet.t(Capability.t())`.

  This is the `{:held_by, actor}` / `{:admin, admin}` authorizer source
  for `Ezagent.Identity.Grant.prepare/4`: the actor's REAL held caps
  (the same set dispatch step 5.5 authorizes against). Reads the live
  `:identity` slice via `Ezagent.Kind.get_slice/2`, falling back to the
  persisted `users.caps_json` row when the Kind is not live (boot-order
  gap). Returns an EMPTY MapSet for an unknown URI — dispatch CapBAC
  then rejects cleanly rather than nil-deref'ing. Neither path is
  spoofable (the DB row was written under the §5.2 grant gate).
  """
  @spec read_held_caps(URI.t() | String.t()) :: MapSet.t(Ezagent.Capability.t())
  @impl Ezagent.Cap.AuthorityLoader
  def read_held_caps(actor_uri) do
    actor_uri
    |> parse_uri()
    |> Ezagent.IdentityCaps.load()
    |> MapSet.new()
  end

  @impl Ezagent.Cap.AuthorityLoader
  def principal_fenced?(actor_uri) do
    Ezagent.Identity.Offboarding.RevocationFence.fenced?(actor_uri)
  end

  @doc """
  Authorize a held-cap set against a runtime `needed`-cap map, with the EXACT
  predicate the dispatch chokepoint applies (`Ezagent.Kind.Runtime.authorizes?/2`):
  a cap authorizes only if it traces to a real entity (`granted_by_entity?/1`)
  AND `matches?/2` the needed cap.

  This is the SANCTIONED home for the cap-shape check used by NON-dispatching
  READ facades (`Ezagent.Agent.Config.read_cascade/4`,
  `Ezagent.World.IdentityData` caps panel) that must preserve a dispatch gate
  WITHOUT activating the target (FP5 S5 #115). It lives here — not in the facade
  and not in `Ezagent.Capability` (which is def-count-capped) — so the cap-check
  stays at an allowlisted chokepoint owner (`cap_check_only_at_chokepoint`).

  `needed` is the runtime needed-cap shape the dispatch path builds for the
  action (`%{kind:, behavior:, action:, instance:, workspace_uri:}`) — the
  caller constructs it from the target (pure field assignment, no `matches?`),
  so the instance binding (and thus the wrong-target denial) is preserved.
  """
  @spec caps_authorize?(
          URI.t(),
          MapSet.t(Ezagent.Capability.t()) | [Ezagent.Capability.t()],
          map()
        ) ::
          boolean()
  def caps_authorize?(%URI{} = holder, caps, needed) when is_map(needed) do
    caps
    |> normalize_caps()
    |> Enum.any?(&cap_authorizes?(holder, &1, needed))
  end

  def caps_authorize?(_holder, _caps, _needed), do: false

  @doc """
  Match an ALREADY-LOADED cap set (from `Ezagent.IdentityCaps.load/1`) against a
  runtime `needed`-cap map, WITHOUT re-loading the holder's store.

  Same shape predicate as `caps_authorize?/3` (`granted_by_entity?/1` AND
  `Ezagent.Capability.matches?/2`), PLUS a per-call TARGET-axis re-verify:
  each shape-matching artifact is verified against its target's CURRENT
  active authority row via `Ezagent.Cap.Authority.verify_against_current/3`
  — the same target gate the `Ezagent.Cap.authorize/3` chokepoint applies
  (`Cap.Authorize.verified_candidate?/2`). `IdentityCaps.load/1`'s `verified/2`
  gate is PRINCIPAL-axis (the holder's self-license generation); it does NOT
  re-check each artifact's TARGET generation at match time, so a target
  regenesis AFTER the load would otherwise leave a stale cap "matching"
  (cap-revocation hardening P3). The re-verify is ordered AFTER `matches?/2`
  so a pure shape-MISS short-circuits with ZERO authority reads (the batch
  caller `Ezagent.Domain.Agent.read_credential_statuses/3`, SPEC §6.3, does no
  authority read per shape-denied candidate). A shape-MATCHING but stale /
  tampered / wrong-generation cap still incurs ONE authority read before it is
  denied — so authority reads scale with the shape-matching subset, not
  strictly with the authorized subset.

  Deny (`false`) is CORRECT for a genuine miss — unsigned, scope-tuple / `:any`
  (no concrete target), old-gen, or tampered. But a TRANSIENT authority-store
  read failure is NOT a denial: it RAISES `Ezagent.Cap.AuthorityReadError` (via
  the `verify_against_current_checked/3` `:authority_read_failed` path) rather
  than silently returning `false` — the silent-denial class #1346 /
  `Ezagent.Cap.HoldsCap` forbids converting a store blip into an unauthorized
  result.
  """
  @spec caps_match?(
          MapSet.t(Ezagent.Capability.t()) | [Ezagent.Capability.t()],
          map()
        ) :: boolean()
  def caps_match?(caps, needed) when is_map(needed) do
    caps
    |> normalize_caps()
    |> Enum.any?(
      &(Ezagent.Capability.granted_by_entity?(&1) and
          Ezagent.Capability.matches?(&1, needed) and
          target_current?(&1))
    )
  end

  def caps_match?(_caps, _needed), do: false

  # The target gate of the `Ezagent.Cap.authorize/3` chokepoint, per artifact.
  # The presenter is the artifact's own `grantee_uri` — sound here (NOT a
  # grantee-check bypass) because every caller passes caps from
  # `IdentityCaps.load(holder)`, whose `verified_set/2` storage filter already
  # binds `grantee_uri == holder` (`Cap.storable_for?/2`); the load-time
  # binding is what the per-call re-verify adds the fresh TARGET-generation
  # check on top of.
  #
  # Uses the CHECKED verifier so a TRANSIENT authority-store read failure
  # (`{:error, :authority_read_failed}`) is NOT collapsed into a `false` denial
  # — it RAISES `Ezagent.Cap.AuthorityReadError` (fail-LOUD, per #1346 /
  # `Ezagent.Cap.HoldsCap`: a store blip must never masquerade as
  # "unauthorized"). A genuine stale / tampered / wrong-generation cap returns
  # `{:ok, false}` → not matched. A non-concrete target (scope-tuple / `:any`)
  # → `false` (a shape issue, not a transient error — such caps are already
  # excluded from `IdentityCaps.load/1` by `Cap.storable_for?/2`). No blanket
  # `rescue`/`catch`: `target_uri/1` and `verify_against_current_checked/3`
  # both return tagged results, so anything else genuinely unexpected must
  # crash (let-it-crash), not silently deny.
  defp target_current?(%Ezagent.Capability{grantee_uri: %URI{} = grantee} = cap) do
    case Ezagent.Cap.Authority.target_uri(cap) do
      {:ok, target} ->
        case Ezagent.Cap.Authority.verify_against_current_checked(cap, grantee, target) do
          {:ok, current?} ->
            current?

          {:error, :authority_read_failed} ->
            raise Ezagent.Cap.AuthorityReadError, target: target, grantee: grantee
        end

      {:error, :concrete_target_required} ->
        false
    end
  end

  defp target_current?(_cap), do: false

  defp cap_authorizes?(holder, %Ezagent.Capability{} = cap, needed) do
    Ezagent.Capability.granted_by_entity?(cap) and
      match?({:ok, %Ezagent.Capability{}}, Ezagent.Cap.authorize(holder, [cap], needed))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp cap_authorizes?(_holder, _cap, _needed), do: false

  defp normalize_caps(%MapSet{} = caps), do: caps
  defp normalize_caps(caps) when is_list(caps), do: MapSet.new(caps)
  defp normalize_caps(_), do: MapSet.new()

  @doc "Compatibility delegate; new callers use `Ezagent.IdentityCaps.load/1`."
  @spec read_identity_caps(URI.t() | String.t()) :: [Ezagent.Capability.t()]
  defdelegate read_identity_caps(entity_uri), to: Ezagent.IdentityCaps, as: :load
end
