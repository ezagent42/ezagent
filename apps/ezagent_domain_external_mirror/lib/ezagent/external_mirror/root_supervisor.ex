defmodule Ezagent.ExternalMirror.RootSupervisor do
  @moduledoc """
  `Ezagent.ExternalMirror.RootSupervisor` — the top-level
  `DynamicSupervisor` that hosts every per-binding supervisor.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.3 + §6.3 — r4 HIGH-2 two-tier supervisor fix; codex round-4
  HIGH-2 invariant.

  ## Topology (SPEC §6.3)

      Ezagent.ExternalMirror.RootSupervisor    (DynamicSupervisor)
        ├── PerBindingSupervisor[binding_uri=A]   (Supervisor)
        │   └── Kind.Server[ExternalMirrorWorker A]
        ├── PerBindingSupervisor[binding_uri=B]
        │   └── Kind.Server[ExternalMirrorWorker B]
        └── … one per active binding

  ## Restart policy

  - **DynamicSupervisor:** `:one_for_one`, `max_restarts: 100,
    max_seconds: 60`. Wide intensity because per-binding-supervisor
    crashes are RARE structural events — a PerBindingSupervisor
    only crashes when its OWN Worker exhausts the inner 3/30s
    budget (a binding stuck in restart loop). Even 50 concurrent
    per-binding crashes stay well under the 100/60s envelope.
  - **Per-binding child restart strategy:** `:permanent` (codex
    round-1 CRIT fix, 2026-05-25). r1 used `:transient` reasoning
    that "supervisor budget exhaustion crashes the supervisor →
    restart". But OTP supervisor intensity exhaustion exits with
    EXIT REASON `:shutdown`, and `:transient` explicitly does NOT
    restart on `:shutdown` (only on non-`:normal`/`:shutdown`
    crashes). So a single restart-storm would leave the binding
    permanently down after the FIRST inner-budget exhaustion —
    the documented "inner burns → RootSupervisor restarts →
    cycle" loop never fired.
    `:permanent` restarts on ANY exit including `:shutdown`. The
    graceful-unbind path (`DynamicSupervisor.terminate_child/2`)
    bypasses the restart strategy entirely (`terminate_child`
    removes the child from the dynamic supervisor's bookkeeping
    BEFORE propagating shutdown), so explicit termination never
    respawns even with `:permanent`.

  ## Why two-tier (NOT a flat shared supervisor)

  R3 had this as a single `DynamicSupervisor` with Workers as
  direct children + intensity 3/30s. Codex round-3 HIGH-2 caught
  the bug: 4 different bindings crashing once each within 30s
  would trip the SHARED supervisor and crash ALL workers including
  the 46 that were healthy.

  The two-tier topology localizes restart pressure: each
  PerBindingSupervisor has its OWN 3/30s budget (so a single
  flaky binding can crash-loop without spending the global
  budget); the RootSupervisor's 100/60s budget then absorbs many
  PerBindingSupervisor crashes without itself crashing.

  ## Invariant (PR-EM-2 acceptance test 3)

  `Supervisor.which_children(RootSupervisor)` MUST return ONLY
  PerBindingSupervisor children — never a `Kind.Server` directly.
  That invariant test catches any future "optimization" that
  flattens the tree and reintroduces the cumulative-restart bug.
  """

  use DynamicSupervisor

  @doc """
  Start the RootSupervisor with SPEC §6.3's intensity settings.
  Called from `EzagentDomainExternalMirror.Application.start/2`.
  """
  @spec start_link(any()) :: Supervisor.on_start()
  def start_link(_init_arg) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(:ok) do
    # SPEC §5.3 / §6.3: wide envelope because per-binding-sup
    # crashes are rare; the inner PerBindingSupervisor 3/30s
    # budget does the per-binding isolation work.
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 60
    )
  end
end
