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

  # Phase 6 PR 6: live cap mutation via behavior action. The CapBAC
  # gate at dispatch step 5.5 enforces that only callers with admin
  # caps can grant — so the action itself stays unconditional and
  # trusts the dispatch-level check.
  def invoke(:grant_cap, slice, %{cap: cap}, _ctx) do
    new_slice = %{slice | caps: MapSet.put(slice.caps, cap)}
    {:ok, new_slice, %{caps: MapSet.to_list(new_slice.caps)}}
  end

  def invoke(:revoke_cap, slice, %{cap: cap}, _ctx) do
    new_slice = %{slice | caps: MapSet.delete(slice.caps, cap)}
    {:ok, new_slice, %{caps: MapSet.to_list(new_slice.caps)}}
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
end
