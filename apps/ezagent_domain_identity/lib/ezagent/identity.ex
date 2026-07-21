defmodule Ezagent.Identity do
  @moduledoc """
  Facade for reading Identity slice (caps) per principal URI.

  Phase 4-completion Spec 05 §A.2.3: LV mounts call `list_caps_for/1`
  to derive `ctx.caps` from the session cookie's `current_entity_uri`
  (renamed from `current_user_uri` in PR #142 — works for any Entity).

  Uses the dispatch path so cap checks fire naturally (and audit rows
  appear for non-admin reads). Per Q-MU-5 default: every spawned User
  gets a self-grant cap (`%Capability{kind: :user, behavior: Identity,
  instance: own_uri}`) automatically in `init_slice`, so freshly logged-in
  users CAN read their own caps via dispatch without bypassing auth.
  """

  @behaviour Ezagent.Cap.AuthorityLoader

  alias Ezagent.{Cmd, KindRegistry, Router}

  @doc """
  List capabilities held by `principal_uri`. Returns `MapSet.t(Capability.t())`.

  Falls back to `MapSet.new()` if the User Kind isn't spawned yet
  (boot-window or unprovisioned user).
  """
  @spec list_caps_for(URI.t() | String.t()) :: MapSet.t(Ezagent.Capability.t())
  def list_caps_for(uri) do
    user_uri = parse_uri(uri)

    case KindRegistry.lookup(user_uri) do
      :error ->
        MapSet.new()

      {:ok, _pid} ->
        # wildcard-cap-fix 2026-05-26: `Behavior.Identity.post_init/2`
        # now queues a caps_json reconciliation continuation for every
        # user URI, so the rehydrated Kind is `:not_ready` until the
        # continue completes. A `:call`-mode dispatch against a
        # `:not_ready` Kind fails fast per hard-invariant #3, which
        # would return `MapSet.new()` to the caller — masking the
        # post_init repair entirely (the exact bug the fix is trying
        # to cure). Wait for readiness before dispatching; this is the
        # canonical pattern operator-CLI uses (see
        # `mix ezagent.stress.await_ready!/1`).
        await_ready(user_uri)

        target = Ezagent.URI.with_action(user_uri, :identity, :list_caps)

        case Router.dispatch(%Cmd{
               target: target,
               action: :list_caps,
               args: %{},
               ctx: %{
                 mode: :call,
                 caller: user_uri,
                 caps: signed_self_cap(user_uri, target),
                 reply: {:caller_inbox, self()}
               },
               origin: :trusted_internal
             }) do
          {:ok, %{caps: caps}} when is_list(caps) -> verified_cap_set(caps, user_uri)
          _ -> MapSet.new()
        end
    end
  end

  # Bounded wait — up to ~500ms total (50 × 10ms). post_init's
  # `handle_continue/3` does a single SQLite PK lookup + MapSet
  # operation; the bound is generous to tolerate Sandbox / contention.
  # On timeout, fall through to dispatch (which will :not_ready fail
  # fast and return empty MapSet — same posture as the pre-fix code).
  defp await_ready(user_uri, attempts \\ 50)

  defp await_ready(_user_uri, 0), do: :timeout

  defp await_ready(user_uri, attempts) do
    case Ezagent.ReadyGate.status(user_uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        await_ready(user_uri, attempts - 1)
    end
  end

  defp signed_self_cap(user_uri, target) do
    admin = Ezagent.URI.user(:system, :admin)

    case Ezagent.Cap.issue_for_action({:admin, admin}, user_uri, target) do
      {:ok, cap} -> MapSet.new([cap])
      {:error, _reason} -> MapSet.new()
    end
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
  def read_held_caps(actor_uri) do
    actor_uri = parse_uri(actor_uri)

    actor_uri
    |> read_granter_caps()
    |> verified_cap_set(actor_uri)
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
  @spec caps_authorize?(MapSet.t(Ezagent.Capability.t()) | [Ezagent.Capability.t()], map()) ::
          boolean()
  def caps_authorize?(caps, needed) when is_map(needed) do
    caps
    |> normalize_caps()
    |> Enum.any?(&cap_authorizes?(&1, needed))
  end

  defp cap_authorizes?(%Ezagent.Capability{grantee_uri: %URI{} = holder} = cap, needed) do
    Ezagent.Capability.granted_by_entity?(cap) and
      match?({:ok, %Ezagent.Capability{}}, Ezagent.Cap.authorize(holder, [cap], needed))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp cap_authorizes?(_, _), do: false

  defp normalize_caps(%MapSet{} = caps), do: caps
  defp normalize_caps(caps) when is_list(caps), do: MapSet.new(caps)
  defp normalize_caps(_), do: MapSet.new()

  @doc "Compatibility delegate; new callers use `Ezagent.EntityCaps.load/1`."
  @spec read_entity_caps(URI.t() | String.t()) :: [Ezagent.Capability.t()]
  defdelegate read_entity_caps(entity_uri), to: Ezagent.EntityCaps, as: :load

  defp verified_cap_set(caps, receiver_uri),
    do: Ezagent.EntityCaps.verified_set(caps, receiver_uri)

  # PR-OWN-2 (caps-data-ownership SPEC #306 §5.2 + r4):
  # Read the granter's current Identity slice caps via
  # `Ezagent.Kind.get_slice/2`. Skips dispatch (chicken-and-egg).
  #
  # Codex PR-OWN-2 round-2 HIGH-2 fix: REMOVED the URI-equality
  # admin-caps fallback (spoofable). Round-1 trusted URI string
  # equality; that lets any caller setting `granter_uri = admin_uri`
  # mint admin grants without proving they're admin.
  #
  # Codex round-3 boot-order fix: when the Kind isn't live (e.g.
  # admin facade call immediately after fresh app boot before any
  # dispatch has lazily-spawned the admin Kind), fall back to the
  # PERSISTED caps stored in the `users` table — NOT spoofable
  # because the row's `caps_json` was written under the §5.2 gate
  # (or by bootstrap before §5.2 was enforced; bootstrap admin's
  # caps are the all-four-:any invariant shape minted at seed
  # time and persisted with `granted_by` set to the bootstrap URI).
  #
  # The Kind-slice read is preferred when available (most recent
  # in-memory state); DB fallback covers the boot-order gap.
  # Empty MapSet for unknown URIs — dispatch CapBAC will reject.
  defp read_granter_caps(granter_uri) do
    case Ezagent.Kind.get_slice(granter_uri, :identity) do
      {:ok, %{caps: caps}} when is_struct(caps, MapSet) ->
        caps

      {:ok, %{caps: caps}} when is_list(caps) ->
        MapSet.new(caps)

      _ ->
        read_persisted_caps(granter_uri)
    end
  end

  # Persisted-caps fallback — reads `users` table. Returns empty
  # MapSet for non-user URIs (agents, system, etc) since this
  # facade is User-scoped today; future Agent-grant flows would
  # add an `Agents.get_by_uri/1` branch.
  defp read_persisted_caps(granter_uri) do
    granter_uri |> Ezagent.EntityCaps.UserStore.load() |> MapSet.new()
  end
end
