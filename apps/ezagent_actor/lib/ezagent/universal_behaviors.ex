defmodule Ezagent.UniversalBehaviors do
  @moduledoc """
  Behaviors that apply to EVERY Kind **by construction** (#533 §3.4; Allen
  2026-06-03 decision 1-B — "auto-register by construction, not per-app").

  The registry lookups (`Ezagent.BehaviorRegistry.lookup/2` and
  `Ezagent.CapabilityRegistry.lookup_subject/2`) fall back to these behaviors
  for any `{kind, action}` that has no per-Kind registration — so a NEW Kind
  (including plugin-defined Kinds: `CurlAgent`, `PyAgent`,
  `ExternalMirrorWorker`, …) gets these capabilities automatically, with no
  per-app registration call to forget. This makes the "every Kind has Manage"
  invariant true by construction rather than by remembering.

  Keep this list TINY — only truly cross-cutting, every-Kind management
  behaviors belong here. A per-Kind registration always takes precedence (the
  fallback fires only on a lookup miss), so a Kind may still override.

  ## Invariant: actions must not collide

  No two universal behaviors may declare the same action, and a universal
  behavior's actions should not collide with a common per-Kind action name
  (`:delete` / `:reconfigure` are reserved for `Manage`). Enforced by
  `lifecycle_persistence_access_test` / the manage-coverage invariant.

  ## C5 §3.4 — registration data, not a hard-coded module

  The list itself is core POLICY (`Ezagent.ActionSet.Manage` stays in
  `ezagent_core`), so this framework module cannot name it: the concrete
  modules are injected as registration data by the core boot wiring
  (`Ezagent.Kind.Adapters.wire!/0`, key `:universal_behaviors`) — the same
  inversion as the `BehaviorSet` slice-owner tables. Module ATOMS only;
  the framework calls `actions/0` on them at runtime. Standalone (no core
  boot) the set is empty.
  """

  @doc "All behaviors that apply to every Kind by construction."
  @spec all() :: [module()]
  def all, do: Application.get_env(:ezagent_actor, :universal_behaviors, [])

  @doc """
  The universal behavior that handles `action`, or `nil` if no universal
  behavior declares it. First match wins (actions are unique across the
  small universal set).
  """
  @spec behavior_for_action(atom()) :: module() | nil
  def behavior_for_action(action) when is_atom(action) do
    Enum.find(all(), fn behavior -> action in behavior.actions() end)
  end
end
