defmodule Ezagent.ExternalMirror do
  @moduledoc """
  `Ezagent.ExternalMirror` — facade for the ExternalMirror Domain
  (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §4.4 + §8.2 r6).

  Two surface classes:

  **Mutations (the bind/unbind facade — r6 two-step flow):**

  - `bind/4` — runs Check 2 (per-adapter allow cap) + Check 3
    (`target_ownership_check/2` in a supervised Task with bounded
    timeout) BEFORE dispatching `:bind` on the Session Kind. The
    facade is the ONLY place adapter I/O happens. Dispatch CapBAC
    step 5.5 handles Check 1 (the session-level
    `Behavior.ExternalMirror` bind cap); step 5.6 handles
    cross-workspace denial.
  - `unbind/3` — straightforward dispatch of `:unbind` (no Task /
    no adapter I/O; the cleanup path is pure slice mutation +
    `WorkerSpawn.terminate/3`).

  **Reads (PR-EM-1 facade, now fully wired in PR-EM-3):**

  - `list_bindings/1` — reads the Session's `:external_mirror` slice
    via `Ezagent.Kind.get_slice/2`.
  - `sessions_for_adapter/1` — reads `external_mirror_bindings`
    projection (DB-side reverse lookup that the slice can't answer
    without scanning every session).
  - `list_adapters/0` — reads AdapterRegistry (PR-EM-1).
  """

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRow}

  require Logger

  @typedoc "A bound external mirror — shape pinned in SPEC §4.1."
  @type binding :: %{
          binding_id: String.t(),
          adapter_id: String.t(),
          target_id: term(),
          opts: map(),
          bound_by: URI.t(),
          bound_at: DateTime.t()
        }

  @typedoc """
  The operator-facing adapter descriptor returned by
  `list_adapters/0` (SPEC §4.4).
  """
  @type adapter_descriptor :: %{
          id: String.t(),
          display_name: String.t(),
          description: String.t()
        }

  @typedoc """
  Caller-context for `bind/4` / `unbind/3` — same shape as
  `Ezagent.Invocation.ctx` (caller URI + caps MapSet). The facade
  builds the inner Invocation ctx by adding `:reply` if absent.
  """
  @type caller_ctx :: %{
          required(:caller) => URI.t(),
          required(:caps) => MapSet.t(Ezagent.Capability.t()),
          optional(:reply) => Ezagent.Invocation.reply_target()
        }

  @default_target_check_timeout 5_000

  # ----- Mutations (the bind/unbind facade) ---------------------------------

  @doc """
  Bind an external mirror on `session_uri` to
  `(adapter_id, target_id)` with caller-supplied `opts`.

  Performs (in order):

  1. **Check 2** — caller holds the per-adapter allow cap
     (`{kind: :session, behavior: <adapter.cap_subject.behavior_module>,
     instance: session_uri, workspace_uri: ws}`). Returns
     `{:error, :adapter_not_authorized}` on miss (SPEC §4.2).

  2. **Check 3** — `adapter.target_ownership_check(caller, target_id)`
     runs in a `Task.Supervisor.async_nolink/3` under
     `Ezagent.ExternalMirror.TargetCheckTaskSup` with bounded timeout
     (default 5000ms; adapter override via
     `target_ownership_check_timeout/0`). Returns:
     - `:ok` → continue to dispatch
     - `{:error, reason}` from adapter → `{:error, {:target_ownership_denied, reason}}`
     - timeout → `{:error, :target_check_timeout}`
     - crash → `{:error, {:target_check_crashed, reason}}`

  3. **Dispatch** `:bind` on the Session Kind with `args[:_facade_checks_ok] = true`.
     Dispatch CapBAC step 5.5 enforces Check 1 (session bind cap);
     step 5.6 enforces cross-workspace isolation; the Behavior's
     `:bind` invoke mutates slice + idempotently spawns the Worker.

  Returns the dispatch result map (`%{ok: true, binding_id: _,
  worker_uri: _}`) on success, or any of the above errors.

  ## Why facade-not-action

  Per r6 HIGH-2: the target_ownership_check runs adapter I/O. If we
  put that inside the Session GenServer's `:bind` action body, the
  Session would be blocked for the whole timeout window (up to 5s
  by default) — chat sends / subscribe calls / other binds on the
  same session would queue behind it. The facade runs in the caller's
  process; the Session GenServer only sees the post-validated
  dispatch which is bounded by slice mutation + cheap `Kind.spawn`.
  """
  @spec bind(URI.t(), String.t(), term(), map(), caller_ctx()) ::
          {:ok, map()}
          | {:error,
             :unknown_adapter
             | :adapter_not_authorized
             | :target_check_timeout
             | {:target_ownership_denied, term()}
             | {:target_check_crashed, term()}
             | term()}
  def bind(%URI{} = session_uri, adapter_id, target_id, opts, ctx)
      when is_binary(adapter_id) and is_map(opts) and is_map(ctx) do
    with {:ok, adapter_module} <- lookup_adapter(adapter_id),
         :ok <- check_adapter_allow_cap(ctx, session_uri, adapter_module),
         :ok <- run_target_ownership_check(adapter_module, ctx.caller, target_id) do
      do_dispatch_bind(session_uri, adapter_id, target_id, opts, ctx)
    end
  end

  @doc """
  Convenience 4-ary wrapper for callers that don't pass `opts`:
  `bind(session_uri, adapter_id, target_id, ctx)` ≡
  `bind(session_uri, adapter_id, target_id, %{}, ctx)`.
  """
  @spec bind(URI.t(), String.t(), term(), caller_ctx()) ::
          {:ok, map()} | {:error, term()}
  def bind(%URI{} = session_uri, adapter_id, target_id, ctx)
      when is_binary(adapter_id) and is_map(ctx) do
    bind(session_uri, adapter_id, target_id, %{}, ctx)
  end

  @doc """
  Unbind an external mirror. Dispatches `:unbind` on the Session
  Kind; the action body removes the binding from the slice,
  deletes the projection row, and terminates the Worker via
  `WorkerSpawn.terminate/3` (which bypasses the
  PerBindingSupervisor's `:permanent` restart strategy via
  `DynamicSupervisor.terminate_child/2`).

  Idempotent: unbinding an already-absent binding returns
  `{:ok, %{ok: true, unbound: false}}`.
  """
  @spec unbind(URI.t(), String.t(), term(), caller_ctx()) ::
          {:ok, map()} | {:error, term()}
  def unbind(%URI{} = session_uri, adapter_id, target_id, ctx)
      when is_binary(adapter_id) and is_map(ctx) do
    target =
      URI.parse("#{URI.to_string(session_uri)}?action=external_mirror.unbind")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{adapter_id: adapter_id, target_id: target_id},
      ctx: ensure_reply(ctx)
    }

    Ezagent.Invocation.dispatch(inv)
  end

  # ----- Reads --------------------------------------------------------------

  @doc """
  List bindings on `session_uri`. Routes through
  `Ezagent.Invocation.dispatch/1` with action
  `external_mirror.list_bindings` so CapBAC step 5.5 enforces the
  session-level `:list_bindings` cap (declared in
  `Ezagent.Behavior.ExternalMirror.cap_subjects/0`) AND step 5.6
  enforces cross-workspace isolation.

  Returns:
  - `{:ok, [binding()]}` — caller authorized, session alive
  - `{:error, :unauthorized}` — caller lacks the cap
  - `{:error, :cross_workspace_denied}` — caller's workspace
    differs from the session's
  - `{:error, :not_ready}` / `{:error, :no_such_actor}` — session
    not running

  ## codex r2 HIGH-2 fix (2026-05-25)

  The pre-fix `list_bindings/1` read the slice directly via
  `Ezagent.Kind.get_slice/2`, bypassing the newly-registered
  `:list_bindings` action and exposing target IDs + opts to any
  in-VM caller. The fix routes through dispatch so the CapBAC
  gates run.
  """
  @spec list_bindings(URI.t(), caller_ctx()) :: {:ok, [binding()]} | {:error, term()}
  def list_bindings(%URI{} = session_uri, ctx) when is_map(ctx) do
    target =
      URI.parse("#{URI.to_string(session_uri)}?action=external_mirror.list_bindings")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{},
      ctx: ensure_reply(ctx)
    }

    case Ezagent.Invocation.dispatch(inv) do
      {:ok, %{bindings: bindings}} -> {:ok, bindings}
      {:ok, _other} -> {:ok, []}
      {:error, _} = err -> err
      :ok -> {:ok, []}
    end
  end

  @doc """
  List sessions with at least one binding for `adapter_id`. Reads
  the `external_mirror_bindings` projection table (the slice can't
  answer cross-session queries without scanning every Session
  Kind), then FILTERS by the caller's workspace.

  Returns `{:ok, [URI.t()]}` where every returned session URI is in
  the caller's workspace (per `Ezagent.Capability.workspace_of/1`).
  Callers holding a workspace-wildcard cap (i.e. an admin cap with
  `workspace_uri: :any` for the matching `kind/behavior`) see every
  session.

  ## codex r2 HIGH-2 fix (2026-05-25)

  Pre-fix, `sessions_for_adapter/1` returned every matching session
  across all workspaces with no caller context — a workspace-A user
  could enumerate workspace-B's bound sessions. The fix derives the
  caller's workspace from `ctx.caller` and filters the result set.
  An admin cap (`workspace_uri: :any` against
  `Ezagent.Behavior.ExternalMirror :list_bindings` on `:any`) skips
  the filter.
  """
  @spec sessions_for_adapter(adapter_id :: String.t(), caller_ctx()) :: {:ok, [URI.t()]}
  def sessions_for_adapter(adapter_id, ctx) when is_binary(adapter_id) and is_map(ctx) do
    all_sessions = safe_sessions_for_adapter(adapter_id)

    filtered =
      if admin_wildcard?(ctx) do
        all_sessions
      else
        caller_workspace = caller_workspace(ctx)
        Enum.filter(all_sessions, &session_in_workspace?(&1, caller_workspace))
      end

    {:ok, filtered}
  end

  defp safe_sessions_for_adapter(adapter_id) do
    BindingRow.sessions_for_adapter(adapter_id)
  rescue
    # DB unavailable — empty list rather than crash (read-side
    # safety net; same posture as PR-EM-1 stub).
    _ -> []
  end

  defp caller_workspace(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = caller_uri -> Ezagent.Capability.workspace_of(caller_uri)
      _ -> :any
    end
  end

  defp session_in_workspace?(_session_uri, :any), do: true

  defp session_in_workspace?(%URI{} = session_uri, %URI{} = caller_workspace) do
    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = session_workspace ->
        URI.to_string(session_workspace) == URI.to_string(caller_workspace)

      :any ->
        true
    end
  end

  # An "admin wildcard" cap = a Capability with `:any` workspace
  # against the `Ezagent.Behavior.ExternalMirror` Behavior's
  # `:list_bindings` action (or the `:any/:any` bootstrap admin cap).
  # When the caller holds one of these, sessions_for_adapter/2 skips
  # the workspace filter — admin tooling needs the unfiltered view.
  defp admin_wildcard?(ctx) do
    caps = Map.get(ctx, :caps, MapSet.new())

    Enum.any?(caps, fn cap ->
      cap.workspace_uri == :any and cap_admin_shape?(cap)
    end)
  end

  defp cap_admin_shape?(%{kind: :any, behavior: :any, instance: :any}), do: true

  defp cap_admin_shape?(%{
         kind: :session,
         behavior: Ezagent.Behavior.ExternalMirror,
         instance: :any
       }),
       do: true

  defp cap_admin_shape?(_), do: false

  @doc """
  List all registered adapters as `%{id, display_name, description}`
  (SPEC §4.4 shape).
  """
  @spec list_adapters() :: [adapter_descriptor()]
  def list_adapters do
    AdapterRegistry.list()
    |> Enum.map(fn %{id: id, display_name: name, description: desc} ->
      %{id: id, display_name: name, description: desc}
    end)
  end

  # ----- Facade internals --------------------------------------------------

  defp lookup_adapter(adapter_id) do
    case AdapterRegistry.lookup(adapter_id) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :unknown_adapter}
    end
  end

  # Check 2 per SPEC §4.2: caller holds the per-adapter allow cap.
  defp check_adapter_allow_cap(ctx, %URI{} = session_uri, adapter_module) do
    %{behavior_module: behavior_module} = adapter_module.cap_subject()

    instance = Ezagent.URI.instance(session_uri)

    workspace_uri =
      case Ezagent.Capability.workspace_of(session_uri) do
        %URI{} = ws -> ws
        :any -> :any
      end

    needed = %{
      kind: :session,
      behavior: behavior_module,
      instance: instance,
      workspace_uri: workspace_uri
    }

    caps = Map.get(ctx, :caps, MapSet.new())

    if Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed)) do
      :ok
    else
      {:error, :adapter_not_authorized}
    end
  end

  # Check 3 per SPEC §4.2 / §8.2: adapter membership check in a
  # supervised Task with bounded timeout. The Task runs OUTSIDE the
  # Session GenServer (in the caller process via async_nolink) — see
  # r6 HIGH-2 fix moduledoc above.
  defp run_target_ownership_check(adapter_module, caller, target_id) do
    timeout =
      if function_exported?(adapter_module, :target_ownership_check_timeout, 0) do
        adapter_module.target_ownership_check_timeout()
      else
        @default_target_check_timeout
      end

    task =
      Task.Supervisor.async_nolink(
        Ezagent.ExternalMirror.TargetCheckTaskSup,
        fn -> adapter_module.target_ownership_check(caller, target_id) end
      )

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        {:error, {:target_ownership_denied, reason}}

      {:exit, reason} ->
        {:error, {:target_check_crashed, reason}}

      nil ->
        {:error, :target_check_timeout}
    end
  end

  defp do_dispatch_bind(%URI{} = session_uri, adapter_id, target_id, opts, ctx) do
    target =
      URI.parse("#{URI.to_string(session_uri)}?action=external_mirror.bind")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{
        adapter_id: adapter_id,
        target_id: target_id,
        opts: opts,
        _facade_checks_ok: true
      },
      ctx: ensure_reply(ctx)
    }

    Ezagent.Invocation.dispatch(inv)
  end

  defp ensure_reply(ctx) do
    if Map.has_key?(ctx, :reply) do
      ctx
    else
      Map.put(ctx, :reply, :ignore)
    end
  end
end
