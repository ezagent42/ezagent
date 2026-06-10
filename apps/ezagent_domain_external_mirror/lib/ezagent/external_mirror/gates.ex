defmodule Ezagent.ExternalMirror.Gates do
  @moduledoc """
  `Ezagent.ExternalMirror.Gates` — the four canonical bind-gate
  checks per audit SPEC
  `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md`
  §2:

  1. **Gate 1** — `check_session_bind_cap/2` (session-level `:bind` cap).
  2. **Gate 0/lookup** — `lookup_adapter/1` (run AFTER Gate 1 so
     no-cap callers cannot enumerate adapter IDs).
  3. **Gate 2** — `check_adapter_allow_cap/3` (per-adapter allow cap).
  4. **Gate 3** — `check_workspace_iso/2` (facade pre-check of
     workspace isolation; defense-in-depth at dispatch step 5.6).
  5. **Gate 4** — `run_target_ownership_check/3` (adapter I/O,
     bounded Task with timeout).

  ## Why an extracted module — closing audit-SPEC CRIT-1

  Per SPEC §3.3, `FacadeNonceTable.claim_nonce/4` is no longer a
  freely-callable nonce minter — it is the gate-enforcing entry
  point. Both `Ezagent.ExternalMirror.bind/5` (the public facade)
  AND `FacadeNonceTable.claim_nonce/4` (the trust-transfer claim
  step) must run the SAME 4 gates in the SAME canonical order.

  Extracting the gates into a shared module is the structural fix:

  - Single source of truth for gate enforcement logic (P3).
  - The facade and `claim_nonce` cannot drift — both call
    `Gates.run_all/4`.
  - A future caller (admin LV, CLI, etc.) that needs the same
    gate semantics imports `Gates` rather than duplicating the
    sequence.

  ## Public API

  - `run_all/4` — runs all 4 gates in canonical order; returns
    `{:ok, adapter_module}` on full pass or the first gate's
    `{:error, reason}` on miss.
  - The individual `check_*/N` and `lookup_adapter/1` and
    `run_target_ownership_check/3` functions remain public for
    callers that need partial enforcement (e.g. read-side
    facades that only need Gate 1).

  ## Threat model

  See SPEC §3.4 for the corrected forgery analysis. The gates +
  the `:private`-ETS-backed nonce table together close every
  in-VM forgery path:

  - In-VM caller calling `claim_nonce/4` directly → gates run
    inside, no nonce minted unless gates pass.
  - In-VM caller reading the nonce ETS → `:private` denies all
    non-owner reads.
  - In-VM caller writing the nonce ETS → `:private` denies all
    non-owner writes.

  See `Ezagent.ExternalMirror.FacadeNonceTable` moduledoc for
  the ETS access-mode rationale.
  """

  alias Ezagent.ExternalMirror.AdapterRegistry

  @default_target_check_timeout 5_000

  @typedoc "Same caller-context shape as `Ezagent.ExternalMirror.caller_ctx/0`."
  @type caller_ctx :: %{
          required(:caller) => URI.t(),
          required(:caps) => MapSet.t(Ezagent.Capability.t()),
          optional(:reply) => Ezagent.Invocation.reply_target()
        }

  @doc """
  Run all four gates in canonical order per SPEC §2:

  1. Gate 1 — session bind cap
  2. Gate 0 — adapter lookup (AFTER Gate 1 — closes enumeration leak)
  3. Gate 2 — per-adapter allow cap
  4. Gate 3 — workspace isolation
  5. Gate 4 — `target_ownership_check` (adapter I/O, bounded)

  Returns `{:ok, adapter_module}` on full pass, or the FIRST gate's
  `{:error, reason}` on miss. Subsequent gates are not run on miss
  (short-circuit).

  Information-leak property: a caller missing Gate 1 sees
  `{:error, :unauthorized}` for EVERY `adapter_id` (real or fake),
  because the adapter lookup happens AFTER Gate 1. They cannot
  distinguish "adapter doesn't exist" from "I'm not authorized" by
  probing.
  """
  @spec run_all(URI.t(), caller_ctx(), String.t(), term()) ::
          {:ok, module()}
          | {:error,
             :unknown_adapter
             | :unauthorized
             | :adapter_not_authorized
             | :not_bindable
             | :cross_workspace_denied
             | :target_check_timeout
             | {:target_ownership_denied, term()}
             | {:target_check_crashed, term()}}
  def run_all(%URI{} = session_uri, ctx, adapter_id, target_id)
      when is_binary(adapter_id) and is_map(ctx) do
    with :ok <- check_session_bind_cap(ctx, session_uri),
         {:ok, adapter_module} <- lookup_adapter(adapter_id),
         # P3-1 Finding 2 — only `:push` adapters are bindable. A `:pull`
         # adapter has no per-binding transport (no `target_ownership_check/2`,
         # no Binding/Worker); submitting it to the bind flow must be
         # rejected cleanly here, BEFORE `run_target_ownership_check/3`
         # (which would otherwise crash on the missing callback). Placed
         # AFTER Gate 1 (`check_session_bind_cap`) + `lookup_adapter` so a
         # no-cap caller is still rejected by Gate 1 first (the enumeration
         # property of Gate 0/1 is preserved — bindability is a structural
         # property of the adapter, not a per-caller authorization).
         :ok <- check_adapter_bindable(adapter_module),
         :ok <- check_adapter_allow_cap(ctx, session_uri, adapter_module),
         :ok <- check_workspace_iso(ctx, session_uri),
         caller_uri = Map.fetch!(ctx, :caller),
         :ok <- run_target_ownership_check(adapter_module, caller_uri, target_id) do
      {:ok, adapter_module}
    end
  end

  # ----- Push-only bind guard (P3-1 Finding 2) ------------------------------

  @doc """
  Gate (P3-1) — only `:push` adapters may enter the bind flow. A `:pull`
  adapter (served on demand by its caller's Phoenix channel, P3-2) has no
  per-binding transport, so binding it is a structural error. Returns
  `{:error, :not_bindable}` for a pull adapter; `:ok` for a push adapter.
  """
  @spec check_adapter_bindable(module()) :: :ok | {:error, :not_bindable}
  def check_adapter_bindable(adapter_module) when is_atom(adapter_module) do
    case Ezagent.ExternalMirror.Adapter.kind_of(adapter_module) do
      :push -> :ok
      :pull -> {:error, :not_bindable}
    end
  end

  # ----- Gate 0: adapter lookup ---------------------------------------------

  @doc "Resolve `adapter_id` via `AdapterRegistry`. Returns `{:error, :unknown_adapter}` on miss."
  @spec lookup_adapter(String.t()) :: {:ok, module()} | {:error, :unknown_adapter}
  def lookup_adapter(adapter_id) when is_binary(adapter_id) do
    case AdapterRegistry.lookup(adapter_id) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, :unknown_adapter}
    end
  end

  # ----- Gate 1: session bind cap -------------------------------------------

  @doc """
  Gate 1 — caller holds the session-level `Behavior.ExternalMirror`
  `:bind` cap. Inlined here so it runs BEFORE Gate 4 (adapter I/O).

  Returns `{:error, :unauthorized}` on miss. Same atom dispatch
  step 5.5 would return.
  """
  @spec check_session_bind_cap(caller_ctx(), URI.t()) :: :ok | {:error, :unauthorized}
  def check_session_bind_cap(ctx, %URI{} = session_uri) do
    instance = Ezagent.URI.instance(session_uri)
    workspace_uri = workspace_or_any(session_uri)

    needed = %{
      kind: :session,
      behavior: Ezagent.Behavior.ExternalMirror,
      # SPEC 2026-05-27 capability-action-axis — Gate 1 enforces the
      # `:bind` action on Behavior.ExternalMirror. Narrow held caps
      # (e.g. `:unbind` or `:list_bindings`) must NOT satisfy this gate.
      action: :bind,
      instance: instance,
      workspace_uri: workspace_uri
    }

    caps = Map.get(ctx, :caps, MapSet.new())

    if Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed)) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  # ----- Gate 2: per-adapter allow cap --------------------------------------

  @doc """
  Gate 2 per SPEC §4.2 — caller holds the per-adapter allow cap on
  the session. Returns `{:error, :adapter_not_authorized}` on miss.
  """
  @spec check_adapter_allow_cap(caller_ctx(), URI.t(), module()) ::
          :ok | {:error, :adapter_not_authorized}
  def check_adapter_allow_cap(ctx, %URI{} = session_uri, adapter_module) do
    %{behavior_module: behavior_module} = adapter_module.cap_subject()
    instance = Ezagent.URI.instance(session_uri)
    workspace_uri = workspace_or_any(session_uri)

    # SPEC 2026-05-27 capability-action-axis — per-adapter Allow
    # Behaviors are convention cap-only with a single action (e.g.
    # `:allow_feishu`). Derive the action from `actions/0`; fall back
    # to `:any` for adapters whose marker Behavior lacks the callback
    # (defensive — should not happen for compliant adapters).
    allow_action =
      case adapter_allow_action(behavior_module) do
        nil -> :any
        atom -> atom
      end

    needed = %{
      kind: :session,
      behavior: behavior_module,
      action: allow_action,
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

  # ----- Gate 3: workspace iso pre-check ------------------------------------

  @doc """
  Gate 3 per audit SPEC §2 — facade pre-check of workspace
  isolation. Saves the bounded 5s `target_ownership_check` round-trip
  on a cross-workspace target the adapter would never legitimately
  serve. Defense in depth: dispatch step 5.6 ALSO enforces this.

  Admin wildcard (cap with `workspace_uri: :any` for the admin
  shapes) bypasses the check — operator tooling needs to bind
  across workspaces.

  Returns `{:error, :cross_workspace_denied}` on miss — the same
  atom dispatch step 5.6 would return.
  """
  @spec check_workspace_iso(caller_ctx(), URI.t()) ::
          :ok | {:error, :cross_workspace_denied}
  def check_workspace_iso(ctx, %URI{} = session_uri) do
    if admin_wildcard?(ctx) do
      :ok
    else
      caller_ws = caller_workspace(ctx)

      case Ezagent.Capability.workspace_of(session_uri) do
        %URI{} = session_ws ->
          case caller_ws do
            %URI{} = c_ws ->
              if URI.to_string(session_ws) == URI.to_string(c_ws) do
                :ok
              else
                {:error, :cross_workspace_denied}
              end

            :any ->
              # Caller URI is workspace-less (e.g. system caller without
              # a workspace anchor) — let dispatch step 5.6 handle this
              # case authoritatively. Pass through here.
              :ok
          end

        :any ->
          # Session URI is workspace-less (class-wide cap path) —
          # workspace iso is N/A; pass through.
          :ok
      end
    end
  end

  # ----- Gate 4: target ownership check (adapter I/O) -----------------------

  @doc """
  Gate 4 per SPEC §4.2 / §8.2 — adapter membership check in a
  supervised Task with bounded timeout. The Task runs in the caller
  process (via `Task.Supervisor.async_nolink/3`) so the Session
  GenServer is never blocked on adapter I/O.

  Returns:
  - `:ok` — adapter confirmed caller owns the target
  - `{:error, {:target_ownership_denied, reason}}` — adapter denied
  - `{:error, :target_check_timeout}` — adapter exceeded timeout
  - `{:error, {:target_check_crashed, reason}}` — adapter raised
  """
  @spec run_target_ownership_check(module(), URI.t(), term()) ::
          :ok
          | {:error,
             :target_check_timeout
             | {:target_ownership_denied, term()}
             | {:target_check_crashed, term()}}
  def run_target_ownership_check(adapter_module, %URI{} = caller, target_id) do
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

  # ----- Helpers ------------------------------------------------------------

  @doc """
  Caller workspace extracted from `ctx.caller` URI, or `:any` if
  the caller URI is workspace-less.
  """
  @spec caller_workspace(caller_ctx()) :: URI.t() | :any
  def caller_workspace(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = caller_uri -> Ezagent.Capability.workspace_of(caller_uri)
      _ -> :any
    end
  end

  @doc """
  Returns `true` iff the caller holds an admin-wildcard cap that
  bypasses workspace iso (cap with `workspace_uri: :any` and the
  admin shape — either `:any/:any/:any` or
  `:session/Behavior.ExternalMirror/:any`).
  """
  @spec admin_wildcard?(caller_ctx()) :: boolean()
  def admin_wildcard?(ctx) do
    caps = Map.get(ctx, :caps, MapSet.new())

    Enum.any?(caps, fn cap ->
      cap.workspace_uri == :any and cap_admin_shape?(cap)
    end)
  end

  # SPEC 2026-05-27 capability-action-axis (codex impl PR review MED):
  # the admin-wildcard bypass must require `action: :any` so narrow
  # action caps (e.g. cross-workspace `:bind` cap) don't masquerade as
  # admin authority that bypasses workspace-iso. The narrow cap is
  # still authoritative for its specific action via dispatch step 5.5;
  # the workspace-iso bypass is a STRICTLY-BROADER admin tier.
  # codex r4 SPEC option-B: legacy fallback REMOVED. Explicit
  # `action: :any` required for admin recognition.
  defp cap_admin_shape?(%{kind: :any, behavior: :any, action: :any, instance: :any}),
    do: true

  defp cap_admin_shape?(%{
         kind: :session,
         behavior: Ezagent.Behavior.ExternalMirror,
         action: :any,
         instance: :any
       }),
       do: true

  defp cap_admin_shape?(_), do: false

  defp workspace_or_any(%URI{} = uri) do
    case Ezagent.Capability.workspace_of(uri) do
      %URI{} = ws -> ws
      :any -> :any
    end
  end

  # SPEC 2026-05-27 capability-action-axis — derive the single action
  # of a per-adapter Allow Behavior (convention: cap-only with one
  # action like `:allow_feishu`). Returns the action atom when exactly
  # one is declared; otherwise nil (caller falls back to `:any`).
  defp adapter_allow_action(behavior_module) when is_atom(behavior_module) do
    if Code.ensure_loaded?(behavior_module) and
         function_exported?(behavior_module, :actions, 0) do
      case behavior_module.actions() do
        [action] when is_atom(action) -> action
        _ -> nil
      end
    else
      nil
    end
  end
end
