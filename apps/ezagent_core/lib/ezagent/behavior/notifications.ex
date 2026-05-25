defmodule Ezagent.Behavior.Notifications do
  @moduledoc """
  Cap-only Behavior for the unified user-notifications inbox.

  `:notify` and `:subscribe` are the cap shapes
  `Ezagent.Notifications.notify/2` + `Ezagent.Notifications.subscribe/2`
  check against. `dispatchable?/0` returns `false` so neither action
  can be accidentally invoked through `Invocation.dispatch/1` —
  notifications are PubSub fan-outs, not dispatch targets (same
  reasoning as `Ezagent.Behavior.Presence.:online`).

  Registered against `Ezagent.Entity.User` (only User Kinds have an
  inbox) in `EzagentCore.Application.start/2`.

  Per SPEC trigger: Allen 2026-05-23 "plugin 是否有注册 notification 的
  统一入口？" → `Ezagent.Notifications` is the unified entry; this
  Behavior is its CapBAC subject.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:notify, :subscribe]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:notify, "push a notification into a user's inbox (used by plugins / domains)"},
      {:subscribe, "subscribe to a user's notification stream (used by LV / admin / monitoring)"}
    ]
  end

  # PR-CC-2a (SPEC caps-cleanup-v1 §5.1) — per-action cap STRING.
  # Registered on User Kind.
  @impl Ezagent.Behavior
  def required_caps,
    do: %{
      notify: "user.notifications.notify",
      subscribe: "user.notifications.subscribe"
    }

  @impl Ezagent.Behavior
  def dispatchable?, do: false

  @impl Ezagent.Behavior
  def state_slice, do: :notifications

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(action, _slice, _args, _ctx) do
    raise "Ezagent.Behavior.Notifications.#{inspect(action)} is cap-only — " <>
            "use Ezagent.Notifications.notify/2 or .subscribe/2 instead of dispatching."
  end

  @impl Ezagent.Behavior
  def interface, do: %{}

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): per-entity Behavior
  # — the entity (user / agent) owns its own state for this Behavior.
  @impl Ezagent.Behavior
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
