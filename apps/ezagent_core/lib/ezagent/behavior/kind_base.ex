defmodule Ezagent.ActionSet.KindBase do
  @moduledoc """
  Base behavior present on every session instance under the unified
  socialware substrate. Its persistent `:kind_base` slice records the
  list of Behavior modules THIS INSTANCE was spawned with, so the runtime
  can scope every behavior enumeration + callback entry point to the
  instance's set (not the host Kind module's static superset).

  Data-only: it declares no actions. The captured set is read via
  `behaviors_in_slice/1` by `Ezagent.Kind.BehaviorSet.effective_set/2`.

  ## Legacy sentinel (codex CRITICAL)

  The captured value distinguishes two cases that MUST NOT collapse:

    * `:behaviors` ABSENT from spawn args → a legacy static Kind. We persist
      the sentinel `nil`, which `effective_set/2` expands to the FULL declared
      list (today's two static Kinds, unchanged).
    * `:behaviors` PRESENT (a list, INCLUDING the empty list `[]`) → the
      instance deliberately carries exactly that subset. We persist the list
      verbatim. An explicit `%{behaviors: []}` therefore yields ONLY the base
      behaviors — never the declared superset.

  Persisting `[]` for the absent case (the old behavior) would make an
  empty/malformed `%{behaviors: []}` indistinguishable from omitted args and,
  on a superset Kind, expand back to the full declared list — re-opening the
  §3.1 hole on first spawn AND on every reload. The `nil` sentinel closes it.

  The set is snapshotted via the standard `kind_snapshots` path, so it
  survives restart/reconcile exactly like any other slice.
  """

  use Ezagent.Lifecycle, state_slice: :kind_base

  @impl Ezagent.Lifecycle
  def create(args) do
    # ABSENT key → legacy sentinel nil (full-declared expansion downstream).
    # PRESENT list (even []) → persist it exactly.
    behaviors =
      case Map.fetch(args, :behaviors) do
        :error -> nil
        {:ok, list} when is_list(list) -> list
      end

    {:ok, %{behaviors: behaviors}}
  end

  @doc """
  Read the captured instance behavior set from this Kind's :kind_base slice.
  Returns the captured list (possibly `[]`) for an instance spawned with a
  PRESENT `:behaviors` arg, or the legacy sentinel `nil` for an absent-args
  (legacy static) instance and for missing/empty slices.
  """
  @spec behaviors_in_slice(map() | nil) :: [module()] | nil
  def behaviors_in_slice(%{state: %{behaviors: behaviors}}) when is_list(behaviors), do: behaviors
  def behaviors_in_slice(%{state: %{behaviors: nil}}), do: nil
  def behaviors_in_slice(%{behaviors: behaviors}) when is_list(behaviors), do: behaviors
  def behaviors_in_slice(%{behaviors: nil}), do: nil
  def behaviors_in_slice(_), do: nil

  @doc """
  RF-2/RF-3 — REWRITE the captured behavior list in a `:kind_base` slice.

  The ONLY writer of the captured set after first spawn (`create/1` is the
  first-spawn writer). `Ezagent.Kind.MountDetach` calls this to record a LIVE
  instance's mount/detach of a behavior so the new set PERSISTS and rehydrates
  identically on cold restart (the whole point of the `:kind_base` capture).

  `new_list` is the PRESENT-list form (a list, possibly `[]`) — NEVER the
  legacy `nil` sentinel: a live mount/detach acts on an instance whose set is
  now explicit, so it must be persisted as a present list (an explicit `[]`
  yields only base behaviors on reload, never the declared superset — the
  §3.1 invariant). Preserves the two-container shape KindBase persists.

  Accepts both the persisted `%{state: %{behaviors: _}, transients: _}` shape
  and a missing/legacy slice (seeds a fresh two-container slice) so a live
  mount on a pre-existing instance with only a sentinel-`nil` capture still
  records a concrete list.
  """
  @spec put_behaviors(map() | nil, [module()]) :: map()
  def put_behaviors(slice, new_list) when is_list(new_list) do
    case slice do
      %{state: state} = s when is_map(state) ->
        %{s | state: Map.put(state, :behaviors, new_list)}

      %{} = s ->
        Map.put(s, :state, %{behaviors: new_list})

      _ ->
        %{state: %{behaviors: new_list}, transients: %{}}
    end
  end
end
