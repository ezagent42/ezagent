defmodule EzagentDomainChat do
  @moduledoc """
  Top-level facade for the chat plugin (Phase 3b-step 1).

  Provides `create_session/2` to dynamically spawn additional Session
  Kinds at runtime (admin LV / mix task / external API / first-login
  wizard can call this).

  ## PR-J (Phase 8c, Allen 2026-05-20)

  The previous `:main_is_static` restriction was removed. `session://default/system/main`
  is no longer a hardcoded static supervisor child of
  `EzagentDomainChat.Application` — it now goes through the same code
  path as every other session, created by the first-login wizard. The
  test environment seeds it via this same facade in
  `EzagentDomainChat.Application` (test-only branch).

  `create_session/2` is the canonical session-creation API: it spawns
  the Kind, binds it to the creator's workspace (derived structurally
  from the caller's entity URI per SPEC v3 §3.3), and joins the
  creator. Idempotent for same short_name — re-call returns the
  existing URI + (re)joins creator.
  """

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Entity.{Session, User}

  require Logger

  @doc """
  Spawn a new Session Kind under `EzagentDomainChat.SessionSupervisor`,
  bind it to the creator's workspace, and join `creator_uri` to it.

  SPEC v3 §3.6 (Phase 9 PR-7) — sessions are
  `session://<template>/<workspace>/<name>`. `short_name` becomes the
  `<name>` segment. The workspace is **derived structurally** from
  `creator_uri` (`Ezagent.URI.entity_workspace_uri/1`) — no silent
  global fallback per SPEC #324. Callers needing a different workspace
  can pass `opts[:workspace_uri]` explicitly (e.g. cross-workspace
  admin flows).

  `opts[:template_name]` is **required** per SPEC #366 (Allen
  2026-05-26, `feedback_let_it_crash_no_workarounds`) — the previous
  silent `"default"` fallback was eliminated. The value becomes the
  session URI's class segment (`session://<template_name>/<workspace>/<short_name>`)
  literally — there is NO `Ezagent.TemplateRegistry.lookup/1` resolution
  here; downstream code treats segment 1 as informational. Operators
  pass:
    * `"default"` for the bootstrap session-naming convention (the
      legacy URI shape ~10 test suites assert against), OR
    * Any key from the current workspace's `session_templates` map
      for tenant flows (LV form sources this directly).

  Missing key raises `ArgumentError`.

  Returns `{:ok, session_uri, meta}` on success where `meta` is
  `%{orchestrator_uri: URI.t() | nil, orchestrator_status: :ready |
  :pending | :failed, orchestrator_error: term() | nil}` — SPEC
  `2026-05-26-session-create-orchestrator-unified` Gap A. The
  `orchestrator_status` field surfaces the result of the auto-spawned
  orchestrator Agent Kind:

    * `:ready` — orchestrator agent is alive (was `:created` or
      `:already_present` per `Session.ensure_orchestrator/3`)
    * `:pending` — orchestrator URI reserved but ownership not yet
      classified; LV should render "pending — refresh in a moment"
    * `:failed` — orchestrator spawn failed; the session itself is
      alive and usable, but `orchestrator_error` carries the reason
      and the LV restart button is the recovery path

  Returns `{:error, reason}` on session-create failure (the orchestrator
  step is only attempted if session creation + cap grant succeed).

  Raises `ArgumentError` if neither `creator_uri` nor
  `opts[:workspace_uri]` is supplied (a `nil` creator with no explicit
  workspace cannot be assigned a workspace structurally).

  Idempotent re-spawn of same short_name returns `{:ok, existing_uri, meta}`
  (via `{:already_started, pid}` → reuse pid).
  """
  @type create_session_meta :: %{
          orchestrator_uri: URI.t() | nil,
          orchestrator_status: :ready | :pending | :failed,
          orchestrator_error: term() | nil
        }

  @spec create_session(String.t(), URI.t() | nil, keyword()) ::
          {:ok, URI.t(), create_session_meta()} | {:error, term()}
  def create_session(short_name, creator_uri \\ nil, opts \\ [])

  def create_session(short_name, creator_uri, opts)
      when is_binary(short_name) and short_name != "" do
    workspace_uri =
      case Keyword.fetch(opts, :workspace_uri) do
        {:ok, ws} ->
          ws

        :error ->
          case creator_uri do
            %URI{scheme: "entity"} = uri ->
              Ezagent.URI.entity_workspace_uri(uri)

            _ ->
              raise ArgumentError,
                    "EzagentDomainChat.create_session/3 requires either a non-nil " <>
                      "entity creator_uri (to derive workspace structurally) or " <>
                      "an explicit opts[:workspace_uri]. Got creator_uri=" <>
                      "#{inspect(creator_uri)}, opts=#{inspect(opts)}."
          end
      end

    template_name = require_template_name!(opts)
    workspace_name = workspace_name_of!(workspace_uri)

    session_uri =
      Ezagent.URI.new!("session://#{template_name}/#{workspace_name}/#{short_name}")

    # codex PR #409 r1 review HIGH-2 — serialize concurrent create_session
    # calls per session_uri. Two callers racing on the same URI used to
    # observe a destructive interleave: A (`:fresh`) hits cap-grant
    # failure mid-finalize, B (`:adopted`) finishes finalize successfully
    # and returns `{:ok, _, _}` to its caller; A's rollback then tears
    # down the Session B's caller observed as live. Wrapping the
    # spawn+finalize+rollback body in a per-URI `:global.set_lock/3`
    # forces adopters to wait until the fresh path commits or rolls
    # back. By the time the second caller takes the lock, the Session
    # is either alive (B sees `:already_started` → `:adopted` finalize,
    # idempotent) or fully gone (B sees `{:ok, pid}` → `:fresh`, gets
    # its own chance to commit). Single-machine BEAM per the project's
    # standing constraint, so `:global` within one node suffices; the
    # `[node()]` scope is explicit so a future clustering change does
    # not silently broaden the lock.
    lock_id = {{:ezagent_domain_chat, :create_session, URI.to_string(session_uri)}, self()}

    try do
      true = :global.set_lock(lock_id, [node()])
      do_create_session(session_uri, workspace_uri, creator_uri)
    after
      _ = :global.del_lock(lock_id, [node()])
    end
  end

  defp do_create_session(%URI{} = session_uri, %URI{} = workspace_uri, creator_uri) do
    # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
    # Session Kind declares EzagentDomainChat.SessionSupervisor via
    # supervisor/0 — destination preserved.
    #
    # RFC #402 (Allen 2026-05-26) — thread the creator URI as
    # `owner_uri` so `Behavior.Chat.init_slice/1` records it on the
    # session's `:chat` slice. The Generator path
    # (`Session.spawn_from_template/2`) does the same; this brings the
    # direct-create path to parity. Falls back to the bootstrap admin
    # for system-internal session creates (`creator_uri == nil`);
    # `data_owner/1` then routes through `Session.owner/1` so the
    # restart-cap grant flows correctly.
    effective_owner = creator_uri || User.admin_uri()
    result = Ezagent.Kind.spawn(Session, %{uri: session_uri, owner_uri: effective_owner})

    # codex PR #408 r2 review HIGH-1 — track whether THIS call freshly
    # created the Session Kind so finalize-step failures can roll the
    # session back. Round-1 only fixed the swallow + short-circuit; the
    # residual leak (live Session + workspace bind + creator-join left
    # behind on cap-grant failure) needed the freshness signal too.
    {session_outcome, finalize_result} =
      case result do
        {:ok, _pid} ->
          {:fresh, finalize_session_create(session_uri, workspace_uri, effective_owner)}

        # `:already_started` = same child spec already in supervisor's children
        # `:already_registered` = Kind.Server.init crashed on KindRegistry.put_new
        # conflict (URI claimed by another pid, possibly outside this supervisor).
        # Both indicate "session exists" — return success + re-bind workspace
        # (idempotent ETS overwrite) + re-attempt join (cast is idempotent on
        # members map).
        {:error, {:already_started, _pid}} ->
          {:adopted, finalize_session_create(session_uri, workspace_uri, effective_owner)}

        {:error, {:already_registered, _}} ->
          {:adopted, finalize_session_create(session_uri, workspace_uri, effective_owner)}

        {:error, reason} ->
          {:spawn_failed, {:error, reason}}
      end

    case finalize_result do
      {:ok, _, _} = ok ->
        ok

      {:error, reason} ->
        # codex PR #408 r2 review HIGH-1 — if THIS call freshly created
        # the Session Kind and finalize_session_create failed (e.g.
        # cap-grant denial), tear it down so the caller observes a
        # CLEAN `{:error, _}` rather than a residue (live Session with
        # workspace binding + creator-join, no orchestrator, no
        # restart-cap on the owner). An adopted session is left alone
        # — finalize is idempotent on the adoption path, and tearing
        # down a session WE didn't create would punish a different
        # caller's setup.
        if session_outcome == :fresh do
          rollback_fresh_session(session_uri, effective_owner)
        end

        {:error, reason}
    end
  end

  # codex PR #408 r2 review HIGH-1 — tear down the partial state
  # `finalize_session_create/3` built before failing. Best-effort: each
  # step swallows its own errors so the original failure reason from
  # the caller still surfaces. Operator-visible audit lives in the
  # Logger.warning the caller's `{:error, _}` produced upstream.
  #
  # codex PR #409 r1 review LOW — exposed as `@doc false` (instead of
  # `defp`) so the rollback invariants (Kind terminated + workspace
  # unbound + kind_snapshots row deleted) can be exercised directly as
  # a deterministic unit test. The integration path through
  # `create_session/3` cannot trigger this rollback for the
  # bare-user-creates-own-session case because `OrchestratorAdmin`'s
  # `data_owner/1` resolves to the session owner (the bare user
  # themselves), so the `IdentityAdmin.check_grant_authorized` cond
  # `caller == owner` short-circuits to `:ok`. Direct unit invocation
  # bypasses that architectural quirk and asserts rollback's own
  # contract (codex r1 LOW).
  @doc false
  @spec rollback_fresh_session(URI.t(), URI.t()) :: :ok
  def rollback_fresh_session(%URI{} = session_uri, %URI{} = creator_uri) do
    require Logger

    Logger.warning(
      "EzagentDomainChat.create_session: rolling back freshly-created " <>
        "session=#{URI.to_string(session_uri)} after finalize failure — " <>
        "tearing down Kind + workspace binding so the caller does not " <>
        "leak partial state (codex PR #408 r2 HIGH-1)."
    )

    # Terminate the Session Kind (no other process owns its lifecycle —
    # we just created it).
    _ = Ezagent.Kind.terminate(session_uri)

    # Unbind workspace (idempotent ETS delete).
    safe(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    # codex PR #409 r1 review HIGH-1 — delete the kind_snapshots row
    # `Kind.Server.init/1` wrote synchronously at spawn time
    # (Session.persistence/0 = {:snapshot, :on_change}, so the initial
    # slice landed in DB the moment the GenServer reached
    # `KindRegistry.put_new` — well before this rollback path). Without
    # this delete, the row outlives the dead Kind: next boot's
    # `ReadyGate` replays every snapshot via `KindSnapshot.list_all/0`,
    # which would resurrect a session whose `create_session/3` failed
    # cap-grant — defeating the whole rollback. Wrapped in `safe/1` per
    # the existing best-effort teardown contract: the Kind is already
    # terminated, an orphan row is the worst-case fallback and the
    # original `{:error, _}` reason still surfaces to the caller.
    safe(fn -> Ezagent.Ecto.KindSnapshot.delete(URI.to_string(session_uri)) end)

    # Creator join — we don't have an `unjoin` primitive and the Session
    # is being torn down anyway, so the slice goes away with the Kind.
    # No additional cleanup needed for chat.join's cast side effects.
    _ = creator_uri
    :ok
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  def create_session(_short_name, _creator, _opts), do: {:error, :short_name_required}

  # Shared finalization for the three success branches of the Session
  # spawn step. Binds workspace, joins creator, grants the
  # OrchestratorAdmin :restart cap, then auto-spawns the orchestrator
  # Agent Kind (SPEC `2026-05-26-session-create-orchestrator-unified`
  # Gap A).
  #
  # Returns `{:ok, session_uri, meta}` where `meta` carries the
  # orchestrator status. `:ok` from the spawn step (any of `:created`,
  # `:already_present`) yields `:ready`; `:partial` yields `:pending`;
  # `:error` yields `:failed` WITH the session still alive — the cap is
  # already granted, so the operator can click Restart in LV. This is
  # NOT a silent fallback per `feedback_let_it_crash_no_workarounds`:
  # the meta map structurally surfaces the failure so callers MUST
  # render it (Invariant #9 — no silent drops at user-facing surfaces).
  defp finalize_session_create(session_uri, workspace_uri, effective_owner) do
    # codex PR #408 review HIGH-1 — convert the linear `:ok = ...` chain
    # to a `with` so cap-grant failure short-circuits BEFORE the
    # orchestrator-ensure step. Pre-fix the cap grant's dispatch result
    # was discarded via `_ = Invocation.dispatch(...)` and the helper
    # unconditionally returned `:ok`; a denied grant therefore allowed
    # `ensure_orchestrator_meta/3` to fire anyway, producing an
    # orchestrator under a Session whose owner could not actually drive
    # Restart. SPEC requires a failed grant to surface as
    # `{:error, reason}` and skip orchestrator spawn.
    with :ok <- Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri),
         :ok <- join_creator(session_uri, effective_owner),
         :ok <- grant_owner_orchestrator_admin_cap(session_uri, effective_owner, workspace_uri) do
      meta = ensure_orchestrator_meta(session_uri, workspace_uri, effective_owner)
      {:ok, session_uri, meta}
    end
  end

  # Translate `Session.ensure_orchestrator/3`'s return shapes to the
  # public meta map. The shapes (per the @spec on
  # `Session.ensure_orchestrator/3`):
  #
  #   {:ok, orch_uri, :created | :already_present}        → :ready
  #   {:ok, orch_uri, _outcome, %{role_degraded: true,..}}→ :ready (degraded)
  #   {:partial, %{orchestrator_pending: uri}}            → :pending
  #   {:error, reason}                                    → :failed (logged)
  #
  # codex PR #408 review HIGH-3 — a `:role_degraded` flag from the cc
  # Template Class (orchestrator-skill-copy failure) keeps the status at
  # `:ready` (the agent IS alive) but populates `orchestrator_error`
  # with the degraded reason AND emits a notification to the owner so
  # Invariant #9 (no silent drops at user-facing surfaces) is honored.
  defp ensure_orchestrator_meta(session_uri, workspace_uri, owner_uri) do
    # codex PR #408 review HIGH-3 — call the 4-tuple-capable variant so
    # the role-bootstrap degradation surfaces in the meta map per
    # Invariant #9.
    case Session.ensure_orchestrator_with_meta(session_uri, workspace_uri, owner_uri) do
      {:ok, %URI{} = orch_uri, _outcome, %{role_degraded: true} = degraded_meta} ->
        notify_orchestrator_role_degraded(owner_uri, session_uri, orch_uri, degraded_meta)

        %{
          orchestrator_uri: orch_uri,
          orchestrator_status: :ready,
          orchestrator_error: {:role_degraded, Map.get(degraded_meta, :role_degraded_reason)}
        }

      {:ok, %URI{} = orch_uri, _outcome} ->
        %{
          orchestrator_uri: orch_uri,
          orchestrator_status: :ready,
          orchestrator_error: nil
        }

      {:ok, %URI{} = orch_uri, _outcome, _meta} ->
        # Forward-compat: an `{:ok, _, _, _}` shape without role_degraded
        # is still `:ready` with no error.
        %{
          orchestrator_uri: orch_uri,
          orchestrator_status: :ready,
          orchestrator_error: nil
        }

      {:partial, %{orchestrator_pending: %URI{} = pending_uri}} ->
        %{
          orchestrator_uri: pending_uri,
          orchestrator_status: :pending,
          orchestrator_error: nil
        }

      {:error, reason} ->
        Logger.warning(
          "EzagentDomainChat.create_session: orchestrator spawn failed for " <>
            "session=#{URI.to_string(session_uri)}: #{inspect(reason)} — " <>
            "session is alive, operator may click Restart in LV to retry " <>
            "(SPEC 2026-05-26-session-create-orchestrator-unified Gap A)"
        )

        %{
          orchestrator_uri: nil,
          orchestrator_status: :failed,
          orchestrator_error: reason
        }
    end
  end

  # codex PR #408 review HIGH-3 — notify the session owner that the
  # orchestrator's role-bootstrap (skill copy / CLAUDE.md hint) failed.
  # The agent itself is alive; the orchestrator-specific UX is
  # degraded. Best-effort: a notify failure logs but never bubbles up
  # past the meta map (the orchestrator IS up — the notification is the
  # UX surfacing, not the source of truth).
  defp notify_orchestrator_role_degraded(
         %URI{scheme: "entity", host: "user"} = owner_uri,
         %URI{} = session_uri,
         %URI{} = orch_uri,
         degraded_meta
       ) do
    reason = Map.get(degraded_meta, :role_degraded_reason)

    Logger.warning(
      "EzagentDomainChat.create_session: orchestrator role-bootstrap DEGRADED for " <>
        "session=#{URI.to_string(session_uri)} orchestrator=#{URI.to_string(orch_uri)} " <>
        "reason=#{inspect(reason)} — the agent is alive but the " <>
        "ezagent-session-orchestrator skill / CLAUDE.md hint did not load. " <>
        "The session owner has been notified (Invariant #9)."
    )

    try do
      _ =
        Ezagent.Notifications.notify(owner_uri, %{
          type: :orchestrator_role_degraded,
          body: %{
            text:
              "Orchestrator agent started but the orchestrator skill failed to load. " <>
                "It will behave as a plain claude session. " <>
                "Reason: #{inspect(reason)}",
            session_uri: session_uri,
            orchestrator_uri: orch_uri,
            reason: inspect(reason)
          },
          source: __MODULE__
        })
    rescue
      error ->
        Logger.warning(
          "EzagentDomainChat.create_session: notify(:orchestrator_role_degraded) to " <>
            "#{URI.to_string(owner_uri)} raised #{inspect(error)} — the orchestrator " <>
            "is still alive; this is the notification path failing, not the spawn."
        )
    end

    :ok
  end

  # Non-user owner (e.g. system principal or agent) — no inbox to notify;
  # the Logger warning above is the audit trail.
  defp notify_orchestrator_role_degraded(_owner, %URI{} = session_uri, %URI{} = orch_uri, meta) do
    reason = Map.get(meta, :role_degraded_reason)

    Logger.warning(
      "EzagentDomainChat.create_session: orchestrator role-bootstrap DEGRADED for " <>
        "session=#{URI.to_string(session_uri)} orchestrator=#{URI.to_string(orch_uri)} " <>
        "reason=#{inspect(reason)} — owner is not a user URI; no inbox notification sent."
    )

    :ok
  end

  # workspace://<name> → "<name>". Raises ArgumentError if the URI
  # isn't a bare workspace URI (helps catch passing entity / session
  # URIs by accident).
  defp workspace_name_of!(%URI{scheme: "workspace", host: name}) when is_binary(name),
    do: name

  defp workspace_name_of!(other),
    do: raise(ArgumentError, "expected %URI{scheme: \"workspace\"}, got: #{inspect(other)}")

  # SPEC #366 (Allen 2026-05-26) — eliminate the silent `"default"`
  # template-class fallback. Callers MUST pass `:template_name` in opts.
  # The previous code (`Keyword.get(opts, :template_name, "default")`)
  # let LV/CLI/test sites omit the choice and silently land in the
  # `session://default/…` namespace — operationally invisible, blocks
  # tenant-customized session templates per the same reasoning as
  # `feedback_let_it_crash_no_workarounds`.
  defp require_template_name!(opts) do
    case Keyword.fetch(opts, :template_name) do
      {:ok, name} when is_binary(name) and name != "" ->
        name

      {:ok, other} ->
        raise ArgumentError,
              "EzagentDomainChat.create_session/3 requires opts[:template_name] to be " <>
                "a non-empty String, got: #{inspect(other)}. Per SPEC #366 the silent " <>
                "`\"default\"` fallback was removed; pick a class explicitly from the " <>
                "workspace's `session_templates` map (or use `\"default\"` literally " <>
                "for the bootstrap session-naming convention)."

      :error ->
        raise ArgumentError,
              "EzagentDomainChat.create_session/3 requires opts[:template_name] " <>
                "(SPEC #366, Allen 2026-05-26). The previous silent `\"default\"` " <>
                "fallback was removed. Callers — LV forms, CLI tasks, test seeds, " <>
                "bootstrap — must choose a template class explicitly. Examples:\n" <>
                "  * Bootstrap / preserve existing URI shape: `template_name: \"default\"`\n" <>
                "  * Tenant flows: `template_name: <key from workspace.session_templates>`\n" <>
                "Got: opts=#{inspect(opts)}."
    end
  end

  @doc """
  Return all known Session URIs (KindRegistry session:// entries),
  including main + all dynamically-created sessions. Used by LV
  sidebar render.

  Task #55 (Allen 2026-05-27) — the unfiltered list is a
  cross-workspace leak surface: every LV mounted in workspace X
  was rendering sessions from workspace Y. Prefer the
  workspace-scoped `list_sessions/1` overload below for any
  operator-facing listing. Callers needing an admin-wide view (CI
  invariant tests, batch utilities) keep this arity for
  enumeration across tenants.
  """
  @spec list_sessions :: [URI.t()]
  def list_sessions do
    KindRegistry.list_all()
    |> Enum.filter(fn {uri_str, _pid} -> String.starts_with?(uri_str, "session://") end)
    |> Enum.map(fn {uri_str, _pid} -> Ezagent.URI.new!(uri_str) end)
    |> Enum.sort_by(&URI.to_string/1)
  end

  @doc """
  Return Session URIs whose workspace segment matches
  `workspace_uri`. SPEC v3 §5.15 — `session://<template>/<workspace>/<name>`
  carries workspace as the second path segment; this helper extracts
  it structurally (no `WorkspaceRegistry` lookup).

  Task #55 (Allen 2026-05-27). The LV session sidebar / `/admin/sessions`
  list MUST filter by the operator's current workspace; rendering
  sessions across tenants is a cross-workspace display leak.
  """
  @spec list_sessions(URI.t()) :: [URI.t()]
  def list_sessions(%URI{scheme: "workspace", host: workspace_name})
      when is_binary(workspace_name) and workspace_name != "" do
    list_sessions()
    |> Enum.filter(fn %URI{path: path} -> session_in_workspace?(path, workspace_name) end)
  end

  # `session://` URI shape per SPEC v3 §5.15:
  #   `session://<template>/<workspace>/<name>` → URI parsed as
  #   `%URI{scheme: "session", host: <template>, path: "/<workspace>/<name>"}`.
  # The workspace segment is the FIRST path segment (post-leading-slash).
  defp session_in_workspace?("/" <> rest, workspace_name) do
    case String.split(rest, "/", parts: 2) do
      [^workspace_name, _name] -> true
      _ -> false
    end
  end

  defp session_in_workspace?(_, _), do: false

  # RFC #402 (Allen 2026-05-26) — grant the session creator the
  # `Behavior.OrchestratorAdmin :restart` cap on this session so the
  # `OrchestratorHealthCard` LV renders the Restart button for them
  # (and a non-creator gets nothing). Idempotent: re-calling
  # `create_session/3` for the same session re-enters this path; the
  # cap-equality check inside the helper skips a re-grant when a
  # logically-equal cap row is already on the owner.
  #
  # Mirrors the same grant `Session.spawn_from_template/2` does for
  # the orchestrator-template path; here it covers the direct-create
  # path (`create_session/3` without going through SessionTemplate
  # materialization).
  defp grant_owner_orchestrator_admin_cap(
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    want = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.Behavior.OrchestratorAdmin,
      # SPEC 2026-05-27 capability-action-axis — OrchestratorAdmin
      # has a single action `:restart` (per `actions/0`); make it
      # explicit so the cap matches the narrow needed-cap shape
      # admin_live's `caller_can_restart_orchestrator?` constructs.
      action: :restart,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    current = Ezagent.Identity.list_caps_for(owner_uri)

    has_equiv? =
      Enum.any?(current, fn cap ->
        match?(%Ezagent.Capability{}, cap) and
          cap.kind == want.kind and
          cap.behavior == want.behavior and
          # SPEC 2026-05-27 capability-action-axis — include action
          # in the equivalence check via `action_of/1` for snapshot-
          # restored old-shape tolerance.
          Ezagent.Capability.action_of(cap) == Ezagent.Capability.action_of(want) and
          cap.instance == want.instance and
          cap.workspace_uri == want.workspace_uri and
          cap.granted_by == want.granted_by
      end)

    if has_equiv? do
      :ok
    else
      target = Ezagent.URI.with_action(owner_uri, :identity, :grant_cap)
      cap = %{want | granted_at: DateTime.utc_now()}

      # codex PR #408 review HIGH-1 — dispatch result MUST be checked.
      # Pre-fix `_ = Invocation.dispatch(...); :ok` silently swallowed
      # a denied grant, letting `finalize_session_create/3` proceed to
      # spawn the orchestrator even though the owner could not actually
      # restart it. Use `:cast`-style reply but :call mode so we observe
      # the result; `reply: :ignore` was the silent-swallow vector.
      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          # SPEC caps-cleanup-v1 §4.4 — granting an ownership cap at
          # session-create time is template-materialization-equivalent;
          # runs under `system://template-materialize` (closed
          # Catalog). Owner stays as caller for provenance.
          ctx: %{
            caller: owner_uri,
            caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
            reply: {:caller_inbox, self()}
          }
        })

      case result do
        {:ok, _} ->
          :ok

        :ok ->
          :ok

        {:error, reason} ->
          {:error, {:orchestrator_admin_cap_grant_failed, reason}}

        other ->
          {:error, {:orchestrator_admin_cap_grant_unexpected, other}}
      end
    end
  end

  defp join_creator(session_uri, creator_uri) do
    # PR-M (Allen 2026-05-20) — `chat.join` requires the member's Kind
    # alive in KindRegistry (see Behavior.Chat.invoke(:join) — returns
    # `{:error, {:member_not_registered, _}}` if absent). In production
    # the login path already calls `Ezagent.Entity.ensure_spawned/1`
    # before the wizard reaches create_session. For mix tasks /
    # boot-time test seeds, the test-env admin Kind seed in
    # `EzagentDomainIdentity.Application` covers admin. Demand-spawn
    # any non-admin caller here as belt-and-suspenders — idempotent
    # ({:ok, pid} for already-alive).
    _ = Ezagent.SpawnRegistry.spawn(creator_uri)

    target = Ezagent.URI.with_action(session_uri, :chat, :join)

    _ =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{member: creator_uri},
        # SPEC caps-cleanup-v1 §4.4 — Session creator-join is
        # Session slice-internal (member sync); runs under
        # `system://session-internal` (closed Catalog).
        ctx: %{
          caller: creator_uri,
          caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
          reply: :ignore
        }
      })

    :ok
  end
end
