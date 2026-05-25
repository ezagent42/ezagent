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

  @impl Ezagent.Behavior
  def invoke(:grant_cap, slice, %{cap: cap}, ctx) do
    case check_grant_authorized(cap, ctx) do
      :ok ->
        new_slice = %{slice | caps: MapSet.put(slice.caps, cap)}
        notify_cap_change(ctx, :cap_granted, "A new capability was granted to you.", cap)
        {:ok, new_slice, %{caps: MapSet.to_list(new_slice.caps)}}

      {:error, _} = err ->
        err
    end
  end

  def invoke(:revoke_cap, slice, %{cap: cap}, ctx) do
    new_slice = %{slice | caps: MapSet.delete(slice.caps, cap)}
    notify_cap_change(ctx, :cap_revoked, "A capability was revoked from you.", cap)
    {:ok, new_slice, %{caps: MapSet.to_list(new_slice.caps)}}
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

  # Cross-workspace operator authority — `Behavior.Workspace` cap with
  # `workspace_uri: :any`. Held by `system://template-materialize`,
  # `system://workspace-loader`, and any operator who can mint
  # workspace-`:any` caps (the admin LV's grant form defaults to
  # `:any` workspace per `entity_caps_live.ex`).
  defp holds_cross_workspace_admin_cap?(%{caps: caps}) do
    caps_list = if is_struct(caps, MapSet), do: MapSet.to_list(caps), else: List.wrap(caps)

    Enum.any?(caps_list, fn
      %Ezagent.Capability{
        behavior: Ezagent.Behavior.Workspace,
        workspace_uri: :any
      } ->
        true

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

    Enum.any?(caps_list, fn
      %Ezagent.Capability{
        behavior: Ezagent.Behavior.Workspace,
        workspace_uri: ^ws_uri
      } ->
        true

      %Ezagent.Capability{
        behavior: Ezagent.Behavior.Workspace,
        workspace_uri: :any
      } ->
        true

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

    Enum.any?(caps_list, fn
      %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        instance: :any,
        workspace_uri: :any
      } ->
        true

      _ ->
        false
    end)
  end

  defp holds_admin_caps?(_), do: false
end
