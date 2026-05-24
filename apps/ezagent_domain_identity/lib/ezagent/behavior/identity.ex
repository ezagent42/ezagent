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

  Phase 1-2 admin caps came from `Ezagent.Entity.User.admin_caps/0` —
  hardcoded module function. Phase 3d puts them in **runtime slice**
  so:
  - `:sys.get_state(admin_user_pid)` exposes the live caps (debuggable)
  - Phase 4+ admin grants new cap → mutate slice, not redeploy code
  - Agent Kinds also carry caps (different per agent), same shape

  ## State

      %{caps: MapSet.t(Ezagent.Capability.t())}

  `init_slice(args)` reads `args[:initial_caps]` (default `MapSet.new()`).
  Chat plugin Application passes `initial_caps: User.admin_caps()` when
  spawning admin User.

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

    %{caps: caps}
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
      _ =
        Ezagent.Notifications.notify(target_uri, %{
          kind: kind,
          text: text,
          cap_summary: inspect(cap)
        })
    end

    :ok
  end

  # PR-OWN-2 §5.2 enforcement helpers — called from `invoke(:grant_cap,...)`.
  # Three branches:
  #   (1) wildcard cap shape — {kind: :any} or {behavior: :any} —
  #       only the bootstrap admin can grant. Rejects with
  #       :grant_wildcard_requires_admin otherwise.
  #   (2) cap's Behavior declares data_owner/1 — caller must be
  #       the data owner. Rejects with :grant_not_owner otherwise.
  #   (3) cap's Behavior has NOT migrated — fall through to :ok
  #       (incremental rollout; dispatch-level CapBAC remains the
  #       only check).
  defp check_grant_authorized(%Ezagent.Capability{kind: :any}, ctx),
    do: require_bootstrap_admin(ctx, :grant_wildcard_requires_admin)

  defp check_grant_authorized(%Ezagent.Capability{behavior: :any}, ctx),
    do: require_bootstrap_admin(ctx, :grant_wildcard_requires_admin)

  defp check_grant_authorized(
         %Ezagent.Capability{behavior: behavior, instance: instance},
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

        # :any / :no_owner / {:scope, _, _} — class-wide or
        # ownerless. Only bootstrap admin can grant; same as
        # wildcard caps above.
        _ ->
          require_bootstrap_admin(ctx, :grant_owner_unresolvable)
      end
    else
      # Behavior not yet migrated — incremental rollout fallthrough.
      :ok
    end
  end

  defp check_grant_authorized(_cap, _ctx), do: :ok

  # Bootstrap admin holds at least one cap with `behavior: :any` AND
  # `workspace_uri: :any`. This is the only legitimate granter for
  # wildcard or ownerless caps. Existing `User.admin_caps/1` mints
  # exactly this shape.
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
  # The bootstrap admin's `User.admin_caps()` mints exactly the
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
