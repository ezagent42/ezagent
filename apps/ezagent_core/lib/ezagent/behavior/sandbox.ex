defmodule Ezagent.Behavior.Sandbox do
  @moduledoc """
  Sandbox Behavior — per-agent config dir + extension-management
  scaffolding (Allen 2026-05-24 PR2).

  ## Why this Behavior exists

  Per Allen's 2026-05-24 architectural decision: every spawned agent
  gets its OWN config dir (copied from the template's reference dir at
  spawn time), and the plugin Template Class owns the contract for
  creating / enumerating / mutating / destroying that dir. Core (this
  Behavior) knows NOTHING about what lives inside — it just holds the
  path, the owning Template Class, and orchestrates the lifecycle
  hand-off.

  Before this Behavior, sandbox config was per-TEMPLATE (multiple
  agents from one template shared a single `claude_config_dir` —
  no per-agent isolation, no user-level extension toggle).

  ## State slice — `:sandbox`

      %{
        config_dir_path:       nil | String.t(),  # absolute path; nil until spawn-side write_path
        template_class:        nil | module(),    # Kind.Template Class that owns the dir
        respawn_template_data: nil | map()        # the plugin's instantiate/3 tmpl arg; the
                                                  # opaque map carries cwd + plugin-specific
                                                  # respawn knobs. Persisted in snapshot so
                                                  # post_init/2 (PTY-orphan-restart 2026-05-26)
                                                  # can hand it back to the Template Class's
                                                  # `ensure_subprocess_alive/2` callback after
                                                  # a phx restart, without re-walking
                                                  # Workspace.Store (which would couple core
                                                  # to ezagent_domain_workspace).
      }

  ## Destroy gate — PROCESS DICTIONARY, not slice (codex PR2 round-2 HIGH-2)

  The `destroyed?` flag is stored in the GenServer's PROCESS DICT
  (key `{__MODULE__, :destroyed?}`) rather than the slice — process
  dict dies with the process so a re-spawn of the same Agent URI
  starts with a clean gate. Storing the flag in the slice would
  persist via `:on_terminate` snapshot and a later re-spawn would
  rehydrate `destroyed?: true`, permanently gating the new actor.

  ## Actions — `:read` / `:write_path` / `:destroy`

  - **`:read`** (`:call`) — return the slice fields. Plugin-agnostic
    LV uses this + the looked-up `template_class.list_extensions/1` to
    render the per-agent extension toggle grid. **Rejects with
    `{:error, :destroyed}`** once `:destroy` has set the gate — a
    concurrent read in the 20ms termination window would otherwise
    expose stale (already-cleaned-up) state.
  - **`:write_path`** (`:call`, args `%{config_dir_path:, template_class:}`) —
    population dispatched by the spawn caller AFTER the plugin's
    `instantiate/3` returned the per-agent dir in meta (PR3). The slice
    is initialized empty. **Rejects with `{:error, :destroyed}`** once
    `:destroy` has set the gate — prevents a race where a concurrent
    write would re-populate after cleanup and be persisted by
    `:on_terminate` snapshot.
  - **`:destroy`** (`:call`) — terminal action. (1) atomically sets the
    process-dict gate so concurrent `:read`/`:write_path` are rejected;
    (2) synchronously calls `template_class.destroy_config_dir/2` for
    FS cleanup wrapped in `try/rescue/catch` (best-effort — raises,
    exits, and throws are caught + logged, do NOT block termination);
    (3) schedules Kind-process termination via the same detached-Task
    pattern `Ezagent.Behavior.Terminable.handle_terminate/2` uses
    (so the dispatch reply wins the race against process death).
    Codex PR2 round-1 HIGH-2 + round-2 HIGH-1 fixes.

  ## Relationship to `Ezagent.Kind.Template`

  `Kind.Template` is the Template Class contract — `create_config_dir/2`,
  `list_extensions/1`, `toggle_extension/3`, `destroy_config_dir/1` are
  `@optional_callbacks`. Plugin Template Classes that want per-agent
  config dirs implement them all together; classes that don't (echo,
  curl, np) opt out by omission, and `Sandbox` becomes a no-op for
  agents spawned from them (`config_dir_path` stays `nil`, `:destroy`
  skips the FS callback).

  ## Migration to §2.2 declarative contract (Phase 2.5 — 2026-05-28)

  Per SPEC `2026-05-28-router-behavior-kind-architecture.md` §6.2,
  migrated from `@behaviour Ezagent.Behavior` + `invoke/4` to
  `use Ezagent.Behavior` + `action/3` + `handle_<action>/2`.

  - `:read` → `handle_read/2`. Pure read; reads via `ctx[:read].(...)`;
    no effects (the destroyed?-gate check is identical to the legacy
    body).
  - `:write_path` → `handle_write_path/2`. Validates args, returns
    `{:set, key, value}` effects per slice field. The destroyed? gate
    + invalid-arg rejections stay identical.
  - `:destroy` → `handle_destroy/2`. The process-dict gate IS set
    synchronously inside the handler body BEFORE the slice mutations
    are decided (per legacy ordering — codex PR2 round-1 HIGH-2). The
    FS cleanup is inline (its return value gates which slice fields
    get cleared vs preserved per codex round-4 HIGH-2). Termination
    scheduling is a `{:effect, ...}` side effect — `Task.start/1`
    returns immediately so the dispatch reply still wins the race.

  The `post_init/2` + `handle_continue/3` + `handle_kind_message/3`
  callbacks are NOT part of the action contract (they hook into
  `Kind.Server` boot + message paths); they remain on the module
  unchanged.
  """

  use Ezagent.Behavior

  require Logger

  action :read,
    args: %{},
    returns: %{
      config_dir_path: {:option, :string},
      template_class: {:option, :atom},
      respawn_template_data: {:option, :map},
      pty_phase: {:option, :atom}
    },
    caps: [:read],
    modes: [:call],
    description: "read the agent's sandbox slice (config_dir_path, template_class)"

  action :write_path,
    args: %{
      config_dir_path: {:option, :string},
      template_class: {:option, :atom},
      respawn_template_data: {:option, :map}
    },
    returns: %{config_dir_path: {:option, :string}},
    caps: [:write_path],
    modes: [:call],
    description:
      "set the agent's config_dir_path (one-time, at spawn — caller is the " <>
        "spawn orchestrator, system caps)"

  action :destroy,
    args: %{},
    returns: %{destroyed: :boolean},
    caps: [:destroy],
    modes: [:call],
    description:
      "destroy the agent — synchronous config-dir cleanup + scheduled " <>
        "Kind-process termination"

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Sandbox is registered on the Agent Kind — kind axis is `:agent`. The
  # macro-derived default would yield `:any`; we override to preserve the
  # `:agent` axis the CapabilityRegistry needs to match existing grants.
  def required_caps do
    %{
      read: Ezagent.Capability.cap(:agent, __MODULE__, :read),
      write_path: Ezagent.Capability.cap(:agent, __MODULE__, :write_path),
      destroy: Ezagent.Capability.cap(:agent, __MODULE__, :destroy)
    }
  end

  def state_slice, do: :sandbox

  # Codex PR2 round-2 HIGH-2 — destroyed? lives in process dict, NOT
  # the slice, so a re-spawn of the same Agent URI starts with a clean
  # gate even though the snapshot survives.
  @destroyed_pdict_key {__MODULE__, :destroyed?}

  def init_slice(args) do
    # Reset the process-dict gate at slice-init time too — covers the
    # case where the same OS process happens to host successive Kind
    # incarnations (e.g. supervisor restart in the same beam). The dict
    # write is harmless if the key was already absent.
    Process.delete(@destroyed_pdict_key)

    %{
      config_dir_path: Map.get(args, :config_dir_path),
      template_class: Map.get(args, :template_class),
      # PTY-orphan-restart 2026-05-26: nil at fresh spawn; populated by
      # `:write_path` (along with config_dir_path + template_class) so
      # the snapshot carries enough state for `post_init/2` to call
      # `Kind.Template.ensure_subprocess_alive/2` on a phx restart.
      respawn_template_data: Map.get(args, :respawn_template_data),
      # PTY-phase-state-machine 2026-05-26 follow-up (b): mirror of the
      # PtyServer's `phase` field, updated via the PubSub broadcasts on
      # `pty:phase:<agent_uri>`. Nil by default (no subprocess yet);
      # transitions to `:starting | :running | :dead` as events arrive.
      # Snapshot-persisted alongside the other fields — when the slice
      # rehydrates after a phx restart, the previous `:dead` shows up
      # in the LV badge until the post_init `:ensure_subprocess` flow
      # re-spawns the PtyServer (which then re-emits `:starting →
      # :running`).
      pty_phase: validate_phase(Map.get(args, :pty_phase))
    }
  end

  # `init_slice/1` may receive a rehydrated snapshot in `args`; reject
  # corrupt values (anything that isn't nil-or-one-of-the-three-atoms)
  # by resetting to nil. The next live phase broadcast (or the
  # post_init re-spawn flow) will write the correct value.
  defp validate_phase(p) when p in [:starting, :running, :dead, nil], do: p
  defp validate_phase(_), do: nil

  # --- :read ----------------------------------------------------------------

  def handle_read(_args, ctx) do
    if destroyed?() do
      # Codex PR2 round-1 HIGH-2 — once :destroy has set the gate, the
      # slice fields refer to ALREADY-CLEANED-UP filesystem state. A
      # concurrent read in the 20ms termination window must not see them.
      {:error, :destroyed}
    else
      {:ok,
       %{
         config_dir_path: ctx[:read].(:config_dir_path, nil),
         template_class: ctx[:read].(:template_class, nil),
         respawn_template_data: ctx[:read].(:respawn_template_data, nil),
         # PTY-phase-state-machine 2026-05-26 follow-up (b): expose the
         # mirrored phase so LV / admin callers can read it without
         # subscribing to the phase topic themselves.
         pty_phase: ctx[:read].(:pty_phase, nil)
       }, []}
    end
  end

  # --- :write_path ----------------------------------------------------------

  # Population dispatched by the spawn caller AFTER the plugin's
  # `instantiate/3` returned the per-agent dir in meta (PR3 wiring).
  # Subsequent invocations are allowed (re-spawn / re-bind) but ONLY
  # before destroy has run — there is no immutability semantics here
  # (cf. SessionTemplate `:write` write-once); the caller (spawn
  # orchestrator) is trusted.
  def handle_write_path(args, _ctx) when is_map(args) do
    if destroyed?() do
      # Codex PR2 round-1 HIGH-2 — refusing further writes after destroy
      # closes the race where a concurrent write_path would re-populate
      # the slice after cleanup and persist via :on_terminate snapshot.
      {:error, :destroyed}
    else
      do_write_path(args)
    end
  end

  # --- :destroy -------------------------------------------------------------

  # Terminal action. Ordering (codex PR2 round-1 HIGH-2 + round-2 HIGH-1
  # + round-3 HIGH-1):
  #   1. Set the process-dict gate FIRST → any concurrent
  #      :read/:write_path dispatched in the 20ms window before the
  #      Kind process is brought down will hit the destroyed? guards
  #      and get {:error, :destroyed} instead of stale state.
  #   2. Synchronously call `template_class.destroy_config_dir/2` for
  #      FS cleanup, wrapped in try/rescue/catch (best-effort —
  #      RAISES + EXITS + THROWS are caught + logged, do NOT block
  #      termination; codex round-2 HIGH-1).
  #   3. CLEAR the slice (config_dir_path: nil, template_class: nil).
  #      Agent persistence is `:on_terminate` — `Kind.Server.terminate/2`
  #      saves the CURRENT slice on shutdown. Returning the original
  #      slice (with the now-deleted dir path) would persist stale
  #      state; a re-spawn at the same URI would rehydrate a
  #      `config_dir_path` pointing at a dir that no longer exists.
  #      Codex round-3 HIGH-1: clear the slice so the snapshot saves
  #      empty state; re-spawn rehydrates as if fresh.
  #   4. Schedule the supervised-child termination in a detached Task
  #      (mirrors Lifecycle.terminate's 20ms-sleep pattern so the
  #      dispatch reply wins the race).
  # A second :destroy is idempotent — the gate already shows true,
  # FS cleanup retries (best-effort no-op for an absent dir), the
  # cleared slice clears-again to the same shape, and a second
  # termination schedule is harmless.
  def handle_destroy(_args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    kind_module = Map.get(ctx, :kind_module)
    config_dir = ctx[:read].(:config_dir_path, nil)
    template_class = ctx[:read].(:template_class, nil)

    # 1. Gate first — must commit BEFORE cleanup so a racing read
    #    sees the gate, not stale state. Inline because the gate is
    #    a process-dict write; expressing it as a `{:effect, ...}`
    #    would run AFTER the handler returns (apply_effects bucket
    #    order), losing the "set-before-cleanup" ordering invariant.
    Process.put(@destroyed_pdict_key, true)

    # 2. FS cleanup — passes BOTH agent_uri AND config_dir_path (codex
    #    PR2 round-1 MEDIUM-3); wrapped in try/rescue/catch (codex
    #    round-2 HIGH-1). Inline because the return value gates which
    #    slice fields get cleared vs preserved (codex round-4 HIGH-2).
    cleanup_result = invoke_destroy_config_dir(self_uri, config_dir, template_class)

    # 3. Slice update — branches on cleanup result (codex round-4 HIGH-2):
    #    - SUCCESS: clear the slice fields. `:on_terminate` snapshot
    #      saves the cleared state, re-spawn rehydrates as if fresh.
    #    - FAILURE: PRESERVE the slice fields (config_dir_path +
    #      template_class survive into the snapshot) so admin/ops can
    #      see "this agent destroyed but cleanup failed, stale path is
    #      here" and retry out-of-band. Losing the path would orphan
    #      FS state with no recoverable pointer (cc sandboxes hold
    #      credentials).
    set_effects =
      case cleanup_result do
        :ok ->
          [
            {:set, :config_dir_path, nil},
            {:set, :template_class, nil},
            {:set, :respawn_template_data, nil},
            # PTY-phase-state-machine follow-up (b): destroy clears the
            # mirrored phase too — the agent is going away, the next
            # incarnation rehydrates with nil and observes its own
            # broadcasts fresh.
            {:set, :pty_phase, nil}
          ]

        {:error, _reason} ->
          # No slice changes — preserve every field.
          []
      end

    # 4. Schedule process termination as a fire-and-forget effect.
    #    Inside `schedule_termination/2` the Task spawn returns
    #    immediately; the 20ms Process.sleep happens inside the task,
    #    well after the dispatch reply has been sent.
    {:ok, %{destroyed: true, cleanup: cleanup_result},
     set_effects ++
       [{:effect, {__MODULE__, :schedule_termination}, [self_uri, kind_module]}]}
  end

  defp destroyed?, do: Process.get(@destroyed_pdict_key, false) == true

  # Validate the write_path args + apply to slice. Called from
  # :write_path AFTER the destroyed? gate has been checked. Returns
  # the new-contract `{:ok, result, effects}` shape (or `{:error, _}`).
  defp do_write_path(args) do
    path = Map.get(args, :config_dir_path)
    tc = Map.get(args, :template_class)
    # PTY-orphan-restart 2026-05-26: optional respawn-template-data
    # arg. When the caller (Agent.spawn_from_template_content/4)
    # supplies it, the data is persisted into the slice alongside
    # path + tc and used by post_init/2 on the next phx boot to
    # re-spawn the plugin-owned subprocess via the Template Class's
    # `ensure_subprocess_alive/2` callback. Absent → slice keeps the
    # current value (nil at first write; the caller may omit it to
    # write only the config_dir_path on a re-bind).
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
        # Build the :set effects — `:respawn_template_data` only writes
        # when present in args (legacy semantics: omit means "leave it
        # alone", supply nil means "clear it"). The result map mirrors
        # the legacy 3-key return shape.
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

        {:ok, %{config_dir_path: path, template_class: tc, respawn_template_data: rtd},
         effects}
    end
  end

  # --- internals ------------------------------------------------------------

  # FS cleanup with a CHECKED return — `:destroy` branches slice
  # clearing on the result (codex PR2 round-4 HIGH-2):
  # - `:ok` → success, slice gets cleared
  # - `{:error, reason}` → failure, slice gets PRESERVED so admin/ops
  #   can see "this agent destroyed but cleanup failed, path is here"
  #   via the snapshot
  #
  # Failures (returns + RAISES + EXITS + THROWS) NEVER propagate — the
  # process MUST still terminate even if the dir cleanup hits a
  # permission / filesystem error / plugin crash (otherwise a
  # destroy-then-respawn would deadlock against a stuck filesystem
  # state, OR a buggy plugin would prevent termination entirely).
  #
  # - Codex PR2 round-1 MEDIUM-3 — passes BOTH agent_uri AND
  #   config_dir_path; the plugin does NOT have to reverse-engineer the
  #   path from the URI.
  # - Codex PR2 round-2 HIGH-1 — try/rescue/catch wraps the callback so
  #   raises/exits/throws are caught + reported as {:error, _}.
  # - Codex PR2 round-4 HIGH-2 — returns the actual cleanup status; the
  #   caller (`:destroy`) uses it to decide slice clear vs preserve.
  @spec invoke_destroy_config_dir(URI.t(), term(), term()) ::
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
      # slice gets cleared (the plugin doesn't manage a config dir).
      :ok
    end
  end

  # No config_dir or no template_class to clean against → nothing to do,
  # success.
  defp invoke_destroy_config_dir(_uri, _dir, _class), do: :ok

  defp log_cleanup_failure(self_uri, config_dir, template_class, failure) do
    Logger.warning(
      "Ezagent.Behavior.Sandbox.destroy: " <>
        "#{inspect(template_class)}.destroy_config_dir/2 failed for " <>
        "#{URI.to_string(self_uri)} (config_dir=#{config_dir}): " <>
        "#{inspect(failure)} (continuing process termination; " <>
        "slice PRESERVED for ops retry — codex round-4 HIGH-2)"
    )

    :ok
  end

  # Mirrors `Ezagent.Behavior.Terminable.schedule_termination/2` — detached
  # Task + 20ms sleep so the dispatch reply wins the race against the
  # supervisor terminating this GenServer.
  #
  # Marked @doc false so the function is invocable by the effect grammar's
  # `{:effect, {Mod, :fun}, args}` shape (which requires public
  # functions) but doesn't pollute the Behavior's public API.
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
    case Ezagent.KindRegistry.lookup(self_uri) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            _ = Process.exit(pid, :shutdown)
            :ok
        end

      :error ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "Ezagent.Behavior.Sandbox.destroy: terminate of #{URI.to_string(self_uri)} " <>
          "raised #{inspect(error)}; treating as terminated"
      )

      :ok
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): per-entity Behavior
  # — the entity (user / agent) owns its own state for this Behavior.
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- post_init: PTY/Python subprocess re-spawn on boot ---------------------
  #
  # PTY-orphan-restart 2026-05-26 (Allen directive). The bug:
  #
  # Agent Kind (Elixir GenServer, OTP-supervised) recovers from snapshot
  # on phx restart. The plugin-owned subprocess (cc plugin's claude TUI
  # under PtyServer; np plugin's Python interpreter under
  # Domain.Python.Server) is NOT OTP-supervised across BEAM restarts —
  # it dies with the BEAM (or worse, survives as an OS-level orphan
  # when the BEAM is brutal-killed). After phx restart, the Agent Kind
  # gets re-spawned, but its template_class.instantiate/3 may
  # short-circuit on "Kind already alive" and never re-start the
  # subprocess. Result: Agent Kind alive, subprocess missing, operator
  # sees a dead terminal in the LV.
  #
  # The fix (Option A per Allen): hook into the Kind boot path via the
  # post_init/2 continuation. Sandbox Behavior carries enough state in
  # its slice (template_class + respawn_template_data) to dispatch back
  # to the plugin's Template Class — which knows how to check + re-spawn.
  #
  # ## Why this Behavior is the right place
  #
  # 1. Sandbox runs on every cc/np agent Kind (declared in
  #    `Ezagent.Entity.Agent.behaviors/0`). The plugin Behavior
  #    contract has no PTY/Python knowledge — Sandbox is the
  #    plugin-agnostic seam.
  # 2. Sandbox already owns the template_class atom in its slice (for
  #    destroy_config_dir routing). Adding ensure_subprocess_alive is
  #    a parallel callback on the same Kind.Template behaviour — same
  #    routing pattern, same opt-in shape (function_exported?/3
  #    probe).
  # 3. post_init/2 is the documented hook for "run something between
  #    register-in-KindRegistry and announce-ready". Subscribers
  #    waiting on ReadyGate see a fully-rehydrated Kind — including
  #    its subprocess — without race windows.
  #
  # ## What runs when
  #
  # - post_init/2 is invoked from Kind.Server.init/1 AFTER init_slice/1
  #   has populated the sandbox slice. The slice was JUST loaded from
  #   snapshot (Kind.Snapshot.load_or_init/3), so template_class +
  #   respawn_template_data carry the values the spawn-time
  #   :write_path dispatch wrote.
  # - We queue a {:continue, :ensure_subprocess} ONLY when both
  #   template_class AND respawn_template_data are present (post-spawn
  #   state). A fresh-spawn slice has them nil — that path is the
  #   plugin's instantiate/3 doing the initial start, no continuation
  #   needed.
  # - handle_continue/3 calls `template_class.ensure_subprocess_alive/2`
  #   with the agent URI + the slice's respawn_template_data. The
  #   plugin checks whether its subprocess is alive (Domain.Pty.alive?
  #   / Domain.Python.alive?) and starts it if not.
  #
  # ## Let-it-crash discipline
  #
  # When the callback returns `{:error, reason}` we LOG + RAISE. Per
  # `feedback_let_it_crash_no_workarounds` an Agent that can't bring
  # its subprocess up is dead to the operator; silently swallowing the
  # error would leave a "half-alive" Kind that ReadyGate publishes as
  # ready while the LV terminal stays black. Raising propagates to
  # Kind.Server.handle_continue/2; the supervisor restarts with backoff
  # (so an orphan-reap race or transient FS error self-recovers); the
  # operator sees the failure in logs + LV admin health panel.
  #
  # ## What's NOT done here
  #
  # - We do NOT walk Workspace.Store to refresh the template data
  #   (would couple ezagent_core ← ezagent_domain_workspace, violating
  #   the three-tier rule). The snapshot is the source of truth; if
  #   the operator changed the workspace template, the next
  #   instantiate/3 (or admin Restart click) picks up the new data.
  # - We do NOT do orphan-process reaping here. That's a plugin-tier
  #   concern (each plugin knows its own subprocess argv signature)
  #   and runs at plugin Application start, BEFORE this post_init
  #   fires. See Ezagent.PluginCc.OrphanReaper / PluginNp.OrphanReaper.

  def post_init(_args, slice) do
    template_class = Map.get(slice, :template_class)
    respawn_data = Map.get(slice, :respawn_template_data)

    # PTY-phase-state-machine 2026-05-26 follow-up (b): ALWAYS schedule
    # the post_init continuation so the Kind.Server subscribes to
    # `pty:phase:<self_uri>` regardless of whether there's a subprocess
    # to (re-)spawn right now. A fresh-spawn cc agent (template_class
    # + respawn_data both populated post-:write_path) AND a brand-new
    # agent (both nil) both need the subscription so subsequent
    # PtyServer broadcasts (whether from this incarnation's eventual
    # :write_path or from a future :ensure_subprocess) flow through.
    #
    # The continuation term encodes BOTH intents in a 2-tuple shape.
    # `handle_continue/3` branches on the present-vs-absent template
    # class — same logic as before, just under a unified entry point.
    {:continue, {:setup_phase_tracking, template_class, respawn_data}}
  end

  def handle_continue({:setup_phase_tracking, template_class, respawn_data}, slice, ctx) do
    self_uri = Map.get(ctx, :self_uri)

    # 1. Subscribe to the PTY phase topic for this agent. The
    #    Kind.Server process is `self()` here — Phoenix.PubSub
    #    registers it as the recipient, and incoming
    #    `{:pty_phase, ...}` tuples land in
    #    `handle_kind_message/3` below.
    #
    #    Best-effort: subscribe failure (PubSub down) is logged and
    #    swallowed. The post_init flow MUST NOT crash on
    #    operator-visibility plumbing failure.
    subscribe_to_phase_topic(self_uri)

    # 2. Maybe ensure the plugin subprocess is alive (the legacy
    #    PR #385 path). Skipped when the agent has no Template Class
    #    or no respawn data to feed back to the plugin.
    if should_ensure_subprocess?(template_class, respawn_data) do
      _ = do_ensure_subprocess_alive(template_class, self_uri, respawn_data)
    end

    # Slice unchanged — the subscription side effect doesn't modify
    # the slice (the snapshot doesn't carry "we subscribed" state;
    # the subscription is implicit in the live process).
    _ = slice
    :ignore
  end

  defp subscribe_to_phase_topic(%URI{} = self_uri) do
    topic = "pty:phase:" <> URI.to_string(self_uri)

    try do
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
    catch
      kind, reason ->
        Logger.warning(
          "Ezagent.Behavior.Sandbox.post_init: PubSub.subscribe failed " <>
            "(#{inspect(kind)}, #{inspect(reason)}) for #{URI.to_string(self_uri)}; " <>
            "phase tracking disabled for this incarnation"
        )

        :ok
    end
  end

  defp subscribe_to_phase_topic(_), do: :ok

  defp should_ensure_subprocess?(template_class, respawn_data) do
    is_atom(template_class) and not is_nil(template_class) and not is_nil(respawn_data) and
      function_exported?(template_class, :ensure_subprocess_alive, 2)
  end

  # PTY-phase-state-machine 2026-05-26 follow-up (b): consume the
  # phase broadcasts that PtyServer (or Python Server) emit on every
  # `:starting | :running | :dead` transition. Update the slice so
  # snapshot persistence carries the latest known phase across phx
  # restarts.
  #
  # The Kind.Server forwards `handle_info/2` messages through this
  # callback (optional hook — probed via `function_exported?/3`, NOT
  # part of the `@behaviour Ezagent.Behavior` contract). We return
  # `{:ok, new_slice}` to commit the update via the same snapshot
  # path as dispatch (PR-EM-0 codex r1 HIGH fix); `:ignore` for
  # messages we don't care about (so the Kind.Server skips the
  # snapshot write).
  def handle_kind_message({:pty_phase, %URI{} = agent_uri, phase, meta}, slice, ctx)
      when phase in [:starting, :running, :dead] do
    self_uri = Map.get(ctx, :self_uri)

    # codex round-1 MED-2: PubSub topics are not an authentication
    # boundary. A bad internal publisher or a topic collision could
    # in principle deliver a `{:pty_phase, _, _, _}` tuple whose
    # `agent_uri` ≠ this Kind's `self_uri`. Verify identity BEFORE
    # mutating the slice — drop mismatches with a warning log.
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

      {:ok, Map.put(slice, :pty_phase, phase)}
    else
      Logger.warning(
        "Ezagent.Behavior.Sandbox.handle_kind_message: pty_phase " <>
          "agent_uri=#{URI.to_string(agent_uri)} != self_uri=" <>
          "#{inspect(self_uri)}; dropping (topic-collision defense)"
      )

      :ignore
    end
  end

  def handle_kind_message(_other, _slice, _ctx), do: :ignore

  defp uris_equal?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp uris_equal?(_, _), do: false

  defp do_ensure_subprocess_alive(template_class, self_uri, respawn_data) do
    # PTY-orphan-restart 2026-05-26 round-2 (codex finding #3) —
    # rather than RAISE on {:error, _} (which would exhaust the shared
    # AgentSupervisor's restart intensity on a persistent failure
    # like "claude not on PATH" and cascade-kill sibling agents), log
    # loudly + emit telemetry + leave the Kind alive in DEGRADED state.
    #
    # This is NOT a "silent fallback to offline" (the directive from
    # Allen forbids that): the `:pty_subprocess_unhealthy` telemetry
    # event is the loud, observable signal — health panels render it,
    # log lines surface it, operator manually clicks Restart in the LV
    # admin page. The Kind is ALIVE so existing routing / lookups
    # don't crash; what's missing is the subprocess (which the
    # operator already had to handle out-of-band today).
    #
    # The supervisor-intensity option (raise to trigger restart-with-
    # backoff) was rejected per codex finding #3: it cascades to
    # sibling agents on persistent failure. The correct structural
    # fix (per-agent supervisor with isolated intensity) is out of
    # scope for this PR — tracked as a follow-up in the notes doc.
    case template_class.ensure_subprocess_alive(self_uri, respawn_data) do
      :ok ->
        # Subprocess is alive (either it was already, or we just
        # started it). Slice doesn't need changing — the spawn-time
        # write_path already populated it.
        :ignore

      {:error, reason} ->
        Logger.error(
          "Ezagent.Behavior.Sandbox.post_init: " <>
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

        :ignore
    end
  end
end
