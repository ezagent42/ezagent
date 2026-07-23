defmodule Ezagent.ActionSet.Manage do
  @moduledoc """
  Uniform management surface registered on EVERY Kind (#533 §3.4/§3.5).

  Two cap-gated management actions give every Kind a single, uniform way to
  be managed — authorized by the manage-cap `cap(:<kind>, Manage, :any,
  instance)` that the create-entry grants the creator at create (#533 §3.3,
  built in PR-5c):

  - **`:delete`** — tear the Kind down. Maps to `Ezagent.Lifecycle.destroy/2`
    (developer destroy hooks → snapshot+marker clear → terminate). Because
    `manage.delete` is dispatched INTO the target Kind's own process and
    `Lifecycle.destroy/2` REJECTS self-destroy, the handler returns its reply
    and schedules the destroy on a detached Task (an EXTERNAL caller → passes
    the self-destroy guard) — the same "terminate-after-reply" pattern as
    `Ezagent.ActionSet.Terminable`.
  - **`:reconfigure`** — live re-materialize from new `template_data`
    (#533 §3.5). It writes the new data to this behaviour's own `:spec`
    slice and runs the Kind's Template Class `reconfigure/4` hook. The
    per-Class hooks + Class resolution land with the Template-Class registry
    (PR-5e); until then a Kind has no reconfigure hook, so this returns
    `{:error, :reconfigure_unsupported}` (an immutable Kind) rather than
    guessing — never a silent no-op.

  ## `:spec` slice

  Manage owns a tiny `:spec` slice recording the `template_data` the Kind
  was created / last-reconfigured with. Present on every Kind via the
  Manage registration. `nil` until a reconfigure (or the create-entry, 5c)
  records it.

  `required_caps[:delete] = required_caps[:reconfigure] = cap(:any, Manage,
  :any)` — `:any` ACTION (not `:manage`): dispatch overwrites the needed-cap
  action with the concrete dispatched action and `matches?` compares the
  cap's action to it, so a held `:manage` would NOT match `:delete`/
  `:reconfigure`; `:any` (scoped to Manage + the specific instance) means
  "any management action on THIS instance" and is not over-broad (#533 §3.3).
  """

  use Ezagent.Lifecycle, state_slice: :manage

  require Logger

  action(:delete,
    args: %{},
    returns: %{deleted: :boolean},
    caps: [:delete],
    modes: [:call],
    description:
      "tear the target Kind down via Lifecycle.destroy (hooks → clear snapshot+marker → terminate)"
  )

  action(:reconfigure,
    args: %{template_data: :map},
    returns: %{reconfigured: :boolean},
    caps: [:reconfigure],
    modes: [:call],
    description:
      "live re-materialize the Kind from new template_data (per-Class reconfigure hook; #533 §3.5)"
  )

  # #533 §3.3 — `:any` action, scoped to Manage + the dispatched instance.
  # The granted manage-cap `cap(:<kind>, Manage, :any, instance)` satisfies
  # both actions; resolved against the target instance at dispatch.
  def required_caps do
    %{
      delete: Ezagent.Capability.cap(:any, __MODULE__, :any),
      reconfigure: Ezagent.Capability.cap(:any, __MODULE__, :any)
    }
  end

  # Manage exposes management ACTIONS, not per-instance owned data whose
  # visibility needs gating — the manage-cap itself authorizes the actions.
  # So no data owner (same as `Behavior.Terminable`). Required because any
  # Behavior with cap_subjects must declare data_owner/1.
  def data_owner(_), do: :no_owner

  # create/1 — FIRST-EVER existence: the `:spec` records the template_data
  # the Kind was created/last-reconfigured with (nil until set by the
  # create-entry (5c) or a reconfigure). No transients.
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{spec: nil}}

  # `manage.delete` runs INSIDE the target Kind's GenServer. Lifecycle.destroy
  # rejects self-destroy, so schedule it on a detached Task (external caller)
  # AFTER the dispatch reply — mirrors Terminable's self-terminate pattern.
  def handle_delete(_args, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    {:ok, {:ok, :deleted},
     [
       {:effect, {__MODULE__, :schedule_delete}, [self_uri]}
     ]}
  end

  # `manage.reconfigure` — until the Template-Class registry + per-Class
  # `reconfigure/4` hooks land (PR-5e), no Kind declares a reconfigure hook,
  # so reconfigure is unsupported. Fail explicitly (immutable Kind) rather
  # than silently no-op or write a `:spec` that nothing re-materializes.
  # Return a handler ERROR (not {:ok, {:error, ...}}) so dispatch surfaces it
  # as `{:error, :reconfigure_unsupported}` — a caller branching on dispatch
  # errors must see the failure, not a wrapped-error "success" (codex P2).
  def handle_reconfigure(_args, _ctx) do
    {:error, :reconfigure_unsupported}
  end

  # --- internals ---------------------------------------------------------

  # Detached Task: after the synchronous dispatch reply wins the race,
  # destroy the Kind through the sanctioned Lifecycle.destroy/2 primitive
  # from an EXTERNAL process (so the self-destroy guard passes). Idempotent
  # — an already-gone target is a no-op inside destroy/terminate.
  @doc false
  def schedule_delete(%URI{} = self_uri) do
    {:ok, _pid} =
      Task.start(fn ->
        Process.sleep(20)

        Ezagent.Lifecycle.destroy!(self_uri, :manage_delete)
      end)

    :ok
  end

  def schedule_delete(_self_uri), do: :ok
end
