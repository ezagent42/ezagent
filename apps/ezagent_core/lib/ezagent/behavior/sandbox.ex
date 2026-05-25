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
        config_dir_path: nil | String.t(),  # absolute path; nil until spawn-side write_path
        template_class:  nil | module()     # Kind.Template Class that owns the dir
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
    pattern `Ezagent.Behavior.Lifecycle.invoke(:terminate, ...)` uses
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
  """

  @behaviour Ezagent.Behavior

  require Logger

  @impl Ezagent.Behavior
  def actions, do: [:read, :write_path, :destroy]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Sandbox is registered on the Agent Kind — kind axis is `:agent`.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      read: Ezagent.Capability.cap(:agent, __MODULE__, :read),
      write_path: Ezagent.Capability.cap(:agent, __MODULE__, :write_path),
      destroy: Ezagent.Capability.cap(:agent, __MODULE__, :destroy)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:read, "read the agent's sandbox slice (config_dir_path, template_class)"},
      {:write_path,
       "set the agent's config_dir_path (one-time, at spawn — caller is the " <>
         "spawn orchestrator, system caps)"},
      {:destroy,
       "destroy the agent — synchronous config-dir cleanup + scheduled " <>
         "Kind-process termination"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :sandbox

  # Codex PR2 round-2 HIGH-2 — destroyed? lives in process dict, NOT
  # the slice, so a re-spawn of the same Agent URI starts with a clean
  # gate even though the snapshot survives.
  @destroyed_pdict_key {__MODULE__, :destroyed?}

  @impl Ezagent.Behavior
  def init_slice(args) do
    # Reset the process-dict gate at slice-init time too — covers the
    # case where the same OS process happens to host successive Kind
    # incarnations (e.g. supervisor restart in the same beam). The dict
    # write is harmless if the key was already absent.
    Process.delete(@destroyed_pdict_key)

    %{
      config_dir_path: Map.get(args, :config_dir_path),
      template_class: Map.get(args, :template_class)
    }
  end

  # --- :read ----------------------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:read, slice, _args, _ctx) do
    if destroyed?() do
      # Codex PR2 round-1 HIGH-2 — once :destroy has set the gate, the
      # slice fields refer to ALREADY-CLEANED-UP filesystem state. A
      # concurrent read in the 20ms termination window must not see them.
      {:error, :destroyed}
    else
      {:ok, slice,
       %{
         config_dir_path: Map.get(slice, :config_dir_path),
         template_class: Map.get(slice, :template_class)
       }}
    end
  end

  # --- :write_path ----------------------------------------------------------

  # Population dispatched by the spawn caller AFTER the plugin's
  # `instantiate/3` returned the per-agent dir in meta (PR3 wiring).
  # Subsequent invocations are allowed (re-spawn / re-bind) but ONLY
  # before destroy has run — there is no immutability semantics here
  # (cf. SessionTemplate `:write` write-once); the caller (spawn
  # orchestrator) is trusted.
  def invoke(:write_path, slice, args, _ctx) when is_map(args) do
    if destroyed?() do
      # Codex PR2 round-1 HIGH-2 — refusing further writes after destroy
      # closes the race where a concurrent write_path would re-populate
      # the slice after cleanup and persist via :on_terminate snapshot.
      {:error, :destroyed}
    else
      do_write_path(slice, args)
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
  def invoke(:destroy, slice, _args, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    kind_module = Map.get(ctx, :kind_module)
    config_dir = Map.get(slice, :config_dir_path)
    template_class = Map.get(slice, :template_class)

    # 1. Gate first — must commit BEFORE cleanup so a racing read
    #    sees the gate, not stale state.
    Process.put(@destroyed_pdict_key, true)

    # 2. FS cleanup — passes BOTH agent_uri AND config_dir_path (codex
    #    PR2 round-1 MEDIUM-3); wrapped in try/rescue/catch (codex
    #    round-2 HIGH-1).
    cleanup_result = invoke_destroy_config_dir(self_uri, config_dir, template_class)

    # 3. Slice update — branches on cleanup result (codex round-4 HIGH-2):
    #    - SUCCESS: clear the slice. `:on_terminate` snapshot saves the
    #      cleared state, re-spawn rehydrates as if fresh.
    #    - FAILURE: PRESERVE the slice (config_dir_path + template_class
    #      survive into the snapshot) so admin/ops can see "this agent
    #      destroyed but cleanup failed, stale path is here" and retry
    #      out-of-band. Losing the path would orphan FS state with no
    #      recoverable pointer (cc sandboxes hold credentials).
    next_slice =
      case cleanup_result do
        :ok -> %{config_dir_path: nil, template_class: nil}
        {:error, _reason} -> slice
      end

    # 4. Schedule process termination.
    schedule_termination(self_uri, kind_module)

    {:ok, next_slice, %{destroyed: true, cleanup: cleanup_result}}
  end

  defp destroyed?, do: Process.get(@destroyed_pdict_key, false) == true

  # Validate the write_path args + apply to slice. Called from
  # :write_path AFTER the destroyed? gate has been checked.
  defp do_write_path(slice, args) do
    path = Map.get(args, :config_dir_path)
    tc = Map.get(args, :template_class)

    cond do
      not (is_binary(path) or is_nil(path)) ->
        {:error, {:invalid_config_dir_path, path}}

      not (is_atom(tc) or is_nil(tc)) ->
        {:error, {:invalid_template_class, tc}}

      true ->
        new_slice =
          slice
          |> Map.put(:config_dir_path, path)
          |> Map.put(:template_class, tc)

        {:ok, new_slice, %{config_dir_path: path, template_class: tc}}
    end
  end

  # --- interface ------------------------------------------------------------

  @impl Ezagent.Behavior
  def interface do
    %{
      read: %{
        description: "Read the sandbox slice (config_dir_path, template_class)",
        args: %{},
        returns: %{config_dir_path: {:option, :string}, template_class: {:option, :atom}},
        modes: [:call]
      },
      write_path: %{
        description:
          "Set the agent's config_dir_path + template_class (one-time, " <>
            "dispatched by spawn caller after create_config_dir/2 succeeded)",
        args: %{
          config_dir_path: {:option, :string},
          template_class: {:option, :atom}
        },
        returns: %{config_dir_path: {:option, :string}},
        modes: [:call]
      },
      destroy: %{
        description:
          "Destroy the agent: synchronously cleanup config dir via the " <>
            "template_class's destroy_config_dir/1, then schedule Kind " <>
            "process termination",
        args: %{},
        returns: %{destroyed: :boolean},
        modes: [:call]
      }
    }
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

  # Mirrors `Ezagent.Behavior.Lifecycle.schedule_termination/2` — detached
  # Task + 20ms sleep so the dispatch reply wins the race against the
  # supervisor terminating this GenServer.
  defp schedule_termination(%URI{} = self_uri, kind_module) when is_atom(kind_module) do
    supervisor = resolve_supervisor(kind_module)

    {:ok, _pid} =
      Task.start(fn ->
        Process.sleep(20)
        terminate_supervised(self_uri, supervisor)
      end)

    :ok
  end

  defp schedule_termination(_self_uri, _kind_module), do: :ok

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
  @impl Ezagent.Behavior
  def data_owner(%URI{} = entity_uri), do: Ezagent.URI.instance(entity_uri)
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
