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

  ## Migration to §2.2 declarative contract (Phase 2.5 — 2026-05-28)

  Per SPEC `2026-05-28-router-behavior-kind-architecture.md` §6.2,
  this Behavior is migrated from the legacy `@behaviour Ezagent.Behavior`
  contract to the new `use Ezagent.Behavior` macro + per-action
  `action/3` declarations + `handle_<action>/2` handlers. Semantics
  unchanged — `dispatchable?/0 == false` keeps the marker behaviour
  identical (handlers raise if ever reached as defence in depth).

  Custom `required_caps/0` retained (not auto-derived) because the
  cap axis is `:user`, not the macro's default `:any`.

  ## Migration to `use Ezagent.Lifecycle` (Phase B — 2026-05-29)

  Cap-only, state-only Behavior: no PIDs/refs/handles, so there are NO
  transients. `init_slice/1` (empty `%{}`) → `create/1` (empty `%{}`);
  `activate/2` is the macro's no-op default. The slice key auto-derives
  to `:notifications` (module last segment), matching the previous
  explicit `state_slice/0`, so no `state_slice:` override is needed.
  The cap-only handlers + `dispatchable?/0 == false` are unchanged.
  """

  use Ezagent.Lifecycle

  action :notify,
    args: %{},
    returns: :ok,
    caps: [:notify],
    modes: [:call],
    description: "push a notification into a user's inbox (used by plugins / domains)"

  action :subscribe,
    args: %{},
    returns: :ok,
    caps: [:subscribe],
    modes: [:call],
    description: "subscribe to a user's notification stream (used by LV / admin / monitoring)"

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Notifications is cap-only and registered on User Kind only — kind
  # axis is `:user`. The macro-derived default would be `:any`; we
  # override to preserve the `:user` axis the CapabilityRegistry needs
  # to match the existing grants.
  def required_caps do
    %{
      notify: Ezagent.Capability.cap(:user, __MODULE__, :notify),
      subscribe: Ezagent.Capability.cap(:user, __MODULE__, :subscribe)
    }
  end

  def dispatchable?, do: false

  # Cap-only, state-only: empty persistent state, no transients. Slice
  # key auto-derives to `:notifications` (module last segment).
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  # Cap-only marker — must define `handle_<action>/2` to satisfy the
  # `use Ezagent.Behavior` macro's @before_compile invariant (every
  # declared action requires a matching handler). Raises identically
  # to the legacy contract clause; `dispatchable?/0 == false`
  # prevents the framework dispatcher from ever routing here.
  def handle_notify(_args, _ctx) do
    raise "Ezagent.Behavior.Notifications.:notify is cap-only — " <>
            "use Ezagent.Notifications.notify/2 instead of dispatching."
  end

  def handle_subscribe(_args, _ctx) do
    raise "Ezagent.Behavior.Notifications.:subscribe is cap-only — " <>
            "use Ezagent.Notifications.subscribe/2 instead of dispatching."
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): per-entity Behavior
  # — the entity (user / agent) owns its own state for this Behavior.
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
