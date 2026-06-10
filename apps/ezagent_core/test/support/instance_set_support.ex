defmodule Ezagent.Kind.InstanceSetSupport do
  @moduledoc false

  defmodule ProbeBehavior do
    @moduledoc false
    use Ezagent.Lifecycle, state_slice: :probe

    # `description:` is REQUIRED for clean cap-subject registration:
    # `CapabilityRegistry.register/3` reads `cap_subjects/0` (auto-derived
    # from each action's `:description`) — see behavior.ex:753. Without a
    # description the auto-derived subject carries `""`, which registers
    # but is undocumented; give it a real string.
    action(:poke,
      args: %{},
      returns: %{},
      caps: [:poke],
      modes: [:call],
      description: "test-only probe action that records when it is dispatched"
    )

    # IMPORTANT (codex HIGH finding 2): `use Ezagent.Lifecycle` EMITS the
    # engine callbacks `on_ready/2`, `terminate/3`, `post_init/2`,
    # `handle_continue/3`, `handle_kind_message/3` and
    # `__ezagent_lifecycle_destroy__/3` — these are NOT in the macro's
    # `defoverridable` list (verified lifecycle.ex:288-302), so DEFINING
    # them directly is a compile error ("def ... already defined") and the
    # probe would never wire. The ONLY overridable developer hooks are
    # `create/1`, `activate/2`, `deactivate/2`, `destroy/2`, `activated/2`,
    # `handle_signal/2` (lifecycle.ex:290-302). We therefore observe each
    # lifecycle moment through its REAL developer hook, which the macro
    # routes to the corresponding engine callback (mapping table,
    # lifecycle.ex:24-33):
    #
    #   * on-ready observation → `activated/2`  (→ engine `on_ready/2`)
    #   * terminate observation → `deactivate/2` (→ engine graceful `terminate/3`)
    #   * destroy observation  → `destroy/2`    (→ engine `__ezagent_lifecycle_destroy__/3`)
    #   * signal observation   → `handle_signal/2` (→ engine `handle_kind_message/3`)
    #   * init/create observation → `create/1`   (→ engine `init_slice/1`)

    @impl Ezagent.Lifecycle
    def create(_args) do
      notify(:init_slice)
      {:ok, %{poked: false}}
    end

    def handle_poke(_args, _ctx) do
      notify(:handle_poke)
      {:ok, %{}, [{:set, :poked, true}]}
    end

    @impl Ezagent.Lifecycle
    def handle_signal(_msg, _ctx) do
      notify(:handle_signal)
      :ignore
    end

    # on_ready observation via the OVERRIDABLE `activated/2` developer hook
    # (the macro emits engine `on_ready/2`, which calls this — lifecycle.ex:31,284).
    @impl Ezagent.Lifecycle
    def activated(_state, _ctx) do
      notify(:on_ready)
      :ok
    end

    # terminate observation via the OVERRIDABLE `deactivate/2` developer hook
    # (the macro emits engine `terminate/3`, which calls this on the graceful
    # path — lifecycle.ex:29,258).
    @impl Ezagent.Lifecycle
    def deactivate(_reason, _ctx) do
      notify(:terminate)
      :ok
    end

    # destroy observation via the OVERRIDABLE `destroy/2` developer hook
    # (the macro emits engine `__ezagent_lifecycle_destroy__/3`, which calls
    # this on the explicit-destroy path — lifecycle.ex:30,267).
    @impl Ezagent.Lifecycle
    def destroy(_reason, _ctx) do
      notify(:destroy)
      :ok
    end

    defp notify(event) do
      case :persistent_term.get({__MODULE__, :probe_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:probe, event})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule SupersetSessionKind do
    @moduledoc false
    @behaviour Ezagent.Kind
    @impl true
    def type_name, do: :session
    @impl true
    def behaviors do
      [
        Ezagent.Behavior.Chat,
        # Turn is DECLARED (but NOT spawned into the chat-only instance set)
        # so the closure-denial test (Task 9) can REQUEST `Turn` and have it
        # survive `init_set/2`'s ∩-declared intersection — otherwise Turn is
        # dropped before `validate_closure!/1` and `UnclosedSetError` is never
        # raised (codex HIGH). Turn `reads_siblings :surface :required`.
        Ezagent.Behavior.Turn,
        Ezagent.Behavior.Surface,
        Ezagent.Kind.InstanceSetSupport.ProbeBehavior,
        Ezagent.Behavior.KindBase
      ]
    end

    @impl true
    def persistence, do: {:snapshot, :on_change}

    # CRITICAL (codex HIGH finding 3): `supervisor/0` must return a RUNNING
    # DynamicSupervisor, because `Ezagent.Kind.spawn/2` passes
    # `kind_module.supervisor()` straight into
    # `DynamicSupervisor.start_child(supervisor, {Ezagent.Kind.Server, ...})`.
    # Reuse the existing dedicated test DynamicSupervisor
    # `Ezagent.LifecycleCase.gate_supervisor()` (a named singleton started
    # idempotently by `Ezagent.LifecycleCase.ensure_gate_supervisor!/0`) — the
    # SAME opt-in pattern the cold-restart GATE Kinds use. The denial suite
    # calls `ensure_gate_supervisor!/0` in its setup before any spawn.
    @impl true
    def supervisor, do: Ezagent.LifecycleCase.gate_supervisor()
  end
end
