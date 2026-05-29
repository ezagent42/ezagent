defmodule Ezagent.Behavior.Presence do
  @moduledoc """
  Cap-only Behavior for entity presence subscription.

  `:online` is a subscription gate, not a dispatch target — it exists
  to give `Ezagent.Presence.subscribe/2` a cap shape coherent with
  the rest of CapBAC (`%Capability{kind, behavior: Ezagent.Behavior.Presence,
  instance, workspace_uri}`).

  `dispatchable?/0` returns `false`, so the CapabilityRegistry
  registration (via the public `Ezagent.Behavior` author surface)
  records the subject but does NOT write to `BehaviorRegistry` —
  `Router.dispatch/1` can never accidentally invoke `:online`.
  `handle_online/2` raises with a clear error if dispatch ever reaches
  it (defence in depth; should be unreachable given `dispatchable?: false`).

  Registered against `Ezagent.Entity.User` + `Ezagent.Entity.Agent` in
  `EzagentCore.Application.start/2`.

  See SPEC `docs/superpowers/specs/2026-05-23-presence.md` §3.1.

  ## Migration to §2.2 declarative contract (Phase 2.5 — 2026-05-28)

  Per SPEC `2026-05-28-router-behavior-kind-architecture.md` §6.2,
  migrated from `@behaviour Ezagent.Behavior` to `use Ezagent.Behavior`
  + `action/3` + `handle_<action>/2`. Cap-only marker behaviour
  unchanged. Custom `required_caps/0` retained because this Behavior
  is registered on BOTH User AND Agent — `:any` kind axis per check
  11(b)'s multi-Kind escape (dispatch substitutes the actual target's
  `type_name/0` at step 5.5 runtime).
  """

  use Ezagent.Behavior

  action :online,
    args: %{},
    returns: :ok,
    caps: [:online],
    modes: [:call],
    description: "observe an entity's online/offline status across all transports"

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Presence is registered on both User AND Agent — kind axis is `:any`
  # per check 11(b)'s multi-Kind escape (dispatch substitutes the actual
  # target's type_name/0 at step 5.5 runtime). The macro-derived default
  # also yields `:any`; we keep the explicit override for clarity and
  # to insulate this Behavior from any future macro default change.
  def required_caps do
    %{
      online: Ezagent.Capability.cap(:any, __MODULE__, :online)
    }
  end

  def dispatchable?, do: false

  def state_slice, do: :presence

  def init_slice(_args), do: %{}

  # Cap-only marker — must define `handle_online/2` to satisfy the
  # `use Ezagent.Behavior` macro's @before_compile invariant. Raises
  # identically to the legacy contract clause; `dispatchable?/0 == false`
  # prevents the framework dispatcher from ever routing here.
  def handle_online(_args, _ctx) do
    raise "Ezagent.Behavior.Presence.:online is cap-only — " <>
            "subscribe via `Ezagent.Presence.subscribe/2` instead of dispatching."
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): per-entity Behavior
  # — the entity (user / agent) owns its own state for this Behavior.
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
