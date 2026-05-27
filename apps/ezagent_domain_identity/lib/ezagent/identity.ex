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

  alias Ezagent.{Invocation, KindRegistry}

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

        target = URI.parse("#{URI.to_string(user_uri)}?action=identity.list_caps")

        case Invocation.dispatch(%Invocation{
               target: target,
               mode: :call,
               args: %{},
               ctx: %{
                 caller: user_uri,
                 caps: bootstrap_self_cap(user_uri),
                 reply: {:caller_inbox, self()}
               }
             }) do
          {:ok, %{caps: caps}} when is_list(caps) -> MapSet.new(caps)
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

  # Caller's own list_caps cap — per Q-MU-5 default. This is the
  # "self-grant" needed to dispatch list_caps_for one's own URI without
  # already having external caps. Since admin's caps include :any/:any/:any,
  # this matters only for non-admin first-mount.
  #
  # Phase 9 PR-3 (SPEC v3 §4): the self-cap is scoped to the user's
  # own workspace — they're reading their own caps, which lives in
  # their workspace. `entity_workspace_uri/1` derives it from the
  # 3-segment entity URI shape (`entity://user/<workspace>/<name>`).
  defp bootstrap_self_cap(user_uri) do
    workspace_uri = Ezagent.URI.entity_workspace_uri(user_uri)

    MapSet.new([
      %Ezagent.Capability{
        kind: :user,
        behavior: Ezagent.Behavior.Identity,
        # SPEC 2026-05-27 capability-action-axis — self-cap is for
        # `:list_caps` (Identity.actions/0 == [:list_caps, :has_cap?,
        # :grant_cap, :revoke_cap]; the user-facing baseline is read).
        action: :list_caps,
        instance: user_uri,
        workspace_uri: workspace_uri,
        granted_by: URI.parse("system://bootstrap"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }
    ])
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
    case URI.new(s) do
      {:ok, uri} -> uri
      _ -> :error
    end
  end

  defp parse_uri_safe(_), do: :error

  defp parse_uri(%URI{} = u), do: u
  defp parse_uri(s) when is_binary(s), do: URI.parse(s)

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
    target = URI.new!("#{URI.to_string(target_uri)}?action=identity.grant_cap")

    # PR-OWN-2 (caps-data-ownership SPEC #306 §5.2 + r4 fix): pass
    # the granter's REAL caps into dispatch ctx, not a hardcoded
    # admin-caps shape. Round-1 SPEC's §5.2 wildcard pre-check
    # was moot because every call presented as admin regardless of
    # granter's actual caps. Now `Behavior.Identity.invoke(:grant_cap,
    # ...)` (and the dispatch CapBAC) sees the granter's true cap set.
    #
    # **Known limitation (codex round-2 HIGH-1)**: the owner-delegated
    # facade path is INCOMPLETE in PR-OWN-2. Dispatch step 5.5 (CapBAC)
    # authorizes against the grantee/action BEFORE `invoke/4` runs the
    # §5.2 owner check. A non-admin session owner trying to grant via
    # this facade gets `:unauthorized` from dispatch — never reaches
    # §5.2's owner branch.
    #
    # Admin-path grants (admin caps in granter's slice) still work
    # correctly because dispatch CapBAC passes for them; §5.2 runs
    # inside `invoke` and accepts admin under `holds_admin_caps?`.
    #
    # PR-OWN-3 fixes this by (a) splitting Identity into Identity
    # (safe) + IdentityAdmin (privileged) so :grant_cap moves to a
    # cap-only Behavior, AND (b) adding `Ezagent.Kind.trusted_slice_update/3`
    # so the facade can do the §5.2 check itself + mutate grantee's
    # slice without going through dispatch CapBAC. Until PR-OWN-3,
    # owner-delegated grants must call lower-level APIs.
    granter_caps = read_granter_caps(granter)

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{cap: cap},
      ctx: %{
        caller: granter,
        caps: granter_caps,
        reply: :sync
      }
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, _} -> :ok
      :ok -> :ok
      err -> err
    end
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
    case Ezagent.Users.get_by_uri(granter_uri) do
      %{caps: caps} when is_list(caps) -> MapSet.new(caps)
      _ -> MapSet.new()
    end
  end
end
