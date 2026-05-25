defmodule Ezagent.ExternalMirror do
  @moduledoc """
  `Ezagent.ExternalMirror` — facade for the ExternalMirror Domain
  (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §4.4 + §8.2 r6).

  Two surface classes:

  **Mutations (the bind/unbind facade — r6 two-step flow):**

  - `bind/4` — runs Check 1 (session-level `:bind` cap, inlined
    per codex r4 MED so it short-circuits BEFORE any adapter I/O) +
    Check 2 (per-adapter allow cap) + Check 3
    (`target_ownership_check/2` in a supervised Task with bounded
    timeout) BEFORE dispatching `:bind` on the Session Kind. The
    facade is the ONLY place adapter I/O happens. Dispatch CapBAC
    step 5.5 ALSO enforces Check 1 (defence-in-depth: direct
    dispatch attempts still hit it); step 5.6 handles
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

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRow, FacadeNonceTable}

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

  # ----- Mutations (the bind/unbind facade) ---------------------------------

  @doc """
  Bind an external mirror on `session_uri` to
  `(adapter_id, target_id)` with caller-supplied `opts`.

  Performs (in order):

  0. **Check 1** — caller holds the session-level `:bind` cap
     (`{kind: :session, behavior: Behavior.ExternalMirror,
     instance: session_uri, workspace_uri: ws}`). Returns
     `{:error, :unauthorized}` on miss. (codex r4 MED 2026-05-25
     — inlined here so Check 3's adapter I/O doesn't run for a
     caller missing the session cap.)

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

  3. **Dispatch** `:bind` on the Session Kind with
     `args[:_facade_nonce] = <32 bytes of crypto rand>`. The nonce is
     claimed AFTER Checks 2 + 3 pass via
     `Ezagent.ExternalMirror.FacadeNonceTable.claim_nonce/4` (5-second
     TTL) and atomically consumed by the action body via
     `consume_nonce/2`. The nonce table is `:protected` ETS owned by
     the FacadeNonceTable GenServer — only the facade (through the
     GenServer's `:claim` handle_call) can insert nonces, so an
     in-VM caller cannot forge one.

     Dispatch CapBAC step 5.5 enforces Check 1 (session bind cap);
     step 5.6 enforces cross-workspace isolation; the Behavior's
     `:bind` invoke mutates slice + idempotently spawns the Worker.

  ## codex r3 CRIT fix (2026-05-25) — forgery-proof handoff

  Pre-fix, the facade set `args[:_facade_checks_ok] = true` after
  Check 3. The action body trusted that boolean — but `args` is
  caller-controlled at `Invocation.dispatch/1` time, so any in-VM
  caller holding the session `:bind` cap could dispatch directly with
  the flag set and skip Checks 2 + 3. Real authorization bypass.

  The nonce replaces the flag: 32 random bytes signed for the exact
  `(session, adapter, target, caller)` tuple, single-use, 5-second
  expiry, atomically consumed. Forgery requires guessing 256 bits of
  RNG output (infeasible) or writing to a `:protected` ETS table the
  caller doesn't own (impossible without elevation past the BEAM's
  ETS access model).

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
             | :unauthorized
             | :adapter_not_authorized
             | :target_check_timeout
             | {:target_ownership_denied, term()}
             | {:target_check_crashed, term()}
             | term()}
  def bind(%URI{} = session_uri, adapter_id, target_id, opts, ctx)
      when is_binary(adapter_id) and is_map(opts) and is_map(ctx) do
    # SPEC docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md
    # §3.3 (audit-SPEC CRIT-1 corrected shape + codex PR-AUDIT r1 fix):
    # the facade is a thin wrapper around
    # `FacadeNonceTable.claim_nonce/4`, which itself enforces ALL 4
    # gates internally via `Gates.run_all/4` against the REGISTRY-
    # resolved adapter module (NOT a caller-supplied module).
    #
    # claim_nonce/4 takes the adapter_id STRING and resolves to the
    # real adapter_module via AdapterRegistry — this closes the
    # spoof-module bypass codex r1 CRIT identified (caller cannot
    # smuggle in a fake module whose adapter_id/0 lies).
    #
    # An in-VM caller bypassing this facade still cannot obtain a
    # nonce without passing Gates 1+2+3+4 against the registry-
    # resolved module. The gates are SoT in
    # `Ezagent.ExternalMirror.Gates`; this facade and `claim_nonce/4`
    # both delegate so they cannot drift (P3).
    #
    # Gate 1 runs INSIDE Gates.run_all BEFORE Gate 0 (lookup_adapter),
    # so a no-cap caller probing fake adapter IDs sees :unauthorized
    # before lookup_adapter could return :unknown_adapter — preserving
    # scenario 0's anti-enumeration property.
    with {:ok, nonce} <-
           FacadeNonceTable.claim_nonce(session_uri, ctx, adapter_id, target_id) do
      do_dispatch_bind(session_uri, adapter_id, target_id, opts, ctx, nonce)
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
  Kind), then APPLIES TWO FILTERS:

  1. **Workspace match** — caller's workspace must equal the
     session's workspace (or caller holds an admin wildcard, which
     bypasses both filters).
  2. **Per-session `:list_bindings` cap** — the caller must hold a
     cap that authorizes `:list_bindings` on that specific session.
     Same-workspace alone is NOT enough; a caller with no
     `Behavior.ExternalMirror` cap on any session sees `[]` even if
     they're in the right workspace.

  Returns `{:ok, [URI.t()]}` where every returned session URI is
  both in the caller's workspace AND covered by a held
  `:list_bindings` cap. Callers holding an admin wildcard cap (with
  `workspace_uri: :any` for the matching `kind/behavior`) bypass
  both filters and see every session.

  ## codex r2 HIGH-2 fix (2026-05-25) — workspace filter
  ## codex r3 HIGH-1 fix (2026-05-25) — per-session cap filter

  Pre-r2, `sessions_for_adapter/1` returned every matching session
  across all workspaces. Pre-r3, the workspace filter alone let a
  same-workspace caller with NO `Behavior.ExternalMirror` caps still
  enumerate every bound session URI in their workspace (an
  information-disclosure side-channel). The r3 fix adds a second
  intersection against caller caps so the read surface matches the
  CapBAC protection on `list_bindings/2` (which already gates by the
  per-session cap via the dispatch path).
  """
  @spec sessions_for_adapter(adapter_id :: String.t(), caller_ctx()) :: {:ok, [URI.t()]}
  def sessions_for_adapter(adapter_id, ctx) when is_binary(adapter_id) and is_map(ctx) do
    all_sessions = safe_sessions_for_adapter(adapter_id)

    filtered =
      if admin_wildcard?(ctx) do
        all_sessions
      else
        caller_workspace = caller_workspace(ctx)

        all_sessions
        |> Enum.filter(&session_in_workspace?(&1, caller_workspace))
        |> Enum.filter(&caller_can_list_bindings?(ctx, &1))
      end

    {:ok, filtered}
  end

  # codex r3 HIGH-1 (2026-05-25): does the caller hold a cap that
  # authorizes `:list_bindings` on `session_uri`? Uses the same
  # `Ezagent.Capability.matches?/2` shape `Ezagent.Capability.cap_for_action/3`
  # builds for dispatch step 5.5 — so the answer here matches what
  # the dispatch-gated `list_bindings/2` would allow.
  defp caller_can_list_bindings?(ctx, %URI{} = session_uri) do
    caps = Map.get(ctx, :caps, MapSet.new())

    needed = %{
      kind: :session,
      behavior: Ezagent.Behavior.ExternalMirror,
      instance: session_uri,
      workspace_uri: workspace_of_or_any(session_uri)
    }

    Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed))
  end

  defp workspace_of_or_any(%URI{} = uri) do
    case Ezagent.Capability.workspace_of(uri) do
      %URI{} = ws -> ws
      :any -> :any
    end
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
  #
  # Audit-SPEC CRIT-1 (2026-05-25): the previous facade-internal helpers
  # `lookup_adapter/1`, `check_session_bind_cap/2`, `check_adapter_allow_cap/3`,
  # `check_workspace_iso/2`, `run_target_ownership_check/3` were ALL lifted
  # to `Ezagent.ExternalMirror.Gates` so `FacadeNonceTable.claim_nonce/4`
  # could call the same SoT (P3) when enforcing gates from a direct-claim
  # bypass attempt. The facade `bind/5` and `claim_nonce/4` both delegate
  # to `Gates.*`; they cannot drift.
  #
  # Read-side helpers (`admin_wildcard?/1`, `caller_workspace/1`,
  # `session_in_workspace?/2`, `caller_can_list_bindings?/2`,
  # `workspace_of_or_any/1`, `cap_admin_shape?/1`) stay here — they're
  # the read-path filter logic for `sessions_for_adapter/2` and
  # `list_bindings/2`, NOT the bind-path gate enforcement.

  defp do_dispatch_bind(%URI{} = session_uri, adapter_id, target_id, opts, ctx, nonce)
       when is_binary(nonce) do
    # Audit-SPEC §3.3: the nonce was already claimed (and gates
    # already enforced) by `FacadeNonceTable.claim_nonce/4` in the
    # caller. Dispatch carries it as `args[:_facade_nonce]`; the
    # action body atomically consumes it via
    # `FacadeNonceTable.consume_nonce/2`. Any mismatch (missing /
    # expired / replayed / tuple mismatch) → action body returns
    # `:bind_must_go_through_facade`.
    target =
      URI.parse("#{URI.to_string(session_uri)}?action=external_mirror.bind")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{
        adapter_id: adapter_id,
        target_id: target_id,
        opts: opts,
        _facade_nonce: nonce
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
