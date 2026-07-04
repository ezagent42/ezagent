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
  """

  @universal [Ezagent.ActionSet.Manage]

  @doc "All behaviors that apply to every Kind by construction."
  @spec all() :: [module()]
  def all, do: @universal

  @doc """
  The universal behavior that handles `action`, or `nil` if no universal
  behavior declares it. First match wins (actions are unique across the
  small universal set).
  """
  @spec behavior_for_action(atom()) :: module() | nil
  def behavior_for_action(action) when is_atom(action) do
    Enum.find(@universal, fn behavior -> action in behavior.actions() end)
  end
end
