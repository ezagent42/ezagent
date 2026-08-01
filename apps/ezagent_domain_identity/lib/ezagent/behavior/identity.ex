defmodule Ezagent.ActionSet.Identity do
  @moduledoc """
  Identity Behavior — holds the principal's capability set in slice
  state.

  Phase 3d落地 Decision #24 (Identity Behavior 标准化):

  Every Entity Kind (User / Agent) carries an `:identity` slice with
  `caps :: MapSet.t(Ezagent.Capability.t())`. At dispatch step 5.5,
  `Ezagent.Kind.Runtime` reads the **caller**'s caps from the dispatch
  ctx (which adapters populated from `Ezagent.ActionSet.Identity.list_caps`
  call on the caller Kind) and matches against the needed cap.

  ## Why caps live in slice (not module-level constant)

  Phase 1-2 admin caps came from `Ezagent.Entity.User.admin_caps/0`
  (deleted in PR-CC-1 — replaced by `Ezagent.SystemPrincipal.caps/1`
  reading the closed Catalog). Phase 3d puts them in **runtime slice**
  so:
  - the public Kind runtime view exposes the live caps (debuggable)
  - Phase 4+ admin grants new cap → mutate slice, not redeploy code
  - Agent Kinds also carry caps (different per agent), same shape

  ## State

      %{caps: MapSet.t(Ezagent.Capability.t())}

  `init_slice(args)` reads `args[:initial_caps]` (default `MapSet.new()`).
  Chat plugin Application passes
  an initial capability set when
  spawning admin User (PR-CC-1; replaces the previous deleted helper).

  ## Actions

  - `:list_caps` — `%{caps: [Capability.t()]}`
  - `:has_cap?` — args `%{cap: needed}` → `%{has: boolean}`
    where `needed = %{kind, behavior, instance}` shape per
    `Ezagent.Capability.matches?/2`.

  Both are `:call` mode — adapters need the return value.

  ## P2-b migration (2026-05-28)

  Migrated to the new `use Ezagent.ActionSet` action/handler contract
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
  # `Ezagent.ActionSet.IdentityAdmin` (below in this file).
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

  # Membership-cap unification Phase B.3 (spec §10 / K3) — the post-commit
  # cascade sink. `Kind.Server` synthesizes this self-targeted, fire-and-forget
  # dispatch at the SINGLE emit chokepoint for an allowlisted `{scheme,
  # slice_key}` (initially `{entity, :identity}` — a cap grant/revoke mutates the
  # `:identity` slice). The handler resolves the entity's managers/owners and
  # notifies them content-free. It is **cap-exempt** (`cap_exempt_actions/0`
  # below): a VM-internal advisory dispatch under the same in-VM-trust model as
  # `Ezagent.Notifications.notify/2`, mirroring the `:receive` cap-exempt
  # precedent (A2). Read-only (no slice mutation) so it never re-triggers itself.
  action(:cascade_notify_managers,
    args: %{},
    returns: %{},
    caps: [{:cascade_notify_managers, kind: :any}],
    description:
      "Post-commit cascade: content-free notify of this entity's managers/owners on an allowlisted slice change",
    modes: [:cast]
  )

  @doc """
  Membership-cap B.3 cap-exempt actions: the cascade sink is authorized in-VM
  (self-dispatched at the emit chokepoint), NOT via a caller-scoped cap — the
  `:receive` precedent. Keeps `keys(required_caps) ∪ cap_exempt_actions ==
  actions` (the `Ezagent.ActionSet` behaviour-contract parity check).
  """
  def cap_exempt_actions, do: [:cascade_notify_managers]

  # =================================================================
  # Explicit `required_caps/0` — preserved as `kind: :any` (Identity
  # is registered on multiple Kinds; see check 11(b) escape in
  # `Ezagent.ActionSet` callback contract). The auto-derived macro
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

    {caps, recipe_binding} =
      case Map.get(args, :uri) do
        %URI{} = uri ->
          hydrate_recipe_binding(caps, uri)

        _ ->
          {caps, :none}
      end

    caps = Ezagent.Cap.verified_set(caps, Map.get(args, :uri))

    with {:ok, caps} <- maybe_mint_self_license(caps, args) do
      caps = maybe_reread_durable_self_license(caps, args)

      state =
        case recipe_binding do
          {:active, version, keys} ->
            %{caps: caps, recipe_binding_version: version, recipe_binding_keys: keys}

          :none ->
            %{caps: caps}
        end

      {:ok, state}
    end
  end

  defp maybe_mint_self_license(caps, %{create_freshness: :created, uri: %URI{} = uri}) do
    if Enum.any?(caps, &(Ezagent.Capability.action_of(&1) == :self_license)) do
      {:error, :self_license_already_present}
    else
      mint_self_license(caps, uri)
    end
  end

  defp maybe_mint_self_license(caps, _args), do: {:ok, caps}

  @doc false
  # The SINGLE sanctioned self-license constructor for the Identity carrier (Z-1
  # construction ratchet: exactly this file + `self_license.ex`). Mints under the
  # in-scope authority, so it is valid only inside the principal's own compartment:
  # `create/1` and the pre-ready `activate/2` continuation (the latter via the
  # gated `Ezagent.Identity.PreEpochRemint`) both run under `Kind.Server`'s
  # `with_authority`.
  @spec mint_self_license(Enumerable.t(), URI.t()) :: {:ok, MapSet.t()} | {:error, term()}
  def mint_self_license(caps, %URI{} = uri) do
    with {:ok, type} <- Ezagent.URI.type(uri),
         kind <- String.to_existing_atom(type),
         requested <-
           Ezagent.Capability.cap(
             kind,
             __MODULE__,
             :self_license,
             uri,
             Ezagent.URI.workspace_of(uri)
           ),
         intent <- Ezagent.Cap.Grant.freeze(uri, uri, uri, requested),
         {:ok, license} <- Ezagent.Cap.Authority.issue_self_license_current(intent),
         licensed <- MapSet.put(caps, license) do
      {:ok, licensed}
    end
  end

  # #189 PR-3 cutover (Axis B — "re-read on restart", NEVER re-mint). A
  # NON-snapshot (`:ephemeral`) principal (the ExternalMirrorWorker) rebuilds an
  # EMPTY `:identity` slice on restart — no snapshot to load, and no mint on
  # `:existed` — so re-read its DURABLE self-license (written once at `:created`)
  # from the store INTO the live slice. Needed for the LIVE NON-self read path: a
  # worker authorized inside the SESSION's process during `subscribe_from`
  # (`Kind.self?(worker_uri)` false → live-first loader reads the worker's LIVE
  # slice, not the store), which would otherwise find an empty slice and deny
  # (`:holder_revoked`) on rehydrate/resubscribe. `Store.load/1` yields caps ONLY
  # for an `active` row (revoked/tombstoned/absent → `[]`) and the union is
  # gen-gated by the loader's `verified/2` on every read, so a revoked /
  # gen-bumped principal still loads EMPTY (no resurrection). Only reached for a
  # non-snapshot principal (a durable Kind loads its snapshot slice + runs
  # `activate/2`, so its `create/1` isn't called on `:existed`).
  defp maybe_reread_durable_self_license(caps, %{create_freshness: :existed, uri: %URI{} = uri}) do
    uri
    |> Ezagent.EntityCaps.Store.load()
    |> Enum.find(&(Ezagent.Capability.action_of(&1) == :self_license))
    |> case do
      %Ezagent.Capability{} = license -> MapSet.put(caps, license)
      _ -> caps
    end
  end

  defp maybe_reread_durable_self_license(caps, _args), do: caps

  defp hydrate_recipe_binding(caps, %URI{} = uri) do
    if Ezagent.URI.type?(uri, :agent) do
      case Ezagent.Identity.RecipeCapBinding.fetch(uri) do
        {:ok, %{caps: binding_caps, version: version}} ->
          keys = cap_identity_keys(binding_caps)
          {merge_caps_by_identity(caps, binding_caps), {:active, version, keys}}

        :not_found ->
          {caps, :none}

        {:error, reason} ->
          raise "recipe cap binding read failed for #{inspect(uri)}: #{inspect(reason)}"
      end
    else
      {caps, :none}
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
  def activate(%{caps: _existing_caps} = state, %{self_uri: %URI{scheme: "entity"} = uri}) do
    original_state = state

    user_caps =
      if Ezagent.URI.type?(uri, :user), do: Ezagent.EntityCaps.UserStore.load(uri), else: []

    state = Map.update!(state, :caps, &merge_caps_by_identity(&1, user_caps))

    # Canary boot regression (deploy 30456630379): PRE-EPOCH restore the genesis
    # admin's stale/absent self-license so the §3 boot seed authorizes. The
    # security-sensitive, resurrection-proof eligibility predicate lives in
    # `Ezagent.Identity.PreEpochRemint` (a no-op post-epoch / for every non-admin);
    # BEFORE `persist_user_caps_after_marker` so it rides the fail-closed projection.
    state = Ezagent.Identity.PreEpochRemint.remint(state, uri)

    with :ok <- persist_user_caps_after_marker(uri, state.caps),
         {:ok, reconciled} <- reconcile_recipe_binding_state(state, uri) do
      :ok =
        Ezagent.Identity.MembershipConvergence.converge(
          uri,
          MapSet.to_list(reconciled.caps)
        )

      if reconciled == original_state do
        {:ok, %{}}
      else
        {:ok, %{}, reconciled}
      end
    end
  end

  def activate(_state, _ctx), do: {:ok, %{}}

  # `activate/2` runs only after Kind.Server has atomically stored the initial
  # snapshot together with `ever_created`. Keeping the user projection write
  # here prevents a crash between `create/1` and that marker-bearing commit
  # from leaving a self-license that a later retry cannot safely mint.
  defp persist_user_caps_after_marker(uri, caps) do
    if Ezagent.URI.type?(uri, :user) and Ezagent.EntityCaps.UserStore.exists?(uri) do
      Ezagent.EntityCaps.UserStore.persist(uri, MapSet.to_list(caps))
    else
      :ok
    end
  end

  @doc false
  @spec reconcile_recipe_binding_state(map(), URI.t()) :: {:ok, map()} | {:error, term()}
  def reconcile_recipe_binding_state(%{caps: _caps} = state, %URI{} = uri) do
    with {:ok, base_state, binding_caps, binding_update} <-
           reconcile_recipe_binding(state, uri) do
      merged = merge_caps_by_identity(base_state.caps, binding_caps)
      verified_caps = Ezagent.Cap.verified_set(merged, uri)

      {:ok,
       base_state
       |> Map.put(:caps, verified_caps)
       |> apply_recipe_binding_update(binding_update)}
    end
  end

  defp reconcile_recipe_binding(state, %URI{} = uri) do
    if Ezagent.URI.type?(uri, :agent) do
      old_keys = Map.get(state, :recipe_binding_keys, MapSet.new())
      old_version = Map.get(state, :recipe_binding_version)

      case Ezagent.Identity.RecipeCapBinding.fetch(uri) do
        {:ok, %{version: ^old_version}} ->
          # Same binding version means no recipe-cap replay. A cap deliberately
          # revoked from the live slice therefore stays revoked across restart.
          {:ok, state, [], :unchanged}

        {:ok, %{caps: caps, version: version}} ->
          base_state = restore_structural_caps(state, uri, old_keys)
          {:ok, base_state, caps, {:active, version, cap_identity_keys(caps)}}

        :not_found ->
          if MapSet.size(old_keys) == 0 do
            {:ok, state, [], :unchanged}
          else
            base_state = restore_structural_caps(state, uri, old_keys)
            {:ok, base_state, [], :cleared}
          end

        {:error, reason} ->
          {:error, {:recipe_cap_binding_read_failed, reason}}
      end
    else
      {:ok, state, [], :unchanged}
    end
  end

  defp apply_recipe_binding_update(state, :unchanged), do: state

  defp apply_recipe_binding_update(state, {:active, version, keys}) do
    state
    |> Map.put(:recipe_binding_version, version)
    |> Map.put(:recipe_binding_keys, keys)
  end

  defp apply_recipe_binding_update(state, :cleared) do
    state
    |> Map.delete(:recipe_binding_version)
    |> Map.delete(:recipe_binding_keys)
  end

  defp drop_caps_by_keys(caps, keys) do
    caps
    |> Enum.reject(&(Ezagent.Capability.identity_key(&1) in keys))
    |> MapSet.new()
  end

  defp restore_structural_caps(state, _uri, old_binding_keys) do
    caps =
      state.caps
      |> drop_caps_by_keys(old_binding_keys)

    Map.put(state, :caps, caps)
  end

  defp cap_identity_keys(caps) do
    caps
    |> Enum.map(&Ezagent.Capability.identity_key/1)
    |> MapSet.new()
  end

  defp merge_caps_by_identity(current, incoming) do
    incoming = MapSet.new(incoming)
    incoming_keys = cap_identity_keys(incoming)

    current
    |> drop_caps_by_keys(incoming_keys)
    |> MapSet.union(incoming)
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

  @doc """
  Membership-cap B.3 cascade sink (spec §10 / K3). Resolve this entity's
  managers/owners and notify them content-free of the slice change. Read-only
  (emits NO effects → no re-trigger); best-effort inside `Cascade` (a failed
  cascade is advisory and MUST NOT crash the post-commit turn).

  ## Provenance gate (#161 Phase B, codex MED)

  This action is `cap_exempt` AND production-reachable via
  `POST /api/v1/:kind/:action`. Left ungated, an authenticated same-workspace
  caller could invoke it directly to trigger a managers-scan + advisory
  "caps changed" notify (notify-spam / false-signal vector). It is ONLY ever
  meant to be self-dispatched by `Ezagent.Kind.CascadeHook` at the emit
  chokepoint, which sets `ctx.caller = :vm_internal` — the trusted in-VM caller
  marker (#154 VM-internal-trust). We proceed ONLY for that internal
  provenance; any other caller is rejected with `{:error, :unauthorized}`
  (no managers-scan, no notify — a clean reject, never a crash).

  Why an external caller cannot forge it: `ctx.caller` is set by the transport,
  NOT by user-supplied args. The `/api/v1` controller resolves it from the
  bearer token (`resolve_caller/1`) to the authenticated entity's `%URI{}` — it
  is never the atom `:vm_internal`. `:vm_internal` trusts all in-VM code (per
  #154, that is the model), and `CascadeHook` is the sole in-VM producer of this
  action; the security property the gate guarantees is that an EXTERNAL caller
  can never present `:vm_internal`. Mirrors the `:receive` cap-exempt-then-
  in-handler-check precedent (A2).
  """
  def handle_cascade_notify_managers(args, %{caller: :vm_internal} = ctx) do
    Ezagent.Identity.Cascade.notify_managers(Map.get(ctx, :self_uri), args)
    {:ok, %{}, []}
  end

  def handle_cascade_notify_managers(_args, _ctx), do: {:error, :unauthorized}
end

defmodule Ezagent.ActionSet.IdentityAdmin do
  @moduledoc """
  IdentityAdmin Behavior — privileged cap mutation actions on a
  principal's `:identity` slice.

  PR-OWN-3 (caps-data-ownership SPEC #306 §7) split-out from
  `Ezagent.ActionSet.Identity`. Reasoning (codex PR-OWN-1 round-1 MED
  + SPEC §1 reframe): caps are behavior-scoped, so a single Identity
  Behavior cap would have collapsed safe (`:list_caps`, `:has_cap?`)
  and privileged (`:grant_cap`, `:revoke_cap`) actions into one
  grant surface — letting users self-mutate their own caps.

  This Behavior holds ONLY the privileged actions; `Identity` keeps
  the safe ones. `data_owner/1` returns `:no_owner` here so the
  §5.2 gate routes IdentityAdmin grants only through the bootstrap
  admin path.

  Shares the `:identity` slice with `Ezagent.ActionSet.Identity` (both
  Behaviors registered against User + Agent Kinds).

  ## P2-b migration (2026-05-28)

  Migrated to the new `use Ezagent.ActionSet` action/handler contract
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
  `Ezagent.ActionSet.Identity` (the caps `MapSet`); no transients. Because
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

  action(:absorb_cap,
    args: %{artifact: :map},
    returns: %{caps: {:list, :map}},
    caps: [{:absorb_cap, kind: :user, workspace_scoped?: false}],
    description: "store a pre-issued capability in this principal's own caps slice",
    modes: [:cast]
  )

  action(:persist_caps,
    args: %{caps: {:list, :map}},
    returns: %{caps: {:list, :map}},
    caps: [{:persist_caps, kind: :user, workspace_scoped?: false}],
    description: "replace the complete verified capability set in the entity's physical store",
    modes: [:call]
  )

  action(:store_cap,
    args: %{cap: :map},
    returns: %{caps: {:list, :map}},
    caps: [{:store_cap, kind: :user, workspace_scoped?: false}],
    description: "atomically store one verified cap artifact",
    modes: [:call]
  )

  action(:remove_cap,
    args: %{cap: :map},
    returns: %{caps: {:list, :map}},
    caps: [{:remove_cap, kind: :user, workspace_scoped?: false}],
    description: "atomically remove one cap identity",
    modes: [:call]
  )

  action(:sync_recipe_binding,
    args: %{},
    returns: %{caps: {:list, :map}},
    caps: [{:sync_recipe_binding, kind: :user, workspace_scoped?: false}],
    description: "reconcile the live agent identity slice from its durable signed recipe binding",
    modes: [:call]
  )

  @doc "VM-internal self-store is provenance-gated in the handler, not by a held cap."
  def cap_exempt_actions,
    do: [:absorb_cap, :persist_caps, :store_cap, :remove_cap, :sync_recipe_binding]

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
    Ezagent.ActionSet.Identity.create(args)
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
  Store a capability artifact already authorized by `Ezagent.Cap.issue/3`.

  Normalizes the incoming `cap` (struct / atom-keyed / string-keyed → canonical
  struct), dedups by identity-key, writes the `:caps` slice, notifies the
  principal, and emits `:cap_granted`. It deliberately performs no grantor
  authorization; the single authorization home is `Ezagent.Cap.issue/3`.
  """
  def handle_grant_cap(%{cap: cap}, ctx) do
    cap_struct = Ezagent.Capability.normalize!(cap, granter_from_ctx(ctx))

    store_verified_cap(cap_struct, ctx, %{
      via_manage: manager_delegated_grant?(cap_struct, ctx)
    })
  end

  @doc "Store a verified pre-issued artifact; only the VM-internal hand-off may call it."
  def handle_absorb_cap(%{artifact: artifact}, %{caller: :vm_internal} = ctx) do
    with {:ok, cap_struct} <- normalize_artifact(artifact) do
      store_verified_cap(cap_struct, ctx, %{via_manage: false, via_absorb: true})
    else
      _ -> {:error, :invalid_cap_artifact}
    end
  end

  def handle_absorb_cap(_args, _ctx), do: {:error, :unauthorized}

  @doc "VM-internal storage action used by `Ezagent.EntityCaps.persist/2` for a live entity."
  def handle_persist_caps(%{caps: caps}, %{caller: :vm_internal} = ctx) when is_list(caps) do
    receiver = Map.get(ctx, :self_uri)

    with :ok <- Ezagent.EntityCaps.validate_issued_caps(caps, receiver),
         {:ok, persistable} <- Ezagent.EntityCaps.prepare_for_storage(caps, receiver, true) do
      new_caps = MapSet.new(persistable)

      with :ok <- persist_entity_caps(receiver, new_caps) do
        {:ok, %{caps: MapSet.to_list(new_caps)},
         [set_caps_effect(new_caps)] ++ membership_convergence_effects(receiver, new_caps)}
      end
    else
      {:error, _reason} ->
        {:error, :invalid_cap_artifact}
    end
  end

  def handle_persist_caps(_args, _ctx), do: {:error, :unauthorized}

  @doc "VM-internal atomic single-artifact storage used by `Ezagent.EntityCaps.grant/2`."
  def handle_store_cap(%{cap: %Ezagent.Capability{} = cap}, %{caller: :vm_internal} = ctx) do
    receiver = Map.get(ctx, :self_uri)
    updated = replace_cap(ctx[:read].(:caps, MapSet.new()), cap)

    with :ok <- Ezagent.EntityCaps.validate_issued_caps([cap], receiver),
         {:ok, persistable} <- Ezagent.EntityCaps.prepare_for_storage(updated, receiver, true) do
      new_caps = MapSet.new(persistable)

      with :ok <- persist_entity_caps(receiver, new_caps) do
        {:ok, %{caps: MapSet.to_list(new_caps)},
         [set_caps_effect(new_caps)] ++ membership_convergence_effects(receiver, [cap])}
      end
    end
  end

  def handle_store_cap(_args, _ctx), do: {:error, :unauthorized}

  @doc "VM-internal atomic single-artifact removal used by `Ezagent.EntityCaps.revoke/2`."
  def handle_remove_cap(%{cap: %Ezagent.Capability{} = cap}, %{caller: :vm_internal} = ctx) do
    current_caps = ctx[:read].(:caps, MapSet.new())
    receiver = Map.get(ctx, :self_uri)

    with {:ok, resolved} <- Ezagent.EntityCaps.Store.revoke_cap(receiver, cap),
         {:ok, updated} <- Ezagent.Capability.revoke(current_caps, resolved),
         {:ok, persistable} <-
           Ezagent.EntityCaps.prepare_for_storage(updated, receiver, true) do
      new_caps = MapSet.new(persistable)

      with :ok <- persist_entity_caps(receiver, new_caps) do
        {:ok, %{caps: MapSet.to_list(new_caps)}, [set_caps_effect(new_caps)]}
      end
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_remove_cap(_args, _ctx), do: {:error, :unauthorized}

  @doc "VM-internal reconcile after a live target has signed its recipe grants."
  def handle_sync_recipe_binding(_args, %{caller: :vm_internal} = ctx) do
    receiver = Map.get(ctx, :self_uri)

    state = %{
      caps: ctx[:read].(:caps, MapSet.new()),
      recipe_binding_version: ctx[:read].(:recipe_binding_version, nil),
      recipe_binding_keys: ctx[:read].(:recipe_binding_keys, MapSet.new())
    }

    with true <- Ezagent.URI.type?(receiver, :agent),
         {:ok, reconciled} <-
           Ezagent.ActionSet.Identity.reconcile_recipe_binding_state(state, receiver),
         version when is_integer(version) <- Map.get(reconciled, :recipe_binding_version),
         %MapSet{} = keys <- Map.get(reconciled, :recipe_binding_keys) do
      {:ok, %{caps: MapSet.to_list(reconciled.caps)},
       [
         set_caps_effect(reconciled.caps),
         {:set, :recipe_binding_version, version},
         {:set, :recipe_binding_keys, keys}
       ] ++ membership_convergence_effects(receiver, reconciled.caps)}
    else
      false -> {:error, :agent_required}
      nil -> {:error, :recipe_binding_not_found}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_recipe_binding_state}
    end
  end

  def handle_sync_recipe_binding(_args, _ctx), do: {:error, :unauthorized}

  defp store_verified_cap(cap_struct, ctx, event_attrs) do
    if Ezagent.Cap.storable_for?(cap_struct, Map.get(ctx, :self_uri)) do
      current_caps = ctx[:read].(:caps, MapSet.new())

      # Dedup by identity-tuple BEFORE adding (codex review HIGH-1
      # follow-on for both grant and absorb store paths).
      deduped =
        current_caps
        |> Enum.reject(fn held ->
          Ezagent.Capability.identity_key(held) == Ezagent.Capability.identity_key(cap_struct)
        end)
        |> MapSet.new()

      new_caps = MapSet.put(deduped, cap_struct)
      receiver = Map.get(ctx, :self_uri)

      # User authority is physically projected in `users.caps_json`, whereas
      # non-user identities are snapshot-backed. Persist the user projection
      # before scheduling holder-driven convergence so `add_self`'s independent
      # durable read can observe the committed grant. The VM-internal
      # `store_cap` path already has this ordering; absorb/grant must match it.
      with :ok <- persist_entity_caps(receiver, new_caps) do
        notify_cap_change(ctx, :cap_granted, "A new capability was granted to you.", cap_struct)

        payload =
          %{
            target_uri: receiver |> uri_to_str(),
            cap: cap_struct,
            at: DateTime.utc_now()
          }
          |> Map.merge(event_attrs)

        {:ok, %{caps: MapSet.to_list(new_caps)},
         [
           set_caps_effect(new_caps),
           {:emit, :cap_granted, payload}
         ] ++ membership_convergence_effects(receiver, [cap_struct])}
      end
    else
      {:error, :invalid_cap_artifact}
    end
  end

  defp membership_convergence_effects(receiver, caps) do
    Ezagent.Identity.MembershipConvergence.after_commit_effects(receiver, caps)
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
    receiver = Map.get(ctx, :self_uri)

    with {:ok, resolved} <- Ezagent.EntityCaps.Store.revoke_cap(receiver, cap_struct),
         {:ok, new_caps} <- Ezagent.Capability.revoke(current_caps, resolved) do
      notify_cap_change(
        ctx,
        :cap_revoked,
        "A capability was revoked from you.",
        resolved
      )

      {:ok, %{caps: MapSet.to_list(new_caps)},
       [
         set_caps_effect(new_caps),
         {:emit, :cap_revoked,
          %{
            target_uri: receiver |> uri_to_str(),
            cap: resolved,
            at: DateTime.utc_now()
          }}
       ]}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp uri_to_str(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_str(other), do: inspect(other)

  defp persist_entity_caps(%URI{} = uri, caps) do
    if Ezagent.URI.type?(uri, :user) and Ezagent.EntityCaps.UserStore.exists?(uri) do
      Ezagent.EntityCaps.UserStore.persist(uri, MapSet.to_list(caps))
    else
      :ok
    end
  end

  defp persist_entity_caps(_uri, _caps), do: :ok

  defp replace_cap(caps, cap) do
    caps
    |> Enum.reject(&(Ezagent.Capability.identity_key(&1) == Ezagent.Capability.identity_key(cap)))
    |> MapSet.new()
    |> MapSet.put(cap)
  end

  # I7: every runtime caps replacement is visible at this one literal writer.
  # Each caller has already either verified the complete set/artifact or proven
  # that the mutation is removal-only.
  defp set_caps_effect(caps), do: {:set, :caps, caps}

  defp normalize_artifact(%Ezagent.Capability{} = artifact), do: {:ok, artifact}

  defp normalize_artifact(%{} = artifact) do
    try do
      {:ok, Ezagent.Capability.from_map(artifact)}
    rescue
      _ -> {:error, :invalid}
    end
  end

  defp normalize_artifact(_artifact), do: {:error, :invalid}

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

  @doc """
  Structural bound a `{:rule, …}` grant must satisfy (SPEC 2026-06-17 §3.3).

  A rule may NOT mint `kind: :any` / `behavior: :any`; and an
  `action: :any` cap is allowed ONLY when the instance is scope-bounded
  (`{:within_session/within_workspace/spawned_by, %URI{}}`) — a concrete
  `%URI{}` instance is allowed only with a concrete action.

  The implementation lives in core beside `Cap.issue/3`; this public delegate
  is retained for compatibility with existing callers and tests.
  """
  @spec rule_cap_bounded?(Ezagent.Capability.t()) :: boolean()
  defdelegate rule_cap_bounded?(cap), to: Ezagent.CapabilityRegistry

  # SPEC 2026-06-16 §4 (Decision #88) — manager-provenance predicate for the
  # `:cap_granted` audit emit. True iff the grant was authorized via the NEW
  # manager branch: the cap resolves to a concrete `%URI{}` data-owner, the
  # caller is NOT that owner, NOT bootstrap-admin, but DOES hold a Manage cap
  # over the target AND the cap is delegable. Mirrors the
  # core issue-time manager branch exactly so provenance cannot diverge from
  # the authorization decision (self/admin/non-manager → false).
  defp manager_delegated_grant?(%Ezagent.Capability{behavior: behavior, instance: instance}, ctx)
       when is_atom(behavior) do
    if Code.ensure_loaded?(behavior) and function_exported?(behavior, :data_owner, 1) do
      case Ezagent.ActionSet.data_owner_of(behavior, instance) do
        %URI{} = owner ->
          Map.get(ctx, :caller) != owner and
            not holds_admin_caps?(ctx) and
            manages_target?(ctx, instance)

        _ ->
          false
      end
    else
      false
    end
  end

  defp manager_delegated_grant?(_cap, _ctx), do: false

  # SPEC 2026-06-16 §1 (Decision #88) — "caller holds Manage over target".
  # Delegates to the extracted single-source predicate
  # `Ezagent.Identity.Authority.holds_manage_over_target?/2` (membership-cap B.1 /
  # K2), reading the caller's dispatch caps (`ctx.caps`). The URI-based
  # `Authority.manages?/2` (durable identity caps) is the cascade/admission twin;
  # both share the ONE predicate so a security boundary never drifts.
  defp manages_target?(ctx, instance) do
    ctx
    |> caller_caps()
    |> Ezagent.Identity.Authority.holds_manage_over_target?(instance)
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
        behavior: Ezagent.ActionSet.Workspace,
        action: :any,
        instance: :any,
        workspace_uri: :any
      } ->
        true

      _ ->
        false
    end)
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
