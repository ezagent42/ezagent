defmodule Ezagent.ActionSet.Sandbox do
  @moduledoc """
  Sandbox Lifecycle module — per-agent config dir + extension-management
  scaffolding (Allen 2026-05-24 PR2). Migrated to the Lifecycle API
  (Phase B, SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md`
  §2.3B — the canonical TRANSIENTS reference conversion).

  ## Why this module exists

  Per Allen's 2026-05-24 architectural decision: every spawned agent
  gets its OWN config dir (copied from the template's reference dir at
  spawn time), and the plugin Template Class owns the contract for
  creating / enumerating / mutating / destroying that dir. Core (this
  module) knows NOTHING about what lives inside — it just holds the
  path, the owning Template Class, and orchestrates the lifecycle
  hand-off.

  Before this module, sandbox config was per-TEMPLATE (multiple agents
  from one template shared a single config_dir reference — no per-agent
  isolation, no user-level extension toggle).

  ## The two-container split (SPEC §0.1 / §2.1 / §2.3B)

  This is the reference TRANSIENTS conversion. The pre-Lifecycle slice
  mixed durable domain data with a process-bound subscription and a
  process-dict gate. The Lifecycle split is:

  ### `state` (PERSISTENT — framework auto-snapshots)

      %{
        config_dir_path:       nil | String.t(),  # absolute path; nil until :update_config
        template_class:        nil | module(),    # Kind.Template Class that owns the dir
        respawn_template_data: nil | map(),        # opaque plugin instantiate/3 tmpl arg
                                                   # (cwd + respawn knobs); fed back to the
                                                   # Template Class's ensure_subprocess_alive/2
                                                   # on cold-load — without re-walking
                                                   # Workspace.Store (which would couple core
                                                   # to ezagent_domain_workspace).
        pty_phase:             nil | :starting | :running | :dead,
                                                   # mirror of the PtyServer's `phase`;
                                                   # snapshot-persisted so the LV badge shows
                                                   # the last-known phase across a phx restart
                                                   # until activate/2 re-spawns the subprocess.
        passive:               boolean(),          # RF-5a/RF-6: DURABLE non-principal
                                                   # (data-actor) marker. The role create step
                                                   # writes it from the materialized recipe's
                                                   # `passive`; the `:passive` UriQuery resolver
                                                   # reads it from this slice (snapshot-backed)
                                                   # so a passive actor stays passive across a
                                                   # cold restart (NOT fail-open to principal).
        recipe:                nil | String.t()    # P2 RECIPE PROVENANCE (was RF-7 `:role`).
                                                   # DURABLE name of the RECIPE the agent was
                                                   # built from — build provenance, NOT a session
                                                   # role (session role_name lives only on the
                                                   # membership edge; Gate B). The create step
                                                   # writes it from the materialized recipe
                                                   # (`role.name`); the `:recipe` UriQuery resolver
                                                   # + `Ezagent.Agent.RecipeResolver.list_by_recipe/2`
                                                   # read it from this slice (snapshot-backed) so
                                                   # a DORMANT provenance agent (e.g. the
                                                   # kanban-manager) still enumerates by recipe
                                                   # after a BEAM restart (else the board
                                                   # vanishes). `nil` = no recipe provenance.
      }

  Every one of these is DURABLE: the cold-load `activate/2` reads
  `template_class` + `respawn_template_data` to re-spawn the
  plugin-owned subprocess, and `pty_phase` is the persisted LV-badge
  mirror. They must survive a restart, so they live in `state`.

  ### `transients` (NEVER persisted — rebuilt every `activate/2`)

      %{
        phase_subscription: %{topic: String.t(), subscriber: pid()}
      }

  The PTY phase-topic PubSub subscription is process-bound: it binds the
  host `Kind.Server` process to `pty:phase:<agent_uri>` so the live
  `{:pty_phase, ...}` broadcasts land in `handle_signal/2`. The
  subscription DIES with the process and has no serialization path — it
  is the textbook transient. `activate/2` re-subscribes on EVERY start
  (fresh spawn, supervisor restart, cold-load), recording the topic + the
  CURRENT subscriber pid so the cold-restart invariant test can prove the
  binding was rebuilt against the NEW process (the prior incarnation's pid
  would be a stale, dead reference).

  ## The `destroyed?` gate DISAPPEARS (SPEC §2.3B)

  The pre-Lifecycle code stored a `destroyed?` flag in the GenServer
  PROCESS DICT precisely BECAUSE the slice would otherwise persist it (a
  re-spawn would rehydrate `destroyed?: true` and permanently gate the
  new actor). Under Lifecycle this hack is GONE: destroyed = ABSENCE of
  state. `destroy/2` runs the FS cleanup, then the framework clears
  durable `state` + flips the ever-created marker; a respawn at the same
  URI goes through `create/1` again (clean). The 20ms-window race the
  gate guarded (a concurrent `:read`/`:update_config` seeing already-cleaned
  state) is now closed by the destroy path terminating the process — a
  dispatch to a terminated Kind cannot read stale state because there is
  no live process to dispatch to.

  ## Actions — `:read` / `:update_config` / `:destroy`

  - **`:read`** (`:call`) — return the state fields (config_dir_path,
    template_class, respawn_template_data, pty_phase). Plugin-agnostic LV
    uses this + `template_class.list_extensions/1` to render the per-agent
    extension toggle grid.
  - **`:update_config`** (`:call`, args `%{config_dir_path:, template_class:,
    respawn_template_data:}`) — population dispatched by the spawn caller
    AFTER the plugin's `instantiate/3` returned the per-agent dir in meta
    (PR3). Writes the durable `state` fields via `{:set, key, value}`
    effects.
  - **`:destroy`** (`:call`) — terminal action. Synchronously calls
    `template_class.destroy_config_dir/2` for FS cleanup (best-effort,
    try/rescue/catch), then either clears the `state` fields (cleanup
    succeeded) or preserves them (cleanup failed — so ops can see the
    stale path + retry), and schedules Kind-process termination via the
    detached-Task pattern so the dispatch reply wins the race against
    process death.

  ## Boot self-heal (SPEC §10-R1 — pre-`:ready` work → `activate/2`)

  The pre-Lifecycle `post_init/2` → `handle_continue/3` did TWO things,
  BOTH synchronous (no `send(self(), ...)` self-deferral): (1) subscribe
  to the phase topic, (2) `ensure_subprocess_alive` if state says there
  should be a subprocess. Both are pre-`:ready` boot work, so per §10-R1
  both fold into `activate/2`. The subprocess re-spawn is the §4-#113
  fix made structurally guaranteed: it runs on EVERY start because
  `activate/2` is the ONE start hook.

  ## Relationship to `Ezagent.Kind.Template`

  `Kind.Template` is the Template Class contract — `create_config_dir/2`,
  `list_extensions/1`, `toggle_extension/3`, `destroy_config_dir/2`,
  `ensure_subprocess_alive/2` are `@optional_callbacks`. Plugin Template
  Classes that want per-agent config dirs implement them together;
  classes that don't (echo, curl, np) opt out by omission, and this
  module becomes a no-op for agents spawned from them
  (`config_dir_path` stays `nil`, `:destroy` skips the FS callback,
  `activate/2` skips the subprocess re-spawn).
  """

  use Ezagent.Lifecycle

  require Logger

  action(:read,
    args: %{},
    returns: %{
      config_dir_path: {:option, :string},
      template_class: {:option, :atom},
      respawn_template_data: {:option, :map},
      pty_phase: {:option, :atom}
    },
    caps: [:read],
    modes: [:call],
    description: "read the agent's sandbox state (config_dir_path, template_class)"
  )

  action(:update_config,
    args: %{
      config_dir_path: {:option, :string},
      template_class: {:option, :atom},
      respawn_template_data: {:option, :map}
    },
    returns: %{config_dir_path: {:option, :string}},
    caps: [:update_config],
    modes: [:call],
    description:
      "set the agent's config_dir_path (one-time, at spawn — caller is the " <>
        "spawn orchestrator, system caps)"
  )

  action(:destroy,
    args: %{},
    returns: %{destroyed: :boolean},
    caps: [:destroy],
    modes: [:call],
    description:
      "destroy the agent — synchronous config-dir cleanup + scheduled " <>
        "Kind-process termination"
  )

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Sandbox is registered on the Agent Kind — kind axis is `:agent`. The
  # macro-derived default would yield `:any`; we override to preserve the
  # `:agent` axis the CapabilityRegistry needs to match existing grants.
  # Passes through the Lifecycle macro unchanged (SPEC §3 mapping table).
  def required_caps do
    %{
      read: Ezagent.Capability.cap(:agent, __MODULE__, :read),
      update_config: Ezagent.Capability.cap(:agent, __MODULE__, :update_config),
      destroy: Ezagent.Capability.cap(:agent, __MODULE__, :destroy)
    }
  end

  # The auto-derived slice key for `Ezagent.ActionSet.Sandbox` is the
  # underscored last segment `Sandbox` → `:sandbox`, which is EXACTLY the
  # pre-Lifecycle `state_slice/0`. The snapshot-compat key is preserved
  # with no explicit override needed (SPEC §3 / §7 OQ-7).

  # ---- create/1 — PERSISTENT state only (SPEC §5 step 3) -------------------

  # `init_slice/1` → `create/1`: build ONLY the durable fields. No
  # process-dict reset (the gate is gone), no transients (those are
  # `activate/2`'s job). `args` carries the spawn-time values; a snapshot
  # rehydrate shadows this `state` on cold-load (the macro's
  # `init_slice/1` + snapshot merge), so `create/1` runs once-ever.
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       config_dir_path: Map.get(args, :config_dir_path),
       template_class: Map.get(args, :template_class),
       respawn_template_data: Map.get(args, :respawn_template_data),
       # PTY-phase mirror — nil at fresh spawn; transitions to
       # :starting | :running | :dead as PtyServer broadcasts arrive.
       # `validate_phase/1` rejects corrupt rehydrated values.
       pty_phase: validate_phase(Map.get(args, :pty_phase)),
       # RF-5a/RF-6 DURABLE passive (non-principal) marker. The role create
       # step threads `:passive` into the spawn args from the materialized
       # recipe; an absent value (every non-role agent) is `false` (principal).
       # A snapshot rehydrate shadows this on cold-load, so it survives a
       # restart — the `:passive` UriQuery resolver reads it from this slice.
       passive: validate_passive(Map.get(args, :passive)),
       # P2 DURABLE RECIPE PROVENANCE (was RF-7 `:role`). The create step threads
       # `:recipe` into the spawn args from the materialized recipe; an absent
       # value (every non-recipe agent) is `nil`. A snapshot rehydrate shadows
       # this on cold-load, so it survives a restart — the `:recipe` UriQuery
       # resolver + `Ezagent.Agent.RecipeResolver.list_by_recipe/2` read it from the
       # persisted slice, so a DORMANT provenance agent still enumerates by
       # recipe after a BEAM restart. NOT a session role (Gate B).
       recipe: validate_recipe(Map.get(args, :recipe))
     }}
  end

  # `recipe` comes from spawn args (create step) or a rehydrated snapshot value;
  # a non-empty string is the RECIPE NAME (build provenance), anything else
  # (nil/missing/corrupt/empty) is the no-provenance default `nil`.
  defp validate_recipe(r) when is_binary(r) and r != "", do: r
  defp validate_recipe(_), do: nil

  # `passive` comes from spawn args (role create step) or a rehydrated snapshot
  # value; anything that is not a boolean (nil/missing/corrupt) is the
  # principal-actor default `false` — never a surprising truth value.
  defp validate_passive(p) when is_boolean(p), do: p
  defp validate_passive(_), do: false

  # `create/1`'s `args` may be a rehydrated snapshot value; reject corrupt
  # values (anything that isn't nil-or-one-of-the-three-atoms) by resetting
  # to nil. The next live phase broadcast (or the activate re-spawn flow)
  # writes the correct value.
  defp validate_phase(p) when p in [:starting, :running, :dead, nil], do: p
  defp validate_phase(_), do: nil

  # ---- activate/2 — rebuild ALL transients + self-heal (SPEC §5 step 4) ----

  # UNIFIES the pre-Lifecycle `post_init/2` + `handle_continue/3`. Runs on
  # EVERY start (fresh spawn, supervisor restart, cold-load) — the
  # structural guarantee that makes the §4-#113 "fresh works, restart
  # doesn't" bug impossible: the subprocess re-spawn is in the ONE start
  # hook.
  #
  # Both steps are pre-`:ready` boot work with NO self-deferral
  # (`send(self(), ...)`), so per §10-R1 both belong here in `activate`
  # (NOT `activated/2` / `handle_signal/2`):
  #
  #   1. transient: subscribe to the PTY phase topic. The subscription
  #      binds THIS Kind.Server process; it is rebuilt every start and
  #      recorded in `transients` (the subscriber pid is the
  #      cold-restart-detectable token).
  #   2. self-heal: (re)spawn the plugin subprocess if `state` says there
  #      should be one. Best-effort — a brutal kill may have skipped
  #      `destroy`/`deactivate`, so the orphan-reap/ensure-alive runs HERE
  #      every start (§OTP / §10-F4), not solely in `destroy`.
  @impl Ezagent.Lifecycle
  def activate(state, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    # 1. Rebuild the phase-topic subscription transient. The subscription
    #    is process-bound (Phoenix.PubSub registers `self()` as the
    #    recipient); incoming `{:pty_phase, ...}` tuples land in
    #    `handle_signal/2`. Best-effort: a subscribe failure (PubSub down)
    #    is logged + swallowed — operator-visibility plumbing must not
    #    crash the boot.
    phase_subscription = subscribe_to_phase_topic(self_uri)

    # 2. Self-heal the plugin subprocess from durable `state`. Skipped
    #    when the agent has no Template Class or no respawn data (a
    #    brand-new / non-subprocess agent).
    if should_ensure_subprocess?(state.template_class, state.respawn_template_data) do
      _ = do_ensure_subprocess_alive(state.template_class, self_uri, state.respawn_template_data)
    end

    {:ok, %{phase_subscription: phase_subscription}}
  end

  # ---- :read ----------------------------------------------------------------

  # Destroyed-gate (remediation SPEC 2026-05-30 C-C): once `:destroy` has run,
  # a `:read` arriving in the brief live window before scheduled termination
  # must STRICTLY return `{:error, :destroyed}` (not the cleared `{:ok, state}`).
  # The gate is a TRANSIENT — never persisted, rebuilt empty on re-spawn — so
  # the old persisted-flag bug §2.3B cannot recur.
  def handle_read(_args, ctx) do
    if destroyed?(ctx) do
      {:error, :destroyed}
    else
      {:ok,
       %{
         config_dir_path: ctx.read.(:config_dir_path, nil),
         template_class: ctx.read.(:template_class, nil),
         respawn_template_data: ctx.read.(:respawn_template_data, nil),
         # Expose the mirrored phase so LV / admin callers read it without
         # subscribing to the phase topic themselves.
         pty_phase: ctx.read.(:pty_phase, nil)
       }, []}
    end
  end

  # The destroyed marker lives in the TRANSIENT container (set by
  # `handle_destroy`), read via `ctx.transients` like every other transient.
  defp destroyed?(ctx), do: (ctx[:transients] || %{})[:destroyed] == true

  # ---- non-activating snapshot read (FP5 S5 #115 — MEDIUM-2) ----------------

  @doc """
  Read an agent's durable sandbox `state` (the `:read` action's payload —
  `config_dir_path` / `template_class` / `respawn_template_data` / `pty_phase`)
  WITHOUT activating the agent.

  This is the NON-DISPATCHING read surface for the agent-detail / extension
  panels (`Ezagent.World.IdentityData`), the sandbox sibling of
  `Ezagent.Identity.read_entity_caps/1`. It reads the LIVE `:sandbox` slice via
  `Ezagent.Kind.get_slice/2` (a registry lookup — `:not_found` for a cold
  agent, NEVER spawns), then falls back to the persisted
  `Ezagent.SnapshotStore.latest/1` snapshot (cold path), normalizing the
  two-container slice via `Ezagent.Kind.normalize_slice_view/1`. Returns `nil`
  when neither is present so the detail page degrades to "—".

  This OWNER module holds the read (the `:sandbox` slice is NOT a sensitive
  slice — `SensitiveSliceReadTest` covers only `:identity`/`:api_keys`), so no
  allowlist entry is needed and no new cross-app dependency is introduced
  (`Kind` + `SnapshotStore` both live in core, alongside this Behavior).

  Authorization is NOT performed here — this is a pure read, mirroring
  `read_entity_caps/1`. The CALLER (the world facade) preserves the
  `:sandbox/:read` dispatch gate via `Ezagent.Identity.caps_authorize?/2`
  BEFORE calling this; an unauthorized caller never reaches it. The live
  `:read` dispatch path is unchanged.
  """
  @spec read_persisted_state(URI.t() | String.t()) :: map() | nil
  def read_persisted_state(agent_uri) do
    case Ezagent.Kind.get_slice(agent_uri, :sandbox) do
      {:ok, slice} when is_map(slice) -> slice
      _ -> read_persisted_state_from_snapshot(agent_uri)
    end
  end

  defp read_persisted_state_from_snapshot(agent_uri) do
    case Ezagent.SnapshotStore.latest(agent_uri) do
      {:ok, %{state: state}} when is_map(state) ->
        case Map.get(state, :sandbox) do
          slice when is_map(slice) -> Ezagent.Kind.normalize_slice_view(slice)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ---- :update_config ----------------------------------------------------------

  # Population dispatched by the spawn caller AFTER the plugin's
  # `instantiate/3` returned the per-agent dir in meta (PR3 wiring).
  # Subsequent invocations are allowed (re-spawn / re-bind) — there is no
  # immutability semantics here; the caller (spawn orchestrator) is trusted.
  def handle_update_config(args, ctx) when is_map(args) do
    # Destroyed-gate (C-C): same strict rejection as `:read` during the
    # post-destroy live window.
    if destroyed?(ctx) do
      {:error, :destroyed}
    else
      do_update_config(args)
    end
  end

  # ---- :destroy -------------------------------------------------------------

  # Terminal action. Ordering (codex PR2 round-1 HIGH-2 + round-2 HIGH-1
  # + round-3 HIGH-1 + round-4 HIGH-2):
  #   1. Synchronously call `template_class.destroy_config_dir/2` for FS
  #      cleanup, wrapped in try/rescue/catch (best-effort — raises +
  #      exits + throws are caught + logged, do NOT block termination).
  #   2. Branch on the cleanup result:
  #      - SUCCESS → clear the `state` fields (`{:set, key, nil}`).
  #        `:on_terminate` snapshot saves the cleared state, re-spawn
  #        rehydrates as if fresh.
  #      - FAILURE → PRESERVE the `state` fields so admin/ops can see
  #        "this agent destroyed but cleanup failed, stale path is here"
  #        and retry out-of-band. Losing the path would orphan FS state
  #        with no recoverable pointer (cc sandboxes hold credentials).
  #   3. Schedule the supervised-child termination in a detached Task
  #      (mirrors Ezagent.ActionSet.Lifecycle's 20ms-sleep pattern so the
  #      dispatch reply wins the race against process death).
  #
  # The process-dict gate is GONE (SPEC §2.3B). The `:destroyed`-gate
  # rejection of concurrent `:read`/`:update_config` is no longer needed: the
  # scheduled termination removes the live process, after which no
  # dispatch can reach it.
  #
  # NOTE: this is the ACTION handler (a dispatched `:destroy` invocation),
  # distinct from the Lifecycle `destroy/2` cleanup HOOK below. The action
  # is the operator-facing "delete this agent" path; it does its own FS
  # cleanup + termination scheduling here. (A future consolidation onto
  # the framework `Ezagent.Lifecycle.destroy/2` primitive is possible but
  # out of scope for this parity-preserving conversion.)
  def handle_destroy(_args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    kind_module = Map.get(ctx, :kind_module)
    config_dir = ctx.read.(:config_dir_path, nil)
    template_class = ctx.read.(:template_class, nil)

    # 1. FS cleanup — passes BOTH agent_uri AND config_dir_path (codex
    #    PR2 round-1 MEDIUM-3); wrapped in try/rescue/catch (codex
    #    round-2 HIGH-1). Inline because the return value gates which
    #    state fields get cleared vs preserved (codex round-4 HIGH-2).
    cleanup_result = invoke_destroy_config_dir(self_uri, config_dir, template_class)

    # 2. State update — branches on cleanup result (codex round-4 HIGH-2).
    set_effects =
      case cleanup_result do
        :ok ->
          [
            {:set, :config_dir_path, nil},
            {:set, :template_class, nil},
            {:set, :respawn_template_data, nil},
            {:set, :pty_phase, nil}
          ]

        {:error, _reason} ->
          # No state changes — preserve every field.
          []
      end

    # 3. Schedule process termination as a fire-and-forget effect. Inside
    #    `schedule_termination/2` the Task spawn returns immediately; the
    #    20ms Process.sleep happens inside the task, well after the
    #    dispatch reply has been sent.
    {:ok, %{destroyed: true, cleanup: cleanup_result},
     set_effects ++
       [
         # Remediation SPEC 2026-05-30 C-C: re-introduce the destroyed-gate,
         # but as a TRANSIENT (never persisted) instead of the old process-dict
         # / persisted flag. During the ~20ms live window before the scheduled
         # termination removes the process, a concurrent `:read`/`:update_config`
         # must STRICTLY return `{:error, :destroyed}` (SandboxDestroyTest) —
         # NOT `{:ok, cleared_state}`. Because transients are stripped at the
         # serialize boundary and rebuilt EMPTY in `activate/2`, a re-spawn
         # CANNOT rehydrate `destroyed: true` — which is exactly the
         # persisted-flag bug §2.3B removed. The two-container model makes the
         # gate safe by construction.
         {:set_transient, :destroyed, true},
         {:effect, {__MODULE__, :schedule_termination}, [self_uri, kind_module]}
       ]}
  end

  # Validate the update_config args + build the `:set` effects. Returns the
  # `{:ok, result, effects}` shape (or `{:error, _}`).
  defp do_update_config(args) do
    path = Map.get(args, :config_dir_path)
    tc = Map.get(args, :template_class)
    # PTY-orphan-restart: optional respawn-template-data arg. Present →
    # written (supply nil to clear); absent → left alone (legacy
    # semantics: omit means "leave it", the slice keeps its current value).
    rtd_present? = Map.has_key?(args, :respawn_template_data)
    rtd = Map.get(args, :respawn_template_data)

    cond do
      not (is_binary(path) or is_nil(path)) ->
        {:error, {:invalid_config_dir_path, path}}

      not (is_atom(tc) or is_nil(tc)) ->
        {:error, {:invalid_template_class, tc}}

      rtd_present? and not (is_map(rtd) or is_nil(rtd)) ->
        {:error, {:invalid_respawn_template_data, rtd}}

      true ->
        rtd_effects =
          if rtd_present? do
            [{:set, :respawn_template_data, rtd}]
          else
            []
          end

        effects =
          [
            {:set, :config_dir_path, path},
            {:set, :template_class, tc}
          ] ++ rtd_effects

        {:ok, %{config_dir_path: path, template_class: tc, respawn_template_data: rtd}, effects}
    end
  end

  # ---- handle_signal/2 — non-action GenServer messages (SPEC §9 OQ-3) ------

  # `handle_kind_message/3` → `handle_signal/2`: consume the phase
  # broadcasts PtyServer (or Python Server) emit on every
  # `:starting | :running | :dead` transition. The phase is DURABLE
  # `state` (the snapshot-persisted LV-badge mirror), so it is written via
  # `{:set, :pty_phase, phase}` — NOT a transient. The subscription
  # delivering the message is the transient; the phase value it carries is
  # persistent state.
  @impl Ezagent.Lifecycle
  def handle_signal({:pty_phase, %URI{} = agent_uri, phase, meta}, ctx)
      when phase in [:starting, :running, :dead] do
    self_uri = Map.get(ctx, :self_uri)

    # codex round-1 MED-2: PubSub topics are not an authentication
    # boundary. A bad internal publisher or a topic collision could
    # deliver a `{:pty_phase, _, _, _}` whose `agent_uri` ≠ this Kind's
    # `self_uri`. Verify identity BEFORE mutating state — drop mismatches
    # with a warning log.
    if uris_equal?(agent_uri, self_uri) do
      :telemetry.execute(
        [:ezagent, :sandbox, :pty_phase],
        %{at: Map.get(meta, :at, System.os_time(:millisecond))},
        %{
          agent_uri: URI.to_string(agent_uri),
          phase: phase,
          os_pid: Map.get(meta, :os_pid),
          reason: Map.get(meta, :reason)
        }
      )

      {:ok, [{:set, :pty_phase, phase}]}
    else
      Logger.warning(
        "Ezagent.ActionSet.Sandbox.handle_signal: pty_phase " <>
          "agent_uri=#{URI.to_string(agent_uri)} != self_uri=" <>
          "#{inspect(self_uri)}; dropping (topic-collision defense)"
      )

      :ignore
    end
  end

  def handle_signal(_other, _ctx), do: :ignore

  # ---- destroy/2 — Lifecycle cleanup hook (SPEC §5 step 6) ------------------

  # Best-effort permanent-deletion cleanup hook (distinct from the
  # `:destroy` ACTION above). Invoked by the framework
  # `Ezagent.Lifecycle.destroy/2` primitive against the LIVE Kind BEFORE
  # durable state is cleared, so it can read its own `state`. Tears down
  # the plugin-owned config dir. The orphan-reap / ensure-alive self-heal
  # is NOT here — it is in `activate/2` (a brutal kill skips this hook —
  # §OTP / §10-F4). After this returns the framework clears `state` + the
  # ever-created marker; a respawn at the same URI re-runs `create/1`.
  @impl Ezagent.Lifecycle
  def destroy(_reason, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    config_dir = ctx.read.(:config_dir_path, nil)
    template_class = ctx.read.(:template_class, nil)

    _ = invoke_destroy_config_dir(self_uri, config_dir, template_class)
    :ok
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): per-entity Behavior — the
  # entity (user / agent) owns its own state for this Behavior. Passes
  # through the Lifecycle macro unchanged (SPEC §3 mapping table).
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals: subscription transient -------------------------------------

  # Subscribe THIS process to the agent's PTY phase topic and return the
  # transient record. The `subscriber` pid (= the host Kind.Server) is the
  # cold-restart-detectable token: after a brutal kill + cold-load it is a
  # DIFFERENT, live pid — proving the subscription was rebuilt against the
  # new process, not rehydrated as a stale binding (SPEC §6 step 5c).
  defp subscribe_to_phase_topic(%URI{} = self_uri) do
    topic = "pty:phase:" <> URI.to_string(self_uri)

    try do
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
      %{topic: topic, subscriber: self()}
    catch
      kind, reason ->
        Logger.warning(
          "Ezagent.ActionSet.Sandbox.activate: PubSub.subscribe failed " <>
            "(#{inspect(kind)}, #{inspect(reason)}) for #{URI.to_string(self_uri)}; " <>
            "phase tracking disabled for this incarnation"
        )

        %{topic: topic, subscriber: self()}
    end
  end

  defp subscribe_to_phase_topic(_), do: %{topic: nil, subscriber: self()}

  defp should_ensure_subprocess?(template_class, respawn_data) do
    is_atom(template_class) and not is_nil(template_class) and not is_nil(respawn_data) and
      function_exported?(template_class, :ensure_subprocess_alive, 2)
  end

  # --- internals: FS cleanup --------------------------------------------------

  # FS cleanup with a CHECKED return — `:destroy` branches state clearing
  # on the result (codex PR2 round-4 HIGH-2):
  # - `:ok` → success, state gets cleared
  # - `{:error, reason}` → failure, state gets PRESERVED so admin/ops can
  #   see "this agent destroyed but cleanup failed, path is here" via the
  #   snapshot
  #
  # Failures (returns + RAISES + EXITS + THROWS) NEVER propagate — the
  # process MUST still terminate even if the dir cleanup hits a permission
  # / filesystem error / plugin crash (otherwise a destroy-then-respawn
  # would deadlock against a stuck filesystem state, OR a buggy plugin
  # would prevent termination entirely).
  @spec invoke_destroy_config_dir(URI.t() | term(), term(), term()) ::
          :ok | {:error, term()}
  defp invoke_destroy_config_dir(%URI{} = self_uri, config_dir, template_class)
       when is_binary(config_dir) and is_atom(template_class) and template_class != nil do
    if function_exported?(template_class, :destroy_config_dir, 2) do
      try do
        case template_class.destroy_config_dir(self_uri, config_dir) do
          :ok ->
            :ok

          {:error, reason} ->
            log_cleanup_failure(self_uri, config_dir, template_class, {:error, reason})
            {:error, reason}
        end
      rescue
        error ->
          log_cleanup_failure(
            self_uri,
            config_dir,
            template_class,
            {:rescue, error, __STACKTRACE__}
          )

          {:error, {:rescue, error}}
      catch
        kind, reason ->
          log_cleanup_failure(
            self_uri,
            config_dir,
            template_class,
            {kind, reason, __STACKTRACE__}
          )

          {:error, {kind, reason}}
      end
    else
      # No callback exported — nothing to clean. Treat as success so the
      # state gets cleared (the plugin doesn't manage a config dir).
      :ok
    end
  end

  # No config_dir or no template_class to clean against → nothing to do,
  # success.
  defp invoke_destroy_config_dir(_uri, _dir, _class), do: :ok

  defp log_cleanup_failure(self_uri, config_dir, template_class, failure) do
    Logger.warning(
      "Ezagent.ActionSet.Sandbox.destroy: " <>
        "#{inspect(template_class)}.destroy_config_dir/2 failed for " <>
        "#{uri_to_string(self_uri)} (config_dir=#{config_dir}): " <>
        "#{inspect(failure)} (continuing process termination; " <>
        "state PRESERVED for ops retry — codex round-4 HIGH-2)"
    )

    :ok
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(other), do: inspect(other)

  # --- internals: termination scheduling --------------------------------------

  # Mirrors `Ezagent.ActionSet.Lifecycle.schedule_termination/2` — detached
  # Task + 20ms sleep so the dispatch reply wins the race against the
  # supervisor terminating this GenServer.
  #
  # Marked @doc false so the function is invocable by the effect grammar's
  # `{:effect, {Mod, :fun}, args}` shape (which requires public functions)
  # but doesn't pollute the public API.
  @doc false
  def schedule_termination(%URI{} = self_uri, kind_module) when is_atom(kind_module) do
    supervisor = resolve_supervisor(kind_module)

    {:ok, _pid} =
      Task.start(fn ->
        Process.sleep(20)
        terminate_supervised(self_uri, supervisor)
      end)

    :ok
  end

  def schedule_termination(_self_uri, _kind_module), do: :ok

  defp resolve_supervisor(kind_module) do
    if function_exported?(kind_module, :supervisor, 0) do
      kind_module.supervisor()
    else
      Ezagent.KindSupervisor
    end
  end

  defp terminate_supervised(%URI{} = self_uri, supervisor) do
    # Live pid via the public operator plane (§2.2 `Kind.list_instances/0`) — the
    # actor-internal-free replacement for the `KindRegistry.lookup/1` pid
    # resolution the supervised terminate needs.
    uri_str = URI.to_string(self_uri)

    case Enum.find(Ezagent.Kind.list_instances(), fn {u, _meta} -> u == uri_str end) do
      {_u, %{pid: pid}} ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            _ = Process.exit(pid, :shutdown)
            :ok
        end

      nil ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Ezagent.ActionSet.Sandbox.destroy: terminate of #{URI.to_string(self_uri)} " <>
          "raised #{inspect(error)}; treating as terminated"
      )

      :ok
  end

  # --- internals: subprocess re-spawn (PTY-orphan-restart self-heal) ----------
  #
  # PTY-orphan-restart 2026-05-26 (Allen directive). The bug: the Agent
  # Kind (Elixir GenServer, OTP-supervised) recovers from snapshot on phx
  # restart, but the plugin-owned subprocess (cc plugin's claude TUI under
  # PtyServer; np plugin's Python interpreter) is NOT OTP-supervised across
  # BEAM restarts — it dies with the BEAM. After phx restart the Agent Kind
  # re-spawns but its `instantiate/3` may short-circuit on "Kind already
  # alive" and never re-start the subprocess. Result: Kind alive,
  # subprocess missing, operator sees a dead terminal.
  #
  # The fix (Option A per Allen): re-spawn from `activate/2` (the unified
  # start hook). `state` carries enough (template_class +
  # respawn_template_data) to dispatch back to the plugin's Template Class.
  # Under Lifecycle this runs on EVERY start, so the "fresh works, restart
  # doesn't" hazard is impossible by construction (SPEC §4-#113).
  #
  # Let-it-crash discipline (per codex finding #3): rather than RAISE on
  # `{:error, _}` (which would exhaust the shared AgentSupervisor's restart
  # intensity on a persistent failure like "claude not on PATH" and
  # cascade-kill sibling agents), log loudly + emit the
  # `:subprocess_unhealthy` telemetry (the LOUD observable signal — NOT a
  # silent fallback) + leave the Kind ALIVE in a degraded state so existing
  # routing / lookups don't crash. The correct structural fix (per-agent
  # supervisor with isolated intensity) is tracked as a follow-up.
  defp do_ensure_subprocess_alive(template_class, self_uri, respawn_data) do
    case template_class.ensure_subprocess_alive(self_uri, respawn_data) do
      :ok ->
        :ok

      # On a FRESH create this is EXPECTED: the Template Class's own spawn path
      # materializes the per-agent config home moments after the Kind starts and
      # launches the subprocess in order, while `activate/2` (the cold-restart
      # self-heal hook) correctly declines to launch against an unmaterialized
      # home (#1096 / chain B). Logging that at `:error` would make every cc
      # create look broken.
      #
      # On a COLD RESTART the same reason means the config home was deleted or
      # never committed — a REAL fault that leaves the agent permanently without a
      # subprocess. We cannot tell the two apart from here, so: log at `:info`
      # (not `:debug`, which is off in prod) and ALWAYS emit the telemetry event.
      # A `:not_ready` agent that keeps re-emitting this is the fault signal.
      {:error, {:config_dir_not_materialized, _uri} = reason} ->
        Logger.info(
          "Ezagent.ActionSet.Sandbox.activate: #{inspect(template_class)} config home for " <>
            "#{inspect(self_uri)} is not materialized — deferring the subprocess launch to " <>
            "the Template Class's spawn path. Expected on a fresh create; on a RESTART it " <>
            "means the config home is gone and the agent will stay subprocess-less."
        )

        :telemetry.execute(
          [:ezagent, :sandbox, :config_dir_not_materialized],
          %{count: 1},
          %{uri: self_uri, template_class: template_class, reason: reason}
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "Ezagent.ActionSet.Sandbox.activate: " <>
            "#{inspect(template_class)}.ensure_subprocess_alive/2 failed " <>
            "for #{inspect(self_uri)}: #{inspect(reason)}. " <>
            "Kind stays alive in DEGRADED state (no subprocess); " <>
            "operator must Restart via /admin/agents/:uri."
        )

        :telemetry.execute(
          [:ezagent, :sandbox, :subprocess_unhealthy],
          %{},
          %{
            agent_uri: URI.to_string(self_uri),
            template_class: template_class,
            reason: inspect(reason)
          }
        )

        {:error, reason}
    end
  end

  defp uris_equal?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp uris_equal?(_, _), do: false
end
