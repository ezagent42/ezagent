defmodule Ezagent.Behavior.Presence do
  @moduledoc """
  Cap-only Behavior for entity presence subscription.

  `:online` is a subscription gate, not a dispatch target — it exists
  to give `Ezagent.Presence.subscribe/2` a cap shape coherent with
  the rest of CapBAC (`%Capability{kind, behavior: Ezagent.Behavior.Presence,
  instance, workspace_uri}`).

  `dispatchable?/0` returns `false`, so `Ezagent.CapabilityRegistry.register/3`
  records the subject but does NOT write to `BehaviorRegistry` —
  `Invocation.dispatch/1` can never accidentally invoke `:online`.
  `invoke/4` raises with a clear error if dispatch ever reaches it
  (defence in depth; should be unreachable given `dispatchable?: false`).

  Registered against `Ezagent.Entity.User` + `Ezagent.Entity.Agent` in
  `EzagentCore.Application.start/2`.

  See SPEC `docs/superpowers/specs/2026-05-23-presence.md` §3.1.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:online]

  @impl Ezagent.Behavior
  def cap_subjects do
    [{:online, "observe an entity's online/offline status across all transports"}]
  end

  @impl Ezagent.Behavior
  def dispatchable?, do: false

  @impl Ezagent.Behavior
  def state_slice, do: :presence

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(:online, _slice, _args, _ctx) do
    raise "Ezagent.Behavior.Presence.:online is cap-only — " <>
            "subscribe via `Ezagent.Presence.subscribe/2` instead of dispatching."
  end

  @impl Ezagent.Behavior
  def interface, do: %{}
end
