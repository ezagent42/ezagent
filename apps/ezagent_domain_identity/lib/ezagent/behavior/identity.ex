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
  """

  use Ezagent.Behavior

  # PR-OWN-3 (caps-data-ownership SPEC #306 §7): SPLIT — Identity
  # keeps only the safe read actions (`:list_caps`, `:has_cap?`).
  # Privileged write actions (`:grant_cap`, `:revoke_cap`) live on
  # `Ezagent.Behavior.IdentityAdmin` (below in this file).
  action :list_caps,
    args: %{},
    returns: %{caps: {:list, :map}},
    caps: [{:list_caps, kind: :any}],
    description: "List the principal's capability set",
    modes: [:call]

  action :has_cap?,
    args: %{cap: :map},
    returns: %{has: :boolean},
    caps: [{:has_cap?, kind: :any}],
    description: "Check whether the principal holds a capability matching the needed shape",
    modes: [:call]

  # =================================================================
  # Explicit `required_caps/0` — preserved as `kind: :any` (Identity
  # is registered on multiple Kinds; see check 11(b) escape in
  # `Ezagent.Behavior` callback contract). The auto-derived macro
  # version also produces `:any` so this override is technically a
  # no-op, but kept explicit for parity with the pre-migration shape.
  # =================================================================
  def required_caps do
    %{
      list_caps: Ezagent.Capability.cap(:any, __MODULE__, :list_caps),
      has_cap?: Ezagent.Capability.cap(:any, __MODULE__, :has_cap?)
    }
  end

  # =================================================================
  # Slice machinery (legacy callbacks; §6.2 step 9)
  # =================================================================

  def state_slice, do: :identity

  def init_slice(args) do
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
      Ezagent.URI.parse!("system://bootstrap/pr-own-3")
    end
  end

  # PR-OWN-3 SPEC #306 §3.3: data_owner for Identity is the
  # entity itself.
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # Post-init reconciliation: re-merge caps from `users.caps_json` into
  # the just-loaded `:identity` slice. See pre-migration moduledoc for
  # full rationale.
  def post_init(%{uri: %URI{scheme: "entity", host: "user"} = uri}, _slice),
    do: {:continue, {:reconcile_caps_json, uri}}

  def post_init(_args, _slice), do: :ok

  def handle_continue({:reconcile_caps_json, %URI{} = uri}, slice, _ctx) do
    case caps_from_caps_json(uri) do
      [] ->
        :ignore

      caps_list when is_list(caps_list) ->
        caps_from_json = MapSet.new(caps_list)
        existing_caps = Map.get(slice, :caps, MapSet.new())
        merged = MapSet.union(existing_caps, caps_from_json)

        if MapSet.size(merged) == MapSet.size(existing_caps) do
          :ignore
        else
          {:ok, %{slice | caps: merged}}
        end
    end
  end

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

  def handle_list_caps(_args, ctx) do
    caps = ctx[:read].(:caps, MapSet.new())
    {:ok, %{caps: MapSet.to_list(caps)}, []}
  end

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
  """

  use Ezagent.Behavior

  action :grant_cap,
    args: %{cap: :map},
    returns: %{caps: {:list, :map}},
    caps: [{:grant_cap, kind: :user, workspace_scoped?: false}],
    description: "grant a new capability to this principal (admin)",
    modes: [:call]

  action :revoke_cap,
    args: %{cap: :map},
    returns: %{caps: {:list, :map}},
    caps: [{:revoke_cap, kind: :user, workspace_scoped?: false}],
    description: "revoke a capability from this principal (admin)",
    modes: [:call]

  # =================================================================
  # Explicit `required_caps/0` — preserved `kind: :user` axis.
  # =================================================================
  def required_caps do
    %{
      grant_cap: Ezagent.Capability.cap(:user, __MODULE__, :grant_cap),
      revoke_cap: Ezagent.Capability.cap(:user, __MODULE__, :revoke_cap)
    }
  end

  # workspace_scoped? = false: admin grant/revoke routinely crosses
  # workspaces.
  def workspace_scoped?, do: false

  # =================================================================
  # Slice machinery (legacy callbacks; §6.2 step 9)
  # =================================================================

  def state_slice, do: :identity

  def init_slice(args) do
    # Defer to Identity for slice init shape — both Behaviors share it.
    Ezagent.Behavior.Identity.init_slice(args)
  end

  # PR-OWN-3: data_owner = :no_owner.
  def data_owner(_), do: :no_owner

  # =================================================================
  # New-contract action handlers (§6.2 — replace invoke/4)
  # =================================================================

  # Bug 2 fix (Allen 2026-05-26) — `cap` arrives as one of three
  # shapes (struct / atom-keyed map / string-keyed map). `normalize!`
  # coerces all three to the canonical struct.
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

      {:ok, %{caps: MapSet.to_list(new_caps)},
       [
         {:set, :caps, new_caps},
         {:emit, :cap_granted,
          %{
            target_uri: Map.get(ctx, :self_uri) |> uri_to_str(),
            cap: cap_struct,
            at: DateTime.utc_now()
          }}
       ]}
    end
  end

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
      Ezagent.URI.parse!("system://bootstrap/grant_cap")
    end
  end

  defp notify_cap_change(ctx, kind, text, cap) do
    target_uri = Map.get(ctx, :self_uri)

    if match?(%URI{scheme: "entity", host: "user"}, target_uri) do
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

  # PR-OWN-2 §5.2 enforcement helpers — called from `handle_grant_cap/2`.
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
