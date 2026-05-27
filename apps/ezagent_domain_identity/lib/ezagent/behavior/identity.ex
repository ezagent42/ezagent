defmodule Ezagent.Behavior.Identity do
  @moduledoc """
  Identity Behavior — holds the principal's capability set in slice
  state.

  Phase 3d落地 Decision #24 (Identity Behavior 标准化):

  Every Entity Kind (User / Agent) carries an `:identity` slice with
  `caps :: MapSet.t(Ezagent.Capability.t())`. At dispatch step 5.5,
  `Ezagent.Kind.Runtime` reads the **caller**'s caps from the dispatch
  ctx (which adapters populated from `Ezagent.Behavior.Identity.list_caps`
  call on the caller Kind) and matches against the needed cap.

  ## Why caps live in slice (not module-level constant)

  Phase 1-2 admin caps came from `Ezagent.Entity.User.admin_caps/0`
  (deleted in PR-CC-1 — replaced by `Ezagent.SystemPrincipal.caps/1`
  reading the closed Catalog). Phase 3d puts them in **runtime slice**
  so:
  - `:sys.get_state(admin_user_pid)` exposes the live caps (debuggable)
  - Phase 4+ admin grants new cap → mutate slice, not redeploy code
  - Agent Kinds also carry caps (different per agent), same shape

  ## State

      %{caps: MapSet.t(Ezagent.Capability.t())}

  `init_slice(args)` reads `args[:initial_caps]` (default `MapSet.new()`).
  Chat plugin Application passes
  `initial_caps: Ezagent.SystemPrincipal.caps("system://bootstrap")` when
  spawning admin User (PR-CC-1; replaces the previous deleted helper).

  ## Actions

  - `:list_caps` — `{:ok, slice, %{caps: [Capability.t()]}}`
  - `:has_cap?` — args `%{cap: needed}` → `{:ok, slice, %{has: boolean}}`
    where `needed = %{kind, behavior, instance}` shape per
    `Ezagent.Capability.matches?/2`.

  Both are `:call` mode — adapters need the return value.
  """

  @behaviour Ezagent.Behavior

  # PR-OWN-3 (caps-data-ownership SPEC #306 §7): SPLIT — Identity
  # keeps only the safe read actions (`:list_caps`, `:has_cap?`).
  # Privileged write actions (`:grant_cap`, `:revoke_cap`) moved to
  # `Ezagent.Behavior.IdentityAdmin` (cap-only). The split is the
  # workaround for the SPEC §1 reframe (caps are behavior-scoped):
  # a single Behavior cap can't distinguish safe + privileged
  # actions, so we use two Behaviors with separate cap_subjects
  # + separate data_owner/1 rules.
  @impl Ezagent.Behavior
  def actions, do: [:list_caps, :has_cap?]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Identity is registered on both User AND Agent — kind axis is `:any`
  # per check 11(b)'s multi-Kind escape. The self-list-caps default-grant
  # in `init_slice/1` carries the same cap shape (kind narrowed via
  # `kind_for_uri/1`) — the runtime substitution at step 5.5 reconciles
  # the declarative `:any` with the per-instance held cap.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      list_caps: Ezagent.Capability.cap(:any, __MODULE__, :list_caps),
      has_cap?: Ezagent.Capability.cap(:any, __MODULE__, :has_cap?)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:list_caps, "list all capabilities currently granted to this principal"},
      {:has_cap?, "test whether this principal holds a specific capability shape"}
    ]
  end

  # PR-OWN-3 SPEC #306 §3.3: data_owner for Identity is the
  # entity itself (Alice owns Alice's list_caps/has_cap?). Means
  # users get default `Behavior.Identity` cap on their own URI at
  # creation — they can read their own caps without admin
  # intervention.
  @impl Ezagent.Behavior
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @impl Ezagent.Behavior
  def state_slice, do: :identity

  @impl Ezagent.Behavior
  def init_slice(args) do
    caps =
      case Map.get(args, :initial_caps) do
        nil -> MapSet.new()
        %MapSet{} = set -> set
        list when is_list(list) -> MapSet.new(list)
      end

    # PR-OWN-3 codex round-1 MED fix: provision the owner-derived
    # safe Identity cap at slice init. `data_owner/1` declares the
    # entity as owner of its own list_caps/has_cap?; without this
    # init-time grant the public dispatch path would deny a user
    # reading their own caps (their cap set wouldn't include the
    # matching `Behavior.Identity` cap). Codex correctly noted this
    # left the safe Identity half of the split unprovisioned.
    #
    # Synthesized via `CapabilityRegistry.default_grants_from_data_owner/2`
    # against User Kind (the helper iterates all Behaviors registered
    # for that Kind; here we only consume the Identity cap row).
    # Skipped if `args[:uri]` is missing (test scenarios constructing
    # slices directly).
    caps =
      case Map.get(args, :uri) do
        %URI{} = uri ->
          add_owner_identity_cap(caps, uri)

        _ ->
          caps
      end

    %{caps: caps}
  end

  defp add_owner_identity_cap(caps, %URI{} = uri) do
    self_identity_cap = %Ezagent.Capability{
      kind: kind_for_uri(uri),
      behavior: __MODULE__,
      # SPEC 2026-05-27 capability-action-axis — the self-identity cap
      # authorizes the entity to dispatch `:list_caps` on its own URI
      # (used by every read of caller_caps via `Identity.list_caps_for`).
      # Narrowing to `:list_caps` reflects intent; future actions (e.g.
      # `:has_cap?`) require their own grants.
      action: :list_caps,
      instance: Ezagent.URI.instance(uri),
      workspace_uri: Ezagent.Capability.workspace_of(uri),
      granted_by: bootstrap_granter(),
      granted_at: DateTime.utc_now()
    }

    MapSet.put(caps, self_identity_cap)
  end

  defp kind_for_uri(%URI{scheme: "entity", host: "user"}), do: :user
  defp kind_for_uri(%URI{scheme: "entity", host: "agent"}), do: :agent
  defp kind_for_uri(_), do: :user

  defp bootstrap_granter do
    if function_exported?(Ezagent.Entity.User, :admin_uri, 0) do
      Ezagent.Entity.User.admin_uri()
    else
      URI.parse("system://bootstrap/pr-own-3")
    end
  end

  # Post-init reconciliation: re-merge caps from `users.caps_json` into
  # the just-loaded `:identity` slice. Why this is necessary:
  #
  #   `init_slice/1` runs FRESH (and reads `args[:initial_caps]`) only
  #   when `Kind.Snapshot.load_or_init/3` finds no snapshot. With a
  #   snapshot present, the slice is restored from `kind_snapshots` and
  #   `init_slice/1` is bypassed entirely — `Map.merge(fresh,
  #   loaded_state)` then has `loaded_state[:identity]` override
  #   `fresh[:identity]` wholesale. Result: any cap added to
  #   `users.caps_json` AFTER the first spawn (or during a botched
  #   first spawn that wrote a partial snapshot — see the
  #   wildcard-cap-fix regression of 2026-05-26 where
  #   `mix ezagent.user.create --caps '*'` wrote the wildcard to
  #   caps_json but the empty `MapSet.new()` default in the entity
  #   spawn fn produced a snapshot lacking it) is INVISIBLE to
  #   dispatch step 5.5's `Kind.holds_cap?/2` slice lookup.
  #
  # This post_init re-reads caps_json on EVERY spawn and merges its
  # contents into `slice.caps` as a UNION. Slice-added caps from
  # `:grant_cap` survive (they remain in the loaded slice); caps_json
  # caps re-appear regardless of whether they made it into the
  # snapshot the first time. Caps_json is the durable bootstrap
  # manifest (immutable post-create) so the union semantic is
  # idempotent for the steady state.
  #
  # ## V1 limitation: revoke vs caps_json
  #
  # `:revoke_cap` mutates the slice only — it does NOT update
  # `users.caps_json`. So a revoked caps_json cap re-appears on next
  # spawn. This is documented as a V1 limitation. In practice the
  # caps_json baseline is `User.default_caps(workspace) ++
  # <caller-supplied caps at creation>` (e.g. `mix ezagent.user.create
  # --caps '*'` for admin-delegate accounts), and revoking those
  # bootstrap caps is not a V1 use case — admin revocations target
  # post-create `:grant_cap` additions which live in the slice
  # alone. A future SPEC ("caps SoT consolidation") will sync
  # `:grant_cap` / `:revoke_cap` writes back to caps_json, at which
  # point this post_init becomes either redundant or hardened with
  # a "deleted-since" set on the user row.
  #
  # ## Non-user URIs
  #
  # Agents and other entity Kinds carry the same `:identity` slice
  # but DO NOT have a `users.caps_json` row. `post_init/2` returns
  # `:ok` for those (no caps_json source to merge) and the slice is
  # left exactly as loaded.
  # `post_init/2` per Behavior contract MUST be cheap + side-effect
  # free (Behavior moduledoc: "side-effecting work goes in
  # handle_continue/3"). We therefore do NO DB work here — only queue
  # a continuation for user URIs. The actual `users.caps_json` read +
  # slice merge happens in `handle_continue/3` below.
  #
  # Trade-off this introduces (codex review MED, accepted):
  # `Ezagent.Kind.Server` keeps the Kind `:not_ready` through the
  # entire post-init phase, including the continue round. Every user
  # spawn now stays `:not_ready` for one additional `handle_continue`
  # step (a single SQLite primary-key lookup + MapSet union, typically
  # <1ms). Callers that synchronously dispatch immediately after
  # `Kind.spawn/2` MUST await readiness via `Ezagent.ReadyGate.status/1`
  # — the existing pattern in `mix ezagent.stress` (`await_ready!/1`)
  # and the standard production demand-spawn path (which already
  # buffers casts via `PendingDelivery` when not_ready). The earlier
  # pre-decide variant pushed the DB read into post_init/2 (lifecycle
  # contract violation) to keep the Kind ready-fast; the contract win
  # outweighs the readiness latency.
  @impl Ezagent.Behavior
  def post_init(%{uri: %URI{scheme: "entity", host: "user"} = uri}, _slice),
    do: {:continue, {:reconcile_caps_json, uri}}

  def post_init(_args, _slice), do: :ok

  @impl Ezagent.Behavior
  def handle_continue({:reconcile_caps_json, %URI{} = uri}, slice, _ctx) do
    case caps_from_caps_json(uri) do
      [] ->
        :ignore

      caps_list when is_list(caps_list) ->
        caps_from_json = MapSet.new(caps_list)
        existing_caps = Map.get(slice, :caps, MapSet.new())
        merged = MapSet.union(existing_caps, caps_from_json)

        if MapSet.size(merged) == MapSet.size(existing_caps) do
          # No new caps to add — slice already reflects caps_json.
          # Skip the slice-write to avoid an unnecessary snapshot
          # commit on every spawn.
          :ignore
        else
          {:ok, %{slice | caps: merged}}
        end
    end
  end

  # Read caps_json caps for a user URI. Returns `[]` for unknown URIs,
  # missing `Ezagent.Users` module (boot-order tolerance), or any
  # error path — the post_init reconcile then returns `:ignore` and
  # the slice is left intact.
  defp caps_from_caps_json(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.Users) and
         function_exported?(Ezagent.Users, :get_by_uri, 1) do
      try do
        case Ezagent.Users.get_by_uri(uri) do
          %{caps: caps} when is_list(caps) -> caps
          _ -> []
        end
      rescue
        _ -> []
      catch
        _, _ -> []
      end
    else
      []
    end
  end

  @impl Ezagent.Behavior
  def invoke(:list_caps, slice, _args, _ctx) do
    {:ok, slice, %{caps: MapSet.to_list(slice.caps)}}
  end

  def invoke(:has_cap?, slice, %{cap: needed}, _ctx) do
    has? = Enum.any?(slice.caps, &Ezagent.Capability.matches?(&1, needed))
    {:ok, slice, %{has: has?}}
  end

  # PR-OWN-3: `:grant_cap` + `:revoke_cap` moved to
  # `Ezagent.Behavior.IdentityAdmin`. The `notify_cap_change/4` helper
  # is shared via that module (called from IdentityAdmin's invokes).

  # PR-OWN-3: `notify_cap_change/4` moved to IdentityAdmin Behavior
  # which now owns the cap-mutation actions.

  @impl Ezagent.Behavior
  def interface do
    %{
      list_caps: %{
        description: "List the principal's capability set",
        args: %{},
        returns: %{caps: {:list, :map}},
        modes: [:call]
      },
      has_cap?: %{
        description: "Check whether the principal holds a capability matching the needed shape",
        args: %{cap: :map},
        returns: %{has: :boolean},
        modes: [:call]
      }
    }
  end
end

defmodule Ezagent.Behavior.IdentityAdmin do
  @moduledoc """
  IdentityAdmin Behavior — privileged cap mutation actions on a
  principal's `:identity` slice.

  PR-OWN-3 (caps-data-ownership SPEC #306 §7) split-out from
  `Ezagent.Behavior.Identity`. Reasoning (codex PR-OWN-1 round-1 MED
  + SPEC §1 reframe): caps are behavior-scoped, so a single Identity
  Behavior cap would have collapsed safe (`:list_caps`, `:has_cap?`)
  and privileged (`:grant_cap`, `:revoke_cap`) actions into one
  grant surface — letting users self-mutate their own caps.

  This Behavior holds ONLY the privileged actions; `Identity` keeps
  the safe ones. `data_owner/1` returns `:no_owner` here so the
  §5.2 gate routes IdentityAdmin grants only through the bootstrap
  admin path.

  Shares the `:identity` slice with `Ezagent.Behavior.Identity` (both
  Behaviors registered against User + Agent Kinds).
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:grant_cap, :revoke_cap]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # IdentityAdmin is registered on the User Kind only (per
  # `EzagentDomainIdentity.Application` line ~263) — kind axis is `:user`.
  # workspace_scoped? = false: admin grant/revoke routinely crosses
  # workspaces (an admin in workspace://system grants caps to users in
  # other workspaces) — the existing `check_grant_authorized/2` enforces
  # admin authority directly.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      grant_cap: Ezagent.Capability.cap(:user, __MODULE__, :grant_cap),
      revoke_cap: Ezagent.Capability.cap(:user, __MODULE__, :revoke_cap)
    }
  end

  @impl Ezagent.Behavior
  def workspace_scoped?, do: false

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:grant_cap, "grant a new capability to this principal (admin)"},
      {:revoke_cap, "revoke a capability from this principal (admin)"}
    ]
  end

  # PR-OWN-3: data_owner = :no_owner. Privileged ops have no
  # per-instance owner; only bootstrap admin (via §5.2's
  # `holds_admin_caps?` check) can dispatch these.
  @impl Ezagent.Behavior
  def data_owner(_), do: :no_owner

  @impl Ezagent.Behavior
  def state_slice, do: :identity

  @impl Ezagent.Behavior
  def init_slice(args) do
    # Defer to Identity for slice init shape — both Behaviors share it.
    Ezagent.Behavior.Identity.init_slice(args)
  end

  # Bug 2 fix (Allen 2026-05-26) — `cap` arrives as one of three
  # shapes depending on caller path:
  #
  #   - `%Ezagent.Capability{}` when an Elixir caller built the struct
  #     directly (e.g. `Ezagent.Identity.grant_cap/3`'s struct branch),
  #   - an ATOM-keyed map when an Elixir caller passed params
  #     (Identity.grant_cap/3's map branch),
  #   - a STRING-keyed map when the CLI's Optimus `:map` arg type
  #     produced it via `Jason.decode/1` (the
  #     `mix ezagent user grant_cap --cap '{...}'` path).
  #
  # The previous code blindly `MapSet.put`'d whatever shape arrived.
  # String-keyed maps then sat in the MapSet bypassing
  # `Capability.matches?/2`'s `%__MODULE__{}` head, silently denying
  # every dispatch the cap was meant to authorize.
  # `Capability.normalize!/2` coerces all three shapes to the canonical
  # struct (or raises on anything else — per
  # `feedback_let_it_crash_no_workarounds`).
  @impl Ezagent.Behavior
  def invoke(:grant_cap, slice, %{cap: cap}, ctx) do
    cap_struct = Ezagent.Capability.normalize!(cap, granter_from_ctx(ctx))

    case check_action_wildcard_grant_authorized(cap_struct, ctx) do
      :ok ->
        do_grant_cap(slice, cap_struct, ctx)

      {:error, _} = err ->
        err
    end
  end

  # SPEC 2026-05-27 capability-action-axis §3.6.1(b) — runtime grant-
  # boundary check. The SPEC's intent is to prevent NON-admin callers
  # from minting **broad** behavior-wildcard caps (e.g.
  # `kind: :workspace, behavior: Workspace, action: :any`) that
  # silently confer all-actions authority on the target. Admin-tier
  # callers (with bootstrap admin / workspace-admin) CAN mint
  # behavior-wildcard caps; the existing per-shape
  # `check_grant_authorized/2` already gates that.
  #
  # The check fires only when:
  #   1. The cap has `action: :any`
  #   2. AND the cap is NOT structurally bounded — i.e. NOT
  #      `instance: {:within_*, _}` / `{:spawned_by, _}`. Scope-
  #      bounded delegation caps (Session.build_desired_caps Cap #1
  #      + Cap #2) are NARROWER than their behavior axis suggests
  #      because the instance scope tuple constrains where the cap
  #      fires. An owner can legitimately mint these for their
  #      orchestrator.
  #   3. AND the caller does NOT hold admin caps (full wildcard).
  #
  # If all three hold, reject. Otherwise, fall through to the
  # existing per-shape check.
  defp check_action_wildcard_grant_authorized(%Ezagent.Capability{} = cap, ctx) do
    cond do
      Ezagent.Capability.action_of(cap) != :any ->
        :ok

      scope_bounded_instance?(cap.instance) ->
        # Scope-bounded delegation: instance tuple is the structural
        # narrowing. Action wildcard symmetric with the behavior
        # wildcard for these patterns (orchestrator within session,
        # spawned-by lineage).
        :ok

      holds_admin_caps?(ctx) ->
        :ok

      true ->
        {:error, :wildcard_action_grant_requires_admin_authority}
    end
  end

  # Scope-bounded instance tuples per `Capability.@type scope_tuple`.
  defp scope_bounded_instance?({:within_session, %URI{}}), do: true
  defp scope_bounded_instance?({:within_workspace, %URI{}}), do: true
  defp scope_bounded_instance?({:spawned_by, %URI{}}), do: true
  defp scope_bounded_instance?(_), do: false

  defp do_grant_cap(slice, cap_struct, ctx) do
    case check_grant_authorized(cap_struct, ctx) do
      :ok ->
        # Drop any pre-existing cap with the same identity-tuple
        # (kind+behavior+instance+workspace_uri) BEFORE adding the
        # newly-stamped struct. Two grants of the "same logical cap"
        # always collapse to one row — without the dedup, the second
        # grant would add a duplicate-modulo-`granted_at` entry
        # (codex review HIGH-1 follow-on for the grant path; the
        # symmetric `revoke` fix lives in `Capability.revoke/2`).
        deduped =
          slice.caps
          |> Enum.reject(fn held ->
            Ezagent.Capability.identity_key(held) ==
              Ezagent.Capability.identity_key(cap_struct)
          end)
          |> MapSet.new()

        new_slice = %{slice | caps: MapSet.put(deduped, cap_struct)}

        notify_cap_change(
          ctx,
          :cap_granted,
          "A new capability was granted to you.",
          cap_struct
        )

        {:ok, new_slice, %{caps: MapSet.to_list(new_slice.caps)}}

      {:error, _} = err ->
        err
    end
  end

  # Revoke takes the same normalization step so a CLI revoke matches
  # the canonical struct shape sitting in the slice (a bare string-keyed
  # map would never match), then delegates to `Capability.revoke/2`
  # which:
  #
  #   1. Refuses to remove the bootstrap-admin invariant cap
  #      (codex review HIGH-3 — direct `MapSet.delete/2` bypassed
  #      `Capability.admin_invariant?/1`'s structural guard).
  #
  #   2. Matches by identity-tuple instead of full-struct equality,
  #      so a freshly-normalized revoke argument (with current-time
  #      `granted_at`) actually finds the original-grant-time cap
  #      sitting in the slice (codex review HIGH-1).
  def invoke(:revoke_cap, slice, %{cap: cap}, ctx) do
    cap_struct = Ezagent.Capability.normalize!(cap, granter_from_ctx(ctx))

    case Ezagent.Capability.revoke(slice.caps, cap_struct) do
      {:ok, new_caps} ->
        new_slice = %{slice | caps: new_caps}

        notify_cap_change(
          ctx,
          :cap_revoked,
          "A capability was revoked from you.",
          cap_struct
        )

        {:ok, new_slice, %{caps: MapSet.to_list(new_slice.caps)}}

      {:error, :cannot_revoke_admin} = err ->
        err
    end
  end

  # The `caller` axis of dispatch ctx is one of:
  #
  #   - `%URI{}` for normal dispatch (CLI / LV / API paths)
  #   - `:system` atom for cross-cutting system-internal grants
  #     (bootstrap seed, snapshot-replay, ...)
  #   - missing / nil for malformed ctx (boot-order edge cases)
  #
  # For the `granted_by` stamp on a normalized cap we want a URI in
  # all three cases — the bootstrap URI is the structural fallback
  # for non-URI callers per Decision #81 + SPEC v3 §4.4. `URI` callers
  # pass through; non-URI callers collapse to the same bootstrap URI
  # `Behavior.Identity.bootstrap_granter/0` returns. We re-derive it
  # locally rather than calling the private helper in the sibling
  # module.
  defp granter_from_ctx(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = uri -> uri
      _ -> bootstrap_granter_uri()
    end
  end

  defp bootstrap_granter_uri do
    if function_exported?(Ezagent.Entity.User, :admin_uri, 0) do
      Ezagent.Entity.User.admin_uri()
    else
      URI.parse("system://bootstrap/grant_cap")
    end
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      grant_cap: %{
        description: "Add a capability to the principal's set",
        args: %{cap: :map},
        returns: %{caps: {:list, :map}},
        modes: [:call]
      },
      revoke_cap: %{
        description: "Remove a capability from the principal's set",
        args: %{cap: :map},
        returns: %{caps: {:list, :map}},
        modes: [:call]
      }
    }
  end

  defp notify_cap_change(ctx, kind, text, cap) do
    target_uri = Map.get(ctx, :self_uri)

    if match?(%URI{scheme: "entity", host: "user"}, target_uri) do
      # Notification contract (`Ezagent.Notifications.notify/2`) requires
      # `%{type: atom, body: map, source: module}`. Pre-fix this call
      # used the legacy `%{kind:, text:, cap_summary:}` shape and crashed
      # the grant_cap dispatch with ArgumentError (E2E 2026-05-25:
      # `mix ezagent.feishu.bind` saved the binding but BindingPolicy
      # cap-grant blew up for non-admin users).
      _ =
        Ezagent.Notifications.notify(target_uri, %{
          type: kind,
          body: %{text: text, cap_summary: inspect(cap)},
          source: __MODULE__
        })
    end

    :ok
  end

  # PR-OWN-2 §5.2 enforcement helpers — called from `invoke(:grant_cap,...)`.
  #
  # Wildcard analysis (pathology-B sweep follow-up to PR-CC-2-v2):
  # A cap is "true wildcard" (admin authority) ONLY when ALL of these
  # are unbounded:
  #   - `kind` is `:any`
  #   - `behavior` is `:any`
  #   - `instance` is `:any`
  #   - `workspace_uri` is `:any`
  # That exact shape is `bootstrap_wildcard()` — the structural admin
  # invariant per Decision #81 and only legitimately held by
  # `system://bootstrap` + `system://mix-task`.
  #
  # Anything narrower is a SCOPE-BOUNDED grant and goes the
  # workspace-admin path:
  #   - `kind: :any` / `behavior: :any` with a concrete
  #     `workspace_uri` — "wildcard within workspace W"; the workspace
  #     admin for W is the legitimate granter.
  #   - `behavior: :any` with a scope-bounded `instance` tuple
  #     (`{:within_session, _}` / `{:spawned_by, _}` per Decision #137)
  #     — bounded to a single session or an orchestrator's descendants;
  #     workspace admin grants. This is the orchestrator delegation
  #     shape `Session.build_desired_caps/4` mints (Cap #1 + Cap #2).
  #
  # Branches:
  #   (1) TRUE wildcard cap shape (all four axes `:any`) — only the
  #       bootstrap admin can grant. Rejects with
  #       :grant_wildcard_requires_admin otherwise.
  #   (1b) Scope-bounded wildcard (`kind: :any` or `behavior: :any` but
  #       narrowed on workspace_uri or instance) — workspace-admin
  #       grants for the cap's workspace_uri.
  #   (2) cap's Behavior declares data_owner/1 — caller must be
  #       the data owner. Rejects with :grant_not_owner otherwise.
  #   (3) cap's Behavior has NOT migrated — fall through to :ok
  #       (incremental rollout; dispatch-level CapBAC remains the
  #       only check).
  defp check_grant_authorized(
         %Ezagent.Capability{
           kind: :any,
           behavior: :any,
           instance: :any,
           workspace_uri: :any
         },
         ctx
       ),
       do: require_bootstrap_admin(ctx, :grant_wildcard_requires_admin)

  defp check_grant_authorized(%Ezagent.Capability{kind: :any} = cap, ctx),
    do: require_workspace_admin(ctx, cap.workspace_uri, cap)

  defp check_grant_authorized(%Ezagent.Capability{behavior: :any} = cap, ctx),
    do: require_workspace_admin(ctx, cap.workspace_uri, cap)

  defp check_grant_authorized(
         %Ezagent.Capability{behavior: behavior, instance: instance, workspace_uri: cap_ws} = cap,
         ctx
       )
       when is_atom(behavior) do
    if Code.ensure_loaded?(behavior) and
         function_exported?(behavior, :data_owner, 1) do
      case Ezagent.CapabilityRegistry.data_owner_of(behavior, instance) do
        %URI{} = owner ->
          caller = Map.get(ctx, :caller)

          cond do
            caller == owner -> :ok
            holds_admin_caps?(ctx) -> :ok
            true -> {:error, :grant_not_owner}
          end

        # Codex PR-OWN-4 round-1 HIGH fix: `:any` means workspace-
        # scoped — workspace admin should be able to grant.
        # Round-1 routed `:any` to bootstrap-admin-only, blocking
        # workspace-admin delegation that SPEC §3/§5.2 mandates.
        # Now: require concrete `cap.workspace_uri` + caller holds
        # admin cap for that workspace (or bootstrap admin).
        :any ->
          require_workspace_admin(ctx, cap_ws, cap)

        # :no_owner / {:scope, _, _} — ownerless, bootstrap-admin
        # only (same as wildcard caps above).
        _ ->
          require_bootstrap_admin(ctx, :grant_owner_unresolvable)
      end
    else
      # Behavior not yet migrated — incremental rollout fallthrough.
      :ok
    end
  end

  defp check_grant_authorized(_cap, _ctx), do: :ok

  # Workspace-admin grant predicate (PR-OWN-4 codex HIGH fix +
  # pathology-B follow-up to PR-CC-2-v2).
  #
  # The cap being granted MUST carry a workspace authority the caller
  # can mint:
  # - `workspace_uri: :any` (cross-workspace grant) — caller must
  #   hold either bootstrap admin OR a `Behavior.Workspace`
  #   `workspace_uri: :any` cap (the operator surface for granting
  #   `:any`-workspace caps to other entities, e.g. admin LV grants).
  # - `workspace_uri: %URI{}` (concrete workspace grant) — caller
  #   must hold either bootstrap admin OR a `Behavior.Workspace` cap
  #   covering that workspace (the `:any` workspace_uri Workspace cap
  #   also matches — cross-workspace operator authority).
  defp require_workspace_admin(ctx, :any, _cap) do
    if holds_admin_caps?(ctx) or holds_cross_workspace_admin_cap?(ctx) do
      :ok
    else
      {:error, :grant_workspace_any_requires_admin}
    end
  end

  defp require_workspace_admin(ctx, %URI{} = cap_ws, _cap) do
    if holds_admin_caps?(ctx) or holds_workspace_admin_cap?(ctx, cap_ws) do
      :ok
    else
      {:error, :grant_workspace_admin_required}
    end
  end

  defp require_workspace_admin(_ctx, _, _), do: {:error, :grant_workspace_uri_invalid}

  # Cross-workspace operator authority — the EXACT operator shape:
  # `Behavior.Workspace` on `:workspace` Kind, `instance: :any`,
  # `workspace_uri: :any`. This is the shape held by
  # `system://template-materialize` + `system://workspace-loader` (both
  # declared as `Capability.cap(:workspace, Workspace, :any)` in
  # `Ezagent.SystemPrincipal.Catalog`, which builds the operator shape
  # via `Capability.cap/3`).
  #
  # Pathology-B narrowing (codex round-1 MED-1): the predicate
  # demands EXACTLY this shape so a narrowly-scoped Workspace cap
  # (e.g. `kind: :session, behavior: Workspace, instance: <uri>,
  # workspace_uri: :any`) does NOT confer cross-workspace grant
  # authority. The four-axis pattern matches the cap_for_action shape
  # the dispatch chokepoint builds against `Behavior.Workspace`, so
  # only a cap that genuinely authorizes any-workspace Workspace
  # actions passes here.
  defp holds_cross_workspace_admin_cap?(%{caps: caps}) do
    caps_list = if is_struct(caps, MapSet), do: MapSet.to_list(caps), else: List.wrap(caps)

    # SPEC 2026-05-27 capability-action-axis — cross-workspace admin
    # operator shape gains `:action`. The legitimate operator caps
    # (system principals: `template-materialize`, `workspace-loader`,
    # etc.) hold `action: :any`. We match either an explicit
    # `action: :any` (post-SPEC) or a pre-SPEC legacy struct missing
    # the key (validated via `action_of/1`).
    Enum.any?(caps_list, fn
      %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :any,
        instance: :any,
        workspace_uri: :any
      } ->
        true

      %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        instance: :any,
        workspace_uri: :any
      } = cap ->
        # codex r2 new HIGH (forgeable legacy path): the legacy branch
        # must ONLY accept caps that were legitimately serialized BEFORE
        # the `:action` axis existed (i.e. struct literally missing the
        # key, post-`binary_to_term` from a pre-SPEC snapshot).
        # `action_of(cap) == :any` was forgeable — a caller controlling
        # `ctx.caps` could `Map.delete(cap, :action)` to fall through the
        # narrow check. Tighten to `not Map.has_key?(cap, :action)` —
        # a real absent-field check, no Map.get default.
        not Map.has_key?(cap, :action)

      _ ->
        false
    end)
  end

  defp holds_cross_workspace_admin_cap?(_), do: false

  # Holder of a workspace-admin cap on `workspace_uri`. The
  # canonical shape: any `Behavior.Workspace` cap on this workspace.
  # Workspace Behavior's `data_owner` returns `:any`, so by SPEC §5.2
  # the cap was minted by a bootstrap admin or transitively by a
  # workspace admin. Either is acceptable for further delegation
  # within the same workspace.
  #
  # PR-CC-2-v2 (SPEC §5 catalog narrowing): a `Behavior.Workspace`
  # cap with `workspace_uri: :any` is the cross-workspace shape held
  # by system principals like `system://template-materialize` and
  # `system://workspace-loader` — those principals are the
  # legitimate granters of template caps across workspaces, so the
  # predicate accepts the `:any` workspace_uri form too. The narrower
  # `^ws_uri` literal still matches for delegated workspace admins.
  defp holds_workspace_admin_cap?(%{caps: caps}, %URI{} = ws_uri) do
    caps_list = if is_struct(caps, MapSet), do: MapSet.to_list(caps), else: List.wrap(caps)

    # SPEC 2026-05-27 capability-action-axis (codex impl PR review HIGH-2):
    # narrow workspace-admin recognition to caps that ACTUALLY confer
    # admin authority — `action: :any` (behavior-wildcard) only. A
    # narrow `Workspace :create_session` cap is the structural shape
    # of a non-admin member auto-grant (per PR #408); accepting it
    # here would re-introduce the over-grant the SPEC closes (a
    # principal with `:create_session` + delegated `IdentityAdmin
    # :grant_cap` could mint broader workspace caps via the workspace-
    # admin path). Pre-SPEC snapshot-restored caps (missing :action
    # key) are honored via `action_of/1`.
    Enum.any?(caps_list, fn
      %Ezagent.Capability{
        behavior: Ezagent.Behavior.Workspace,
        action: :any,
        workspace_uri: ^ws_uri
      } ->
        true

      %Ezagent.Capability{
        behavior: Ezagent.Behavior.Workspace,
        action: :any,
        workspace_uri: :any
      } ->
        true

      # Legacy snapshot-restored caps (no `:action` key) — codex r2 fix:
      # ONLY accept caps that literally lack the `:action` field (real
      # `binary_to_term` of pre-SPEC %Capability{} produces this exact
      # shape via non-exhaustive struct restore). A forgeable
      # `action_of(cap) == :any` check let any controlled-`ctx.caps`
      # path `Map.delete(cap, :action)` to bypass the narrow guard;
      # `Map.has_key?` is the real absent-field check, no defaulting.
      %Ezagent.Capability{
        behavior: Ezagent.Behavior.Workspace,
        workspace_uri: ^ws_uri
      } = cap ->
        not Map.has_key?(cap, :action)

      %Ezagent.Capability{
        behavior: Ezagent.Behavior.Workspace,
        workspace_uri: :any
      } = cap ->
        not Map.has_key?(cap, :action)

      _ ->
        false
    end)
  end

  defp holds_workspace_admin_cap?(_, _), do: false

  # Bootstrap admin holds at least one cap with `behavior: :any` AND
  # `workspace_uri: :any`. This is the only legitimate granter for
  # wildcard or ownerless caps.
  # `Ezagent.SystemPrincipal.caps("system://bootstrap")` mints exactly
  # this shape (PR-CC-1 replacement for `User.admin_caps/0`).
  defp require_bootstrap_admin(ctx, error_tag) do
    if holds_admin_caps?(ctx) do
      :ok
    else
      {:error, error_tag}
    end
  end

  # Codex PR-OWN-2 round-2 HIGH-1 fix: bootstrap-admin predicate
  # must require ALL four `:any` wildcards (kind, behavior, instance,
  # workspace_uri). Round-1 omitted `instance: :any`, which let a
  # narrow-instance delegated wildcard cap (e.g.
  # `kind:any/behavior:any/instance:<target>/workspace:any`) satisfy
  # the predicate — privilege escalation for that specific target.
  # `SystemPrincipal.caps("system://bootstrap")` mints exactly the
  # all-four-wildcards shape; no legitimate delegated cap should
  # have that exact shape.
  defp holds_admin_caps?(%{caps: caps}) do
    caps_list = if is_struct(caps, MapSet), do: MapSet.to_list(caps), else: List.wrap(caps)

    # SPEC 2026-05-27 capability-action-axis §3.6.1 — admin invariant
    # gains a fifth axis `:action`. Struct pattern matching is
    # non-exhaustive, so a pre-action-axis cap (missing the `:action`
    # key) ALSO matches `%Capability{action: :any, ...}` IF the value
    # at the key is `:any` — but absence of the key would not match
    # the literal. We use `action: :any` in the pattern AND a
    # `is_map_key`-guarded clause for legacy old-struct snapshots so
    # both shapes are recognized: (1) fresh post-SPEC caps with
    # `action: :any` set explicitly, (2) old struct restored from
    # snapshot where the `:action` key is absent — handled via
    # `Capability.action_of/1`.
    Enum.any?(caps_list, fn
      %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any
      } ->
        true

      # Legacy pre-action-axis structs (snapshot restored before this
      # SPEC landed) — the `:action` key is absent from the map. Match
      # the other four axes; treat missing `:action` as `:any`.
      %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        instance: :any,
        workspace_uri: :any
      } = cap ->
        Ezagent.Capability.action_of(cap) == :any

      _ ->
        false
    end)
  end

  defp holds_admin_caps?(_), do: false
end
