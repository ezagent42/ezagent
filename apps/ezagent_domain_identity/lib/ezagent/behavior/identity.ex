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

  @impl Ezagent.Behavior
  def actions, do: [:list_caps, :has_cap?, :grant_cap, :revoke_cap]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:list_caps, "list all capabilities currently granted to this principal"},
      {:has_cap?, "test whether this principal holds a specific capability shape"},
      {:grant_cap, "grant a new capability to this principal (caller must hold admin cap)"},
      {:revoke_cap, "revoke a capability from this principal (caller must hold admin cap)"}
    ]
  end

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

  # Phase 6 PR 6: live cap mutation via behavior action.
  #
  # PR-OWN-2 (caps-data-ownership SPEC #306 §5.2) adds a §5.2
  # structural pre-check: for caps whose Behavior declares
  # `data_owner/1` (i.e. has migrated to the new framework), the
  # caller MUST be the data owner OR hold a recorded delegation cap
  # — even if the dispatch-level CapBAC allowed them through with
  # an admin cap. Behaviors that have NOT migrated keep the old
  # admin-cap dispatch gate as the only check (incremental rollout
  # per SPEC §7 PR-OWN-2 — Identity is not yet migrated as of this
  # PR; PR-OWN-3 migrates it).
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

  # Notifier/flash audit 2026-05-24 — surface cap changes to the
  # affected user. The :self_uri ctx field is the URI whose Identity
  # slice we're mutating (i.e. the target principal). User-only —
  # agents don't have an inbox.
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
      },
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
