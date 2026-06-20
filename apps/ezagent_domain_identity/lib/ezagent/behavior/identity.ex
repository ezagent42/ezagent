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
  `initial_caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])` when
  spawning admin User (PR-CC-1; replaces the previous deleted helper).

  ## Actions

  - `:list_caps` — `%{caps: [Capability.t()]}`
  - `:has_cap?` — args `%{cap: needed}` → `%{has: boolean}`
    where `needed = %{kind, behavior, instance}` shape per
    `Ezagent.Capability.matches?/2`.

  Both are `:call` mode — adapters need the return value.

  ## P2-b migration (2026-05-28)

  Migrated to the new `use Ezagent.Behavior` action/handler contract
  per SPEC #445 §4 + §6.2. Legacy `invoke/4` replaced by
  `handle_list_caps/2` and `handle_has_cap?/2`. Lifecycle callbacks
  (`init_slice/1`, `post_init/2`, `handle_continue/3`) are preserved
  per §6.2 step 9 — the Kind.Server still calls them directly. The
  caps_json reconcile mechanism stays intact.

  ## Phase B migration (2026-05-29) — `use Ezagent.Lifecycle`

  Converted to the Lifecycle developer API per SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §5 + OQ-8.
  STATE-ONLY: `caps` (a `MapSet` of `%Capability{}`) is PERSISTENT; no
  PID/ref/ETS transients exist. The conversion:

  - `init_slice/1` → `create/1` (build the caps set + owner identity cap).
  - The `post_init/2` + `handle_continue/3` caps_json reconcile is a
    DB-PROJECTION reconcile (OQ-8); it FOLDS into `activate/2`'s 3-arity
    return — `activate` re-reads `users.caps_json`, unions it into the
    persistent `state`, and returns the reconciled state. Idempotent
    set-union by `MapSet` (invariant 20). Runs on EVERY start (fresh +
    cold-load), subsuming the old post-init-only path.

  No transients → the `activate` rebuild is purely the reconcile read
  (returns `{:ok, %{}, reconciled_state}` for user URIs, `{:ok, %{}}`
  otherwise). Auto-derived `state_slice` is `:identity` (matches the old
  explicit one). Handler bodies byte-identical. `required_caps/0` +
  `data_owner/1` pass through verbatim.
  """

  use Ezagent.Lifecycle

  # PR-OWN-3 (caps-data-ownership SPEC #306 §7): SPLIT — Identity
  # keeps only the safe read actions (`:list_caps`, `:has_cap?`).
  # Privileged write actions (`:grant_cap`, `:revoke_cap`) live on
  # `Ezagent.Behavior.IdentityAdmin` (below in this file).
  action(:list_caps,
    args: %{},
    returns: %{caps: {:list, :map}},
    caps: [{:list_caps, kind: :any}],
    description: "List the principal's capability set",
    modes: [:call]
  )

  action(:has_cap?,
    args: %{cap: :map},
    returns: %{has: :boolean},
    caps: [{:has_cap?, kind: :any}],
    description: "Check whether the principal holds a capability matching the needed shape",
    modes: [:call]
  )

  # =================================================================
  # Explicit `required_caps/0` — preserved as `kind: :any` (Identity
  # is registered on multiple Kinds; see check 11(b) escape in
  # `Ezagent.Behavior` callback contract). The auto-derived macro
  # version also produces `:any` so this override is technically a
  # no-op, but kept explicit for parity with the pre-migration shape.
  # =================================================================
  @doc "Cap map for the read actions (`list_caps`/`has_cap?`), pinned to `kind: :any` because Identity is registered on multiple Kinds (matches the auto-derived shape; kept explicit for parity)."
  def required_caps do
    %{
      list_caps: Ezagent.Capability.cap(:any, __MODULE__, :list_caps),
      has_cap?: Ezagent.Capability.cap(:any, __MODULE__, :has_cap?)
    }
  end

  # =================================================================
  # Lifecycle state — `create/1` builds the PERSISTENT caps set once
  # (Phase B; was `init_slice/1`). `state_slice` auto-derives to
  # `:identity`.
  # =================================================================

  @impl Ezagent.Lifecycle
  def create(args) do
    caps =
      case Map.get(args, :initial_caps) do
        nil -> MapSet.new()
        %MapSet{} = set -> set
        list when is_list(list) -> MapSet.new(list)
      end

    # PR-OWN-3 codex round-1 MED fix: provision the owner-derived
    # safe Identity cap at slice init.
    caps =
      case Map.get(args, :uri) do
        %URI{} = uri ->
          caps
          |> add_owner_identity_cap(uri)
          |> add_agent_self_caps(uri)

        _ ->
          caps
      end

    {:ok, %{caps: caps}}
  end

  # Agent-owned config-evolve (spec 2026-06-11 rev 4) — every agent's base
  # self-caps at create gain TWO self-scoped entries, held over ITSELF
  # (instance: self), so the agent can:
  #   1. project its durable config pointer into its own Sandbox cache
  #      (the step-2 / boot-reconcile `Cmd(self, :write_path, …)`) — gated
  #      by `cap(:agent, Sandbox, :write_path)`, and
  #   2. run its own boot reconciliation (`reconcile_cascade`) — gated by
  #      `cap(:agent, ConfigEvolve, :reconcile_cascade)`.
  # User Kinds get neither (the cascade write + reconcile are agent-only).
  defp add_agent_self_caps(caps, %URI{} = uri) do
    if kind_for_uri(uri) == :agent do
      instance = Ezagent.URI.instance(uri)
      workspace_uri = Ezagent.Capability.workspace_of(uri)

      caps
      |> MapSet.put(
        self_scoped_cap(:agent, Ezagent.Behavior.Sandbox, :write_path, instance, workspace_uri)
      )
      |> MapSet.put(
        self_scoped_cap(
          :agent,
          Ezagent.Behavior.ConfigEvolve,
          :reconcile_cascade,
          instance,
          workspace_uri
        )
      )
    else
      caps
    end
  end

  defp self_scoped_cap(kind, behavior, action, instance, workspace_uri) do
    %Ezagent.Capability{
      kind: kind,
      behavior: behavior,
      action: action,
      instance: instance,
      workspace_uri: workspace_uri,
      granted_by: bootstrap_granter(),
      granted_at: DateTime.utc_now()
    }
  end

  defp add_owner_identity_cap(caps, %URI{} = uri) do
    self_identity_cap = %Ezagent.Capability{
      kind: kind_for_uri(uri),
      behavior: __MODULE__,
      action: :list_caps,
      instance: Ezagent.URI.instance(uri),
      workspace_uri: Ezagent.Capability.workspace_of(uri),
      granted_by: bootstrap_granter(),
      granted_at: DateTime.utc_now()
    }

    MapSet.put(caps, self_identity_cap)
  end

  defp kind_for_uri(%URI{scheme: "entity"} = uri) do
    if Ezagent.URI.type?(uri, :agent), do: :agent, else: :user
  end

  defp kind_for_uri(_), do: :user

  defp bootstrap_granter do
    if function_exported?(Ezagent.Entity.User, :admin_uri, 0) do
      Ezagent.Entity.User.admin_uri()
    else
      Ezagent.URI.system(:bootstrap, :"pr-own-3")
    end
  end

  @doc "Cap data-owner for Identity: the entity OWNS its own `:identity` slice (PR-OWN-3 / SPEC #306 §3.3) — an entity URI is its own owner; `:any` is its own owner; anything else is `:no_owner`."
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # `activate/2` — caps_json reconcile, folded from the old
  # `post_init/2` + `handle_continue/3` (Phase B / OQ-8: a DB-projection
  # reconcile moves into `activate`'s 3-arity return). Runs on EVERY
  # start (fresh + cold-load), re-reading `users.caps_json` and unioning
  # it into the persistent `state.caps` (idempotent set-union, invariant
  # 20). No transients to rebuild → the 2-arity `{:ok, %{}}` no-op is
  # returned when there is no reconcile (non-user URI, empty caps_json,
  # or the union is a no-op).
  @impl Ezagent.Lifecycle
  def activate(%{caps: existing_caps} = state, %{self_uri: %URI{scheme: "entity"} = uri}) do
    if Ezagent.URI.type?(uri, :user) do
      case caps_from_caps_json(uri) do
        [] ->
          {:ok, %{}}

        caps_list when is_list(caps_list) ->
          merged = MapSet.union(existing_caps, MapSet.new(caps_list))

          if MapSet.size(merged) == MapSet.size(existing_caps) do
            {:ok, %{}}
          else
            {:ok, %{}, %{state | caps: merged}}
          end
      end
    else
      {:ok, %{}}
    end
  end

  def activate(_state, _ctx), do: {:ok, %{}}

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

  # =================================================================
  # New-contract action handlers (§6.2 — replace invoke/4)
  # =================================================================

  @doc "Action handler: return the entity's full cap set (read from the `:caps` slice) as a list."
  def handle_list_caps(_args, ctx) do
    caps = ctx[:read].(:caps, MapSet.new())
    {:ok, %{caps: MapSet.to_list(caps)}, []}
  end

  @doc "Action handler: whether the entity holds any cap matching `needed` (via `Ezagent.Capability.matches?/2`)."
  def handle_has_cap?(%{cap: needed}, ctx) do
    caps = ctx[:read].(:caps, MapSet.new())
    has? = Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed))
    {:ok, %{has: has?}, []}
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

  ## P2-b migration (2026-05-28)

  Migrated to the new `use Ezagent.Behavior` action/handler contract
  per SPEC #445 §4 + §6.2. Legacy `invoke/4` replaced by
  `handle_grant_cap/2` and `handle_revoke_cap/2`. Slice mutation
  (`MapSet` ops) is expressed as `:set` effects; cap-change
  notification stays as an inline side effect (`Notifications.notify`
  call) — it's an idempotent, observation-only Notify path that
  doesn't need to be lifted into the effect grammar per SPEC §4.5
  inline-permitted-side-effects.

  ## Phase B migration (2026-05-29) — `use Ezagent.Lifecycle`

  Converted to the Lifecycle developer API per SPEC
  `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §5 +
  OQ-7. STATE-ONLY: shares the `:identity` slice with
  `Ezagent.Behavior.Identity` (the caps `MapSet`); no transients. Because
  the slice key (`:identity`) differs from the module-name derivation
  (`identity_admin`), it uses the sanctioned `state_slice:` override
  escape hatch (SPEC §5 / §7 OQ-7) and carries the
  `# lifecycle:state_slice_override` marker. `init_slice/1` → `create/1`
  (delegates to `Identity.create/1`, the shared slice shape). The
  caps_json reconcile lives on `Identity.activate/2`, so IdentityAdmin's
  `activate/2` is the macro no-op (omitted). Handler bodies
  byte-identical. `required_caps/0` + `data_owner/1` + `workspace_scoped?/0`
  pass through.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :identity

  action(:grant_cap,
    args: %{cap: :map},
    returns: %{caps: {:list, :map}},
    caps: [{:grant_cap, kind: :user, workspace_scoped?: false}],
    description: "grant a new capability to this principal (admin)",
    modes: [:call]
  )

  action(:revoke_cap,
    args: %{cap: :map},
    returns: %{caps: {:list, :map}},
    caps: [{:revoke_cap, kind: :user, workspace_scoped?: false}],
    description: "revoke a capability from this principal (admin)",
    modes: [:call]
  )

  # =================================================================
  # Explicit `required_caps/0` — preserved `kind: :user` axis.
  # =================================================================
  @doc "Cap map for the admin write actions (`grant_cap`/`revoke_cap`), pinned to the `:user` kind axis (these are user-principal admin operations)."
  def required_caps do
    %{
      grant_cap: Ezagent.Capability.cap(:user, __MODULE__, :grant_cap),
      revoke_cap: Ezagent.Capability.cap(:user, __MODULE__, :revoke_cap)
    }
  end

  @doc "`false` — admin grant/revoke routinely crosses workspaces, so the required cap is NOT workspace-scoped."
  def workspace_scoped?, do: false

  # =================================================================
  # Lifecycle state — `create/1` delegates to `Identity.create/1`, the
  # shared `:identity` slice shape (Phase B; was `init_slice/1`). The
  # `state_slice:` override pins the key to `:identity`. The caps_json
  # reconcile lives on `Identity.activate/2`; IdentityAdmin's `activate`
  # is the macro no-op.
  # =================================================================

  @impl Ezagent.Lifecycle
  def create(args) do
    # Defer to Identity for slice shape — both Behaviors share it.
    Ezagent.Behavior.Identity.create(args)
  end

  @doc "`:no_owner` for all subjects (PR-OWN-3): admin grant/revoke authority comes from the caller's admin cap, not from per-entity data-ownership."
  def data_owner(_), do: :no_owner

  # =================================================================
  # New-contract action handlers (§6.2 — replace invoke/4)
  # =================================================================

  # Bug 2 fix (Allen 2026-05-26) — `cap` arrives as one of three
  # shapes (struct / atom-keyed map / string-keyed map). `normalize!`
  # coerces all three to the canonical struct.
  @doc """
  Grant a capability to this principal — the cap-grant chokepoint.

  Normalizes the incoming `cap` (struct / atom-keyed / string-keyed → canonical
  struct), runs the grant authorization checks (`check_action_wildcard_grant_authorized/2`
  + `check_grant_authorized/2`), dedups any cap with the same identity-key, adds
  the new cap to the `:caps` slice, notifies the principal, and emits `:cap_granted`.
  """
  def handle_grant_cap(%{cap: cap}, ctx) do
    cap_struct = Ezagent.Capability.normalize!(cap, granter_from_ctx(ctx))

    with :ok <- check_action_wildcard_grant_authorized(cap_struct, ctx),
         :ok <- check_grant_authorized(cap_struct, ctx) do
      current_caps = ctx[:read].(:caps, MapSet.new())

      # Dedup by identity-tuple BEFORE adding (codex review HIGH-1
      # follow-on for the grant path).
      deduped =
        current_caps
        |> Enum.reject(fn held ->
          Ezagent.Capability.identity_key(held) ==
            Ezagent.Capability.identity_key(cap_struct)
        end)
        |> MapSet.new()

      new_caps = MapSet.put(deduped, cap_struct)

      notify_cap_change(
        ctx,
        :cap_granted,
        "A new capability was granted to you.",
        cap_struct
      )

      # SPEC 2026-06-16 §4 (Decision #88) — manager provenance. A
      # manager-delegated grant (NOT self, NOT admin, but authorized because
      # the caller holds a Manage cap over the target + the cap is delegable)
      # is recorded with `via_manage: true` in the audit/telemetry emit so it
      # is distinguishable from a self/admin grant. The provenance lives on
      # the EVENT payload, not the `%Capability{}` struct (the struct is
      # `@enforce_keys` + `to_map`/`from_map`/`identity_key`/Jason-coupled, and
      # `granted_by` already carries the manager URI via `normalize!/2`).
      {:ok, %{caps: MapSet.to_list(new_caps)},
       [
         {:set, :caps, new_caps},
         {:emit, :cap_granted,
          %{
            target_uri: Map.get(ctx, :self_uri) |> uri_to_str(),
            cap: cap_struct,
            via_manage: manager_delegated_grant?(cap_struct, ctx),
            at: DateTime.utc_now()
          }}
       ]}
    end
  end

  @doc "Revoke a capability from this principal — normalizes the `cap` then removes the identity-key match via `Ezagent.Capability.revoke/2`, notifies the principal, and emits `:cap_revoked`."
  # NOTE (SPEC 2026-06-17 §3.3): a revoke dispatched under a `{:rule,…}` tag is
  # authorized SOLELY by the `Kind.Runtime` step-5.5 rule bypass; this handler runs
  # NO authorization check and `rule_cap_bounded?/1` is grant-only. Safe because
  # revoke strictly de-escalates (removes authority), but it is intentional that
  # the rule-branch structural bound does not constrain revoke.
  def handle_revoke_cap(%{cap: cap}, ctx) do
    cap_struct = Ezagent.Capability.normalize!(cap, granter_from_ctx(ctx))
    current_caps = ctx[:read].(:caps, MapSet.new())

    case Ezagent.Capability.revoke(current_caps, cap_struct) do
      {:ok, new_caps} ->
        notify_cap_change(
          ctx,
          :cap_revoked,
          "A capability was revoked from you.",
          cap_struct
        )

        {:ok, %{caps: MapSet.to_list(new_caps)},
         [
           {:set, :caps, new_caps},
           {:emit, :cap_revoked,
            %{
              target_uri: Map.get(ctx, :self_uri) |> uri_to_str(),
              cap: cap_struct,
              at: DateTime.utc_now()
            }}
         ]}

      {:error, :cannot_revoke_admin} = err ->
        err
    end
  end

  defp uri_to_str(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_str(other), do: inspect(other)

  # SPEC 2026-06-17 §3.2 (MEDIUM-N3) — the `system://bootstrap` grant-path
  # fallback is REMOVED. Every grant/revoke now routes through
  # `Ezagent.Identity.Grant`, which always sets `ctx.caller` to a real
  # entity (it derives + validates the entity `granted_by` and stamps it
  # on the `%Capability{}` BEFORE dispatch). So `granter_from_ctx/1` is
  # only ever consulted for the string/atom-keyed CLI cap shape (where
  # `normalize!/2` uses the granter to stamp `granted_by`); a missing
  # entity caller there is a programmer error (let-it-crash), not a
  # silent bootstrap impersonation. (NOTE: the create-time self-cap
  # stamper at the top of this file and `capability_registry.ex`'s
  # `Code.ensure_loaded?` hedge are deliberately untouched per §3.2.)
  defp granter_from_ctx(%{caller: %URI{} = uri}), do: uri

  defp notify_cap_change(ctx, kind, text, cap) do
    target_uri = Map.get(ctx, :self_uri)

    if match?(%URI{scheme: "entity"}, target_uri) and Ezagent.URI.type?(target_uri, :user) do
      _ =
        Ezagent.Notifications.notify(target_uri, %{
          type: kind,
          body: %{text: text, cap_summary: inspect(cap)},
          source: __MODULE__
        })
    end

    :ok
  end

  # SPEC 2026-05-27 capability-action-axis §3.6.1(b) — runtime grant-
  # boundary check.
  defp check_action_wildcard_grant_authorized(%Ezagent.Capability{} = cap, ctx) do
    cond do
      Ezagent.Capability.action_of(cap) != :any ->
        :ok

      scope_bounded_instance?(cap.instance) ->
        :ok

      holds_admin_caps?(ctx) ->
        :ok

      true ->
        {:error, :wildcard_action_grant_requires_admin_authority}
    end
  end

  defp scope_bounded_instance?({:within_session, %URI{}}), do: true
  defp scope_bounded_instance?({:within_workspace, %URI{}}), do: true
  defp scope_bounded_instance?({:spawned_by, %URI{}}), do: true
  defp scope_bounded_instance?(_), do: false

  @doc """
  Structural bound a `{:rule, …}` grant must satisfy (SPEC 2026-06-17 §3.3).

  A rule may NOT mint `kind: :any` / `behavior: :any`; and an
  `action: :any` cap is allowed ONLY when the instance is scope-bounded
  (`{:within_session/within_workspace/spawned_by, %URI{}}`) — a concrete
  `%URI{}` instance is allowed only with a concrete action.

  This is written to MATCH `check_action_wildcard_grant_authorized/2`
  exactly (an `action: :any` cap needs a scope-bounded instance there
  too), so the two gates are consistent by construction and the
  wildcard gate (which runs first) never rejects a shape this branch
  would have accepted. PUBLIC for direct unit testing (matching the
  precedent of `holds_admin_caps?/1` etc.) — the rule branch itself is
  not yet reachable end-to-end via dispatch (see `check_grant_authorized/2`).
  """
  @spec rule_cap_bounded?(Ezagent.Capability.t()) :: boolean()
  def rule_cap_bounded?(%Ezagent.Capability{kind: :any}), do: false
  def rule_cap_bounded?(%Ezagent.Capability{behavior: :any}), do: false

  def rule_cap_bounded?(%Ezagent.Capability{instance: instance} = cap) do
    scope_bounded_instance?(instance) or
      (match?(%URI{}, instance) and Ezagent.Capability.action_of(cap) != :any)
  end

  # PR-OWN-2 §5.2 enforcement helpers — called from `handle_grant_cap/2`.

  # Rule branch (SPEC 2026-06-17 §3.3, Decision #154). Fires ONLY when
  # `ctx[:authorization_rule]` is set — and ONLY `Ezagent.Identity.Grant`
  # (the chokepoint) sets it, exclusively for the `{:rule, name,
  # configurer}` tag, after the caller verified the rule's precondition
  # (e.g. `PublicView.public_view?/1`). The grant is then authorized on
  # the rule's assertion rather than on `ctx.caps` (which is `[]` for a
  # rule grant). The STRUCTURAL bound: a rule may NOT mint a wildcard
  # cap. `rule_cap_bounded?/1` is written to MATCH
  # `check_action_wildcard_grant_authorized/2`'s logic EXACTLY (an
  # `action: :any` cap is allowed only with a scope-bounded instance),
  # so the two gates are consistent by construction and the wildcard
  # gate never rejects a shape the rule branch would have accepted.
  #
  # ⚠️ NOT REACHABLE END-TO-END IN PR-1 (dormant infrastructure). A
  # `{:rule, …}` grant carries `ctx.caps = []`, so dispatch step 5.5
  # (`Ezagent.Kind.Runtime` cap check, ~runtime.ex:407) denies it with
  # `:unauthorized` BEFORE this handler runs. PR-1 ships ZERO sites using
  # `{:rule, …}` (all 14 use `{:held_by}`/`{:system}`, which carry caps),
  # so this branch + `rule_cap_bounded?/1` are verified as a pure
  # predicate, not through dispatch. PR-2/PR-3 (which introduce the first
  # `{:rule, …}` callers) MUST make the path reachable — either teach
  # dispatch step 5.5 to honor `ctx[:authorization_rule]`, or route rule
  # grants via `Ezagent.Kind.trusted_slice_update/3` (which already
  # bypasses dispatch CapBAC). That is an authorization-path change,
  # deliberately OUT of PR-1's mechanical/behavior-preserving scope.
  defp check_grant_authorized(%Ezagent.Capability{} = cap, ctx)
       when is_map_key(ctx, :authorization_rule) do
    if rule_cap_bounded?(cap) do
      :ok
    else
      {:error, :rule_grant_must_be_concrete_scoped}
    end
  end

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
      # SPEC `2026-05-29-dispatch-returning-effect.md` §2b — call
      # the public re-export on `Ezagent.Behavior` rather than reaching
      # into `Ezagent.CapabilityRegistry` directly. §11 Gate 6 grep
      # gate forbids plugin Behavior modules from talking to the
      # registry as an implementation detail; the Behavior helper is
      # the sanctioned author-facing surface. The underlying logic is
      # unchanged (the re-export is a thin delegate).
      case Ezagent.Behavior.data_owner_of(behavior, instance) do
        %URI{} = owner ->
          caller = Map.get(ctx, :caller)

          # Grant-authorizer set (SPEC 2026-06-16 §1, Decision #88):
          # `{self, admin, manager-of-target}`.
          #   * self  — caller IS the data-owner of the target slice.
          #   * admin — bootstrap wildcard holder.
          #   * manager — caller holds a `Behavior.Manage`/`:any`-action cap
          #     scoped to THIS target instance (it manages the instance).
          #
          # The manager branch is delegation-bounded (codex P1): `grant_cap`
          # does NOT inherit `Role.CapMint`'s delegation policy (that policy
          # is not on this runtime path), so a manager added to the authorizer
          # without a held-cap check could grant arbitrary concrete-action
          # caps it does not hold (escalation). For the manager case ONLY we
          # therefore require the cap-to-grant to `Capability.matches?` a cap
          # the CALLER ITSELF holds — a manager grants only caps it holds
          # whose scope covers the target. `Capability.Match` is asymmetric
          # (a concrete held cap never authorizes a wildcard request), so a
          # manager cannot fabricate authority it lacks; fail-closed
          # `:grant_not_delegable` if no held cap matches. Self/admin keep
          # their existing behavior (no delegation bound).
          cond do
            caller == owner -> :ok
            holds_admin_caps?(ctx) -> :ok
            holds_manage_over_target?(ctx, instance) -> check_delegable_by_caller(cap, ctx)
            true -> {:error, :grant_not_owner}
          end

        :any ->
          require_workspace_admin(ctx, cap_ws, cap)

        _ ->
          require_bootstrap_admin(ctx, :grant_owner_unresolvable)
      end
    else
      :ok
    end
  end

  defp check_grant_authorized(_cap, _ctx), do: :ok

  # SPEC 2026-06-16 §4 (Decision #88) — manager-provenance predicate for the
  # `:cap_granted` audit emit. True iff the grant was authorized via the NEW
  # manager branch: the cap resolves to a concrete `%URI{}` data-owner, the
  # caller is NOT that owner, NOT bootstrap-admin, but DOES hold a Manage cap
  # over the target AND the cap is delegable. Mirrors the
  # `check_grant_authorized/2` manager branch exactly so provenance can never
  # diverge from the authorization decision (self/admin/non-manager → false).
  defp manager_delegated_grant?(%Ezagent.Capability{behavior: behavior, instance: instance}, ctx)
       when is_atom(behavior) do
    if Code.ensure_loaded?(behavior) and function_exported?(behavior, :data_owner, 1) do
      case Ezagent.Behavior.data_owner_of(behavior, instance) do
        %URI{} = owner ->
          Map.get(ctx, :caller) != owner and
            not holds_admin_caps?(ctx) and
            holds_manage_over_target?(ctx, instance)

        _ ->
          false
      end
    else
      false
    end
  end

  defp manager_delegated_grant?(_cap, _ctx), do: false

  # SPEC 2026-06-16 §1 (Decision #88) — "caller holds Manage over target".
  # The manager of an instance is the principal holding a
  # `Behavior.Manage`, `:any`-action cap scoped to that instance (the shape
  # `Ezagent.CreatorGrant.manage_cap/4` mints at create — `cap(:<kind>,
  # Manage, :any, instance, ws)`). We test the caller's caps (`ctx.caps`)
  # with a DIRECT predicate (not `Capability.matches?` against a fixed
  # `needed`): the `kind` axis of a Manage cap is the managed Kind's concrete
  # type (`:agent`/`:session`/…), and `matches?`'s asymmetric rule means a
  # `needed.kind: :any` would NOT match a concrete held kind — so a needed
  # map cannot express "Manage over target, any kind" in one shot. The
  # predicate instead pins `behavior == Manage` + `action_of == :any` (the
  # Manage shape) and reuses the instance-scope match
  # (`Capability.matches?` on a kind/behavior/action/workspace-wildcarded
  # needed) so the held cap's instance-scope tuples
  # (`:within_workspace`/`:spawned_by`/concrete instance/`:any`) are honored
  # against the target. A generic cap cannot masquerade as Manage authority.
  defp holds_manage_over_target?(ctx, instance) do
    target = manage_target_instance(instance)

    ctx
    |> caller_caps()
    |> Enum.any?(fn
      %Ezagent.Capability{behavior: Ezagent.Behavior.Manage} = held ->
        Ezagent.Capability.action_of(held) == :any and
          held_instance_covers_target?(held, target)

      _ ->
        false
    end)
  end

  # Does the held Manage cap's instance scope cover `target`? We reuse
  # `Capability.matches?`'s instance-scope semantics by building a `needed`
  # whose kind/behavior/action/workspace AXES ECHO the held cap's own values
  # (so those four axes match trivially — sidestepping the asymmetric-`:any`
  # rule which would reject a `needed.kind: :any` against a concrete held
  # kind), leaving the INSTANCE axis as the only real constraint. This
  # honors the held cap's `:within_workspace`/`:spawned_by`/concrete-URI/`:any`
  # instance scopes against the target.
  defp held_instance_covers_target?(%Ezagent.Capability{} = held, %URI{} = target) do
    needed = %{
      kind: held.kind,
      behavior: held.behavior,
      action: Ezagent.Capability.action_of(held),
      instance: target,
      workspace_uri: held.workspace_uri
    }

    Ezagent.Capability.matches?(held, needed)
  end

  defp held_instance_covers_target?(_held, _target), do: false

  # The "target" a Manage cap must cover is the cap-to-grant's `instance`.
  # When that instance is itself a scope tuple (e.g. `{:within_session, _}`),
  # use the inner concrete URI as the managed target — a manager of the
  # session/agent/workspace instance is what the Manage cap is scoped to.
  defp manage_target_instance({_scope, %URI{} = uri}), do: uri
  defp manage_target_instance(other), do: other

  # codex P1 (MANDATORY) — explicit held-cap delegation bound for the
  # MANAGER case only. The cap-to-grant must `Capability.matches?` a cap the
  # CALLER ITSELF holds: `Capability.matches?(held, needed)` treats the
  # held cap as the authorizer and the cap-to-grant as the request, so the
  # asymmetric wildcard rule applies — a concrete held cap never authorizes a
  # wildcard-axis request, and the held cap's instance-scope tuples bound
  # WHICH targets it reaches. Fail-closed `:grant_not_delegable` if none
  # matches. (Self/admin never reach here — they keep their existing,
  # delegation-unbounded behavior.)
  defp check_delegable_by_caller(%Ezagent.Capability{} = cap, ctx) do
    needed = %{
      kind: cap.kind,
      behavior: cap.behavior,
      action: Ezagent.Capability.action_of(cap),
      instance: cap.instance,
      workspace_uri: cap.workspace_uri
    }

    if ctx |> caller_caps() |> Enum.any?(&Ezagent.Capability.matches?(&1, needed)) do
      :ok
    else
      {:error, :grant_not_delegable}
    end
  end

  # The caller's held caps, from the dispatch ctx (`ctx.caps`, the same
  # source `holds_admin_caps?/1` reads). Tolerates a MapSet, a list, or a
  # `%{caps: _}` wrapper; anything else → empty (fail-closed).
  defp caller_caps(ctx) do
    case Map.get(ctx, :caps) do
      %MapSet{} = set -> MapSet.to_list(set)
      list when is_list(list) -> list
      %{caps: %MapSet{} = set} -> MapSet.to_list(set)
      %{caps: list} when is_list(list) -> list
      _ -> []
    end
  end

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

  @doc """
  Does the cap list hold a structural cross-workspace admin cap?

  SPEC 2026-05-27-workspace-cap-based-visibility OQ-4 (r5 — option b):
  PUBLIC so `Ezagent.Identity.AdminAuthority.admin?/2` can compose
  the 4-predicate admin shortcut.
  """
  @spec holds_cross_workspace_admin_cap?(MapSet.t() | [Ezagent.Capability.t()] | map()) ::
          boolean()
  def holds_cross_workspace_admin_cap?(caps) when is_struct(caps, MapSet) do
    caps |> MapSet.to_list() |> holds_cross_workspace_admin_cap_list?()
  end

  def holds_cross_workspace_admin_cap?(caps) when is_list(caps) do
    holds_cross_workspace_admin_cap_list?(caps)
  end

  def holds_cross_workspace_admin_cap?(%{caps: caps})
      when is_list(caps) or is_struct(caps, MapSet) do
    holds_cross_workspace_admin_cap?(caps)
  end

  def holds_cross_workspace_admin_cap?(_), do: false

  defp holds_cross_workspace_admin_cap_list?(caps_list) when is_list(caps_list) do
    Enum.any?(caps_list, fn
      %Ezagent.Capability{
        kind: :workspace,
        behavior: Ezagent.Behavior.Workspace,
        action: :any,
        instance: :any,
        workspace_uri: :any
      } ->
        true

      _ ->
        false
    end)
  end

  defp holds_workspace_admin_cap?(%{caps: caps}, %URI{} = ws_uri) do
    caps_list = if is_struct(caps, MapSet), do: MapSet.to_list(caps), else: List.wrap(caps)

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

      _ ->
        false
    end)
  end

  defp holds_workspace_admin_cap?(_, _), do: false

  defp require_bootstrap_admin(ctx, error_tag) do
    if holds_admin_caps?(ctx) do
      :ok
    else
      {:error, error_tag}
    end
  end

  @doc """
  Does the cap list hold a bootstrap-wildcard cap (all five axes
  `:any`)?

  SPEC 2026-05-27-workspace-cap-based-visibility OQ-4 (r5 — option b):
  PUBLIC so `Ezagent.Identity.AdminAuthority.admin?/2` can compose
  the 4-predicate admin shortcut.
  """
  @spec holds_admin_caps?(MapSet.t() | [Ezagent.Capability.t()] | map()) :: boolean()
  def holds_admin_caps?(caps) when is_struct(caps, MapSet) do
    caps |> MapSet.to_list() |> holds_admin_caps_list?()
  end

  def holds_admin_caps?(caps) when is_list(caps) do
    holds_admin_caps_list?(caps)
  end

  def holds_admin_caps?(%{caps: caps}) when is_list(caps) or is_struct(caps, MapSet) do
    holds_admin_caps?(caps)
  end

  def holds_admin_caps?(_), do: false

  defp holds_admin_caps_list?(caps_list) when is_list(caps_list) do
    Enum.any?(caps_list, fn
      %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any
      } ->
        true

      _ ->
        false
    end)
  end
end
