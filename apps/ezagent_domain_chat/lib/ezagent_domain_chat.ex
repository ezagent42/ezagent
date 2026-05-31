defmodule EzagentDomainChat do
  @moduledoc """
  Top-level facade for the chat plugin (Phase 3b-step 1).

  Provides `create_session/3` to dynamically spawn additional Session
  Kinds at runtime (admin LV / mix task / external API / first-login
  wizard can call this).

  ## PR-J (Phase 8c, Allen 2026-05-20)

  The previous `:main_is_static` restriction was removed. `session://default/system/main`
  is no longer a hardcoded static supervisor child of
  `EzagentDomainChat.Application` — it now goes through the same code
  path as every other session, created by the first-login wizard. The
  test environment seeds it via this same facade in
  `EzagentDomainChat.Application` (test-only branch).

  ## 2026-05-31 — atomic, single-entry session creation

  `create_session/3` is the canonical session-creation API and the
  **single live entry** (the dead Generator path
  `Session.spawn_from_template/2` was deleted — SPEC
  `docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`
  §1/§7). It runs a single fail-loud sequence (§4):

    1. resolve + validate + build the `session://<template>/<ws>/<name>`
       URI; resolve `template_name` → a real SessionTemplate (fail-loud
       if absent);
    2. spawn the Session Kind (`{:already_started}`/`{:already_registered}`
       → return existing, idempotent, NO adoption re-finalize);
    3. bind the workspace (one idempotent `WorkspaceRegistry.bind`);
    4. materialize the orchestrator working-copy fields EARLY — write
       `orchestrator_template_uri` + `session_template_uri` to the
       session working copy BEFORE the orchestrator can JOIN. A template
       with no orchestrator → plain session, skip 5-7;
    5. ensure the orchestrator (`Session.ensure_orchestrator/3`); ensure
       FAILURE → rollback → `{:error, _}` (no `:pending`, no
       `:failed`-alive);
    6. grant the orchestrator its scoped caps + ONE owner
       `OrchestratorAdmin :restart` cap;
    7. register the orchestrator MCP context;
    8. join `[owner, orchestrator]` as session members;
    9. on any 4-8 failure: minimal rollback (terminate orchestrator +
       Session Kind, unbind workspace, delete snapshot row).
  """

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Entity.{Session, User}

  require Logger

  @doc """
  Spawn a new Session Kind under `EzagentDomainChat.SessionSupervisor`,
  bind it to the creator's workspace, materialize + ensure its
  orchestrator atomically, and join the creator + orchestrator.

  SPEC v3 §3.6 (Phase 9 PR-7) — sessions are
  `session://<template>/<workspace>/<name>`. `short_name` becomes the
  `<name>` segment. The workspace is **derived structurally** from
  `creator_uri` (`Ezagent.URI.entity_workspace_uri/1`) — no silent
  global fallback per SPEC #324. Callers needing a different workspace
  can pass `opts[:workspace_uri]` explicitly (e.g. cross-workspace
  admin flows).

  `opts[:template_name]` is **required** per SPEC #366 (Allen
  2026-05-26, `feedback_let_it_crash_no_workarounds`). The value becomes
  the session URI's class segment
  (`session://<template_name>/<workspace>/<short_name>`) literally AND —
  2026-05-31 — is resolved to a live `SessionTemplate` Kind in the
  session's workspace so the orchestrator working copy can be
  materialized from it. Operators pass:
    * `"default"` for the bootstrap session-naming convention (resolves
      to the boot-seeded `template://session/<ws>/default@<hash>`), OR
    * Any key from the current workspace's `session_templates` map
      for tenant flows (LV form sources this directly).

  Missing key raises `ArgumentError`.

  Returns `{:ok, session_uri, meta}` on success where `meta` is
  `%{orchestrator_uri: URI.t() | nil, orchestrator_status: :ready |
  :failed, orchestrator_error: term() | nil}`.

  2026-05-31 orchestrator-startup-atomicity §4 — `orchestrator_status`
  is now a **2-state** shape:

    * `:ready` — orchestrator agent is alive (was `:created` or
      `:already_present` per `Session.ensure_orchestrator/3`). May carry
      a non-nil `orchestrator_error` of the form `{:role_degraded,
      reason}` when the agent is up but its orchestrator skill failed to
      load (`:ready+degraded`); the agent is still usable.
    * `:failed` — this arm only appears for a *plain session* (a
      SessionTemplate with no `orchestrator_template_uri`): there is no
      orchestrator to bring up, so the meta carries `:failed` with a nil
      URI to signal "this session has no orchestrator role". An
      orchestrator *ensure failure* does NOT surface as `:failed` here —
      it rolls the whole create back and returns `{:error, _}`
      (fail-loud, no half-started zombie).

  Returns `{:error, reason}` when session creation, the workspace bind,
  OTU materialization, orchestrator ensure, cap grant, or MCP
  registration fails. Any 4-8 failure rolls back (terminate
  orchestrator + Session, unbind workspace, delete the snapshot row).

  Raises `ArgumentError` if neither `creator_uri` nor
  `opts[:workspace_uri]` is supplied (a `nil` creator with no explicit
  workspace cannot be assigned a workspace structurally).

  Idempotent re-spawn of same short_name returns `{:ok, existing_uri, meta}`
  (via `{:already_started, pid}` → reuse pid, NO adoption re-finalize).
  """
  @type create_session_meta :: %{
          orchestrator_uri: URI.t() | nil,
          orchestrator_status: :ready | :failed,
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

    # 2026-05-31 orchestrator-startup-atomicity §4 — a thin per-URI lock.
    # With adoption gone + spawn idempotent, the `:fresh`-rollback vs
    # `:adopted`-commit interleave that originally justified this lock
    # (codex #409) no longer exists. We KEEP a thin per-URI lock because
    # it remains cheap and clearly safe: two callers racing the SAME URI
    # would otherwise both run the 4-8 setup + a possible rollback,
    # tearing each other's partial state. Single-machine BEAM per the
    # project constraint, so `:global` within `[node()]` suffices; the
    # explicit `[node()]` scope keeps a future clustering change from
    # silently broadening the lock.
    lock_id = {{:ezagent_domain_chat, :create_session, URI.to_string(session_uri)}, self()}

    try do
      true = :global.set_lock(lock_id, [node()])
      do_create_session(session_uri, workspace_uri, creator_uri, template_name)
    after
      _ = :global.del_lock(lock_id, [node()])
    end
  end

  def create_session(_short_name, _creator, _opts), do: {:error, :short_name_required}

  # The atomic create_session flow (SPEC §4). A single fail-loud
  # sequence; any 4-8 failure rolls back the freshly-created session.
  defp do_create_session(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         creator_uri,
         template_name
       )
       when is_binary(template_name) do
    # RFC #402 (Allen 2026-05-26) — thread the creator URI as `owner_uri`
    # so `Behavior.Chat.init_slice/1` records it on the session's `:chat`
    # slice. Falls back to the bootstrap admin for system-internal
    # creates (`creator_uri == nil`).
    effective_owner = creator_uri || User.admin_uri()

    # Step 1b — resolve `template_name` → a real SessionTemplate in the
    # session's workspace, fail-loud if absent (SPEC §4 step 1).
    case resolve_session_template!(template_name, workspace_uri) do
      {:error, _} = err ->
        err

      {:ok, session_template_uri, template_content} ->
        do_create_session_with_template(
          session_uri,
          workspace_uri,
          effective_owner,
          session_template_uri,
          template_content
        )
    end
  end

  defp do_create_session_with_template(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = effective_owner,
         %URI{} = session_template_uri,
         template_content
       ) do
    # Step 2 — spawn the Session Kind. `{:already_started}` /
    # `{:already_registered}` → return existing (idempotent, NO adoption
    # re-finalize). The orchestrator working copy + caps + MCP context +
    # member joins are all idempotent, but for an already-existing
    # session we trust the original create committed them — re-running
    # would risk a foreign-orchestrator false positive. We return the
    # existing session with a best-effort orchestrator status read.
    case Ezagent.Kind.spawn(Session, %{uri: session_uri, owner_uri: effective_owner}) do
      {:ok, _pid} ->
        finalize_fresh_session(
          session_uri,
          workspace_uri,
          effective_owner,
          session_template_uri,
          template_content
        )

      {:error, {:already_started, _pid}} ->
        {:ok, session_uri, existing_orchestrator_meta(session_uri, workspace_uri)}

      {:error, {:already_registered, _}} ->
        {:ok, session_uri, existing_orchestrator_meta(session_uri, workspace_uri)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Steps 3-9 for a freshly-spawned Session Kind. Any failure rolls back.
  defp finalize_fresh_session(
         session_uri,
         workspace_uri,
         effective_owner,
         session_template_uri,
         template_content
       ) do
    orchestrator_template_uri = orchestrator_template_uri_of(template_content)

    result =
      with :ok <- Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri),
           :ok <-
             materialize_orchestrator_working_copy(
               session_uri,
               session_template_uri,
               orchestrator_template_uri
             ) do
        case orchestrator_template_uri do
          nil ->
            # Step 4 — plain session (no orchestrator). Join the creator
            # only; skip 5-7.
            with :ok <- join_session_members(session_uri, [effective_owner]) do
              {:ok, session_uri, plain_session_meta()}
            end

          %URI{} ->
            ensure_orchestrated_session(
              session_uri,
              workspace_uri,
              effective_owner,
              session_template_uri
            )
        end
      end

    case result do
      {:ok, _, _} = ok ->
        ok

      {:error, reason} ->
        # Step 9 — minimal rollback of the freshly-created session.
        rollback_session(session_uri, nil)
        {:error, reason}
    end
  end

  # Steps 5-8 for an orchestrator-bearing session.
  defp ensure_orchestrated_session(
         session_uri,
         workspace_uri,
         effective_owner,
         session_template_uri
       ) do
    # Step 5 — ensure orchestrator (2-way ownership; ensure failure →
    # rollback → {:error,_}).
    case Session.ensure_orchestrator(session_uri, workspace_uri, effective_owner) do
      {:error, reason} ->
        rollback_session(session_uri, nil)
        {:error, {:orchestrator_ensure_failed, reason}}

      ensure_ok ->
        {orchestrator_uri, degraded_meta} = decompose_ensure(ensure_ok)

        # Steps 6-8.
        with :ok <-
               Session.grant_orchestrator_scoped_caps(
                 orchestrator_uri,
                 session_uri,
                 effective_owner
               ),
             :ok <-
               grant_owner_orchestrator_admin_cap(
                 session_uri,
                 effective_owner,
                 workspace_uri
               ),
             :ok <-
               Session.register_orchestrator_mcp_context(
                 orchestrator_uri,
                 session_uri,
                 workspace_uri,
                 effective_owner,
                 session_template_uri
               ),
             :ok <- join_session_members(session_uri, [effective_owner, orchestrator_uri]) do
          {:ok, session_uri,
           ready_meta(orchestrator_uri, effective_owner, session_uri, degraded_meta)}
        else
          {:error, reason} ->
            # Step 9 — rollback including the spawned orchestrator Kind.
            rollback_session(session_uri, orchestrator_uri)
            {:error, reason}
        end
    end
  end

  # ── Step 1b — SessionTemplate resolution ─────────────────────────────

  # Resolve `template_name` → a live SessionTemplate Kind in
  # `workspace_uri`, then read its content. SessionTemplates are
  # content-addressed (`template://session/<ws>/<name>@<hash>`); we find
  # the live Kind whose name segment equals `template_name`. Fail-loud
  # (SPEC §4 step 1) — the boot seed (`"default"` under `workspace://system`)
  # + tenant `add_template` are the population paths.
  defp resolve_session_template!(template_name, %URI{} = workspace_uri)
       when is_binary(template_name) do
    workspace_name = workspace_name_of!(workspace_uri)

    case find_session_template_uri(template_name, workspace_name) do
      {:ok, %URI{} = session_template_uri} ->
        # Demand-spawn the SessionTemplate Kind (it may have been seeded
        # at boot but not be live in this process's KindRegistry view —
        # e.g. resolved via the snapshot store). `ensure_template_alive`
        # is the kept helper for this.
        with {:ok, _pid} <- Session.ensure_template_alive(session_template_uri),
             {:ok, content} <- Session.read_template_content(session_template_uri) do
          {:ok, session_template_uri, content}
        else
          {:error, reason} ->
            {:error, {:session_template_not_readable, template_name, reason}}
        end

      :error ->
        {:error, {:session_template_not_found, template_name, workspace_name}}
    end
  end

  # Resolve `template://session/<ws>/<name>@<hash>` (any hash) whose
  # `<name>` matches. SessionTemplates are content-addressed (a given
  # name+content is one URI); any match is returned. Checks the live
  # `KindRegistry` first, then the durable snapshot store (the boot seed
  # writes a snapshot row but the Kind may not be live in this view).
  defp find_session_template_uri(template_name, workspace_name) do
    prefix = "template://session/#{workspace_name}/#{template_name}@"

    live =
      KindRegistry.list_all()
      |> Enum.find_value(false, fn {uri_str, _pid} ->
        if String.starts_with?(uri_str, prefix), do: {:ok, Ezagent.URI.new!(uri_str)}, else: false
      end)

    cond do
      live != false -> live
      true -> find_session_template_uri_in_snapshots(prefix)
    end
  end

  defp find_session_template_uri_in_snapshots(prefix) do
    Ezagent.Ecto.KindSnapshot.list_all()
    |> Enum.find_value(:error, fn %{uri: uri_str} ->
      if is_binary(uri_str) and String.starts_with?(uri_str, prefix) do
        {:ok, Ezagent.URI.new!(uri_str)}
      else
        false
      end
    end)
  rescue
    # DB unavailable — the live registry was already checked; treat as
    # not-found so the caller fails loud.
    _ -> :error
  end

  defp orchestrator_template_uri_of(template_content) when is_map(template_content) do
    case Map.get(template_content, :orchestrator_template_uri) ||
           Map.get(template_content, "orchestrator_template_uri") do
      %URI{} = uri ->
        uri

      uri_str when is_binary(uri_str) and uri_str != "" ->
        Ezagent.URI.new!(uri_str)

      _ ->
        nil
    end
  end

  # ── Step 4 — early OTU materialization ───────────────────────────────

  # Write `orchestrator_template_uri` + `session_template_uri` to the
  # session's durable working copy NOW, before the orchestrator can JOIN
  # (SPEC §4 step 4; codex rev3 Q3 — this narrow early write is safe, it
  # needs only template content). Replaces the deleted Generator
  # `merge_working_copy/6` for the OTU fields. For a plain session
  # (no OTU) we still record `session_template_uri` for provenance.
  defp materialize_orchestrator_working_copy(
         %URI{} = session_uri,
         %URI{} = session_template_uri,
         orchestrator_template_uri
       ) do
    prior = Session.read_template_working_copy(session_uri)

    working_copy =
      prior
      |> Map.put(:orchestrator_template_uri, orchestrator_template_uri)
      |> Map.put(:session_template_uri, session_template_uri)

    case Ezagent.Behavior.Chat.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  # ── Step 6 — owner OrchestratorAdmin :restart cap (the single grant) ──

  # 2026-05-31 orchestrator-startup-atomicity §4 step 6 — the SINGLE
  # owner `OrchestratorAdmin :restart` grant (the duplicate at
  # session.ex:1722 was deleted). The cap is what the LV's
  # `OrchestratorHealthCard` consults to gate the Restart button.
  # Idempotent via the named `Session.cap_equal_ignoring_metadata?/2`
  # (the inlined `has_equiv?` was dropped).
  defp grant_owner_orchestrator_admin_cap(
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    want = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.Behavior.OrchestratorAdmin,
      action: :restart,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    current = Ezagent.Identity.list_caps_for(owner_uri)

    if Enum.any?(current, &Session.cap_equal_ignoring_metadata?(&1, want)) do
      :ok
    else
      target = Ezagent.URI.with_action(owner_uri, :identity, :grant_cap)
      cap = %{want | granted_at: DateTime.utc_now()}

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          # SPEC caps-cleanup-v1 §4.4 — granting an ownership cap at
          # session-create time is template-materialization-equivalent;
          # runs under `system://template-materialize` (closed Catalog).
          ctx: %{
            caller: owner_uri,
            caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
            reply: {:caller_inbox, self()}
          }
        })

      case result do
        {:ok, _} -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, {:orchestrator_admin_cap_grant_failed, reason}}
        other -> {:error, {:orchestrator_admin_cap_grant_unexpected, other}}
      end
    end
  end

  # ── Step 8 — member join (one helper over a member list) ─────────────

  # 2026-05-31 orchestrator-startup-atomicity §4 step 8 — ONE helper
  # joining each member, merging the deleted `join_creator/2` +
  # `auto_join_session_members/3`. Both dispatched `chat.join` as
  # `system://session-internal`; this unifies them. `:call` mode so
  # failures are observable (codex r1 HIGH-2) — a failed join aborts the
  # create (the rollback then tears the session down). Demand-spawn each
  # member's Kind first (idempotent) — `chat.join` requires it alive.
  defp join_session_members(%URI{} = session_uri, members) when is_list(members) do
    target = Ezagent.URI.with_action(session_uri, :chat, :join)

    Enum.reduce_while(members, :ok, fn %URI{} = member_uri, :ok ->
      _ = Ezagent.SpawnRegistry.spawn(member_uri)

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{member: member_uri},
          # SPEC caps-cleanup-v1 §4.4 — Session slice-internal member
          # bookkeeping. The `system://session-internal` principal holds
          # the `cap(:any, Chat, :any)` cap step 5.5 checks.
          ctx: %{
            caller: Ezagent.SystemPrincipal.uri("session-internal"),
            caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
            reply: {:caller_inbox, self()}
          }
        })

      case result do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:member_join_failed, member_uri, reason}}}
        other -> {:halt, {:error, {:member_join_unexpected, member_uri, other}}}
      end
    end)
  end

  # ── Step 9 — rollback ────────────────────────────────────────────────

  # SPEC §4 step 9 — minimal, idempotent rollback. Terminate the
  # orchestrator Kind (if spawned) + the Session Kind, unbind the
  # workspace, delete the snapshot row `Kind.Server.init/1` wrote
  # synchronously at spawn time (Session.persistence/0 = {:snapshot,
  # :on_change}). Each step best-effort so the original failure reason
  # still surfaces. (The 4-store `rollback_fresh_session` enumeration was
  # removed — atomic structure means little has been committed.)
  @doc false
  @spec rollback_session(URI.t(), URI.t() | nil) :: :ok
  def rollback_session(%URI{} = session_uri, orchestrator_uri) do
    Logger.warning(
      "EzagentDomainChat.create_session: rolling back freshly-created " <>
        "session=#{URI.to_string(session_uri)} after a 4-8 failure — " <>
        "tearing down orchestrator + Session Kind + workspace binding + " <>
        "snapshot row (SPEC 2026-05-31 §4 step 9)."
    )

    if match?(%URI{}, orchestrator_uri) do
      _ = Ezagent.Kind.terminate(orchestrator_uri)
    end

    _ = Ezagent.Kind.terminate(session_uri)
    safe(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    safe(fn -> Ezagent.Ecto.KindSnapshot.delete(URI.to_string(session_uri)) end)
    :ok
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # ── Meta-map builders + ensure-result decomposition ──────────────────

  # `Session.ensure_orchestrator/3` returns `{:ok, uri, outcome}` or
  # `{:ok, uri, outcome, %{role_degraded: ...}}`. Decompose into the
  # URI + (possibly empty) degraded meta.
  defp decompose_ensure({:ok, %URI{} = uri, _outcome, degraded_meta}) when is_map(degraded_meta),
    do: {uri, degraded_meta}

  defp decompose_ensure({:ok, %URI{} = uri, _outcome}), do: {uri, %{}}

  # `:ready` (+ optional `:role_degraded` surfacing per Invariant #9).
  defp ready_meta(
         %URI{} = orch_uri,
         owner_uri,
         session_uri,
         %{role_degraded: true} = degraded_meta
       ) do
    notify_orchestrator_role_degraded(owner_uri, session_uri, orch_uri, degraded_meta)

    %{
      orchestrator_uri: orch_uri,
      orchestrator_status: :ready,
      orchestrator_error: {:role_degraded, Map.get(degraded_meta, :role_degraded_reason)}
    }
  end

  defp ready_meta(%URI{} = orch_uri, _owner_uri, _session_uri, _degraded_meta) do
    %{orchestrator_uri: orch_uri, orchestrator_status: :ready, orchestrator_error: nil}
  end

  # Plain session — no orchestrator role. `:failed` with a nil URI is the
  # 2-state contract's "no orchestrator" signal (NOT an error; the
  # session is valid + usable).
  defp plain_session_meta do
    %{orchestrator_uri: nil, orchestrator_status: :failed, orchestrator_error: :no_orchestrator}
  end

  # Best-effort orchestrator status for an idempotent re-create of an
  # already-existing session. We do not re-run setup; we read whether the
  # orchestrator Agent Kind is live.
  defp existing_orchestrator_meta(%URI{} = session_uri, %URI{} = workspace_uri) do
    orch_uri = Session.derive_orchestrator_uri(session_uri, workspace_uri)

    case KindRegistry.lookup(orch_uri) do
      {:ok, _pid} ->
        %{orchestrator_uri: orch_uri, orchestrator_status: :ready, orchestrator_error: nil}

      :error ->
        %{
          orchestrator_uri: nil,
          orchestrator_status: :failed,
          orchestrator_error: :no_orchestrator
        }
    end
  end

  # codex PR #408 review HIGH-3 — notify the session owner that the
  # orchestrator's role-bootstrap (skill copy / CLAUDE.md hint) failed.
  # The agent itself is alive; the orchestrator-specific UX is degraded.
  # Best-effort: a notify failure logs but never bubbles up.
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

  # Non-user owner (e.g. system principal or agent) — no inbox to notify.
  defp notify_orchestrator_role_degraded(_owner, %URI{} = session_uri, %URI{} = orch_uri, meta) do
    reason = Map.get(meta, :role_degraded_reason)

    Logger.warning(
      "EzagentDomainChat.create_session: orchestrator role-bootstrap DEGRADED for " <>
        "session=#{URI.to_string(session_uri)} orchestrator=#{URI.to_string(orch_uri)} " <>
        "reason=#{inspect(reason)} — owner is not a user URI; no inbox notification sent."
    )

    :ok
  end

  # workspace://<name> → "<name>". Raises ArgumentError if the URI isn't a
  # bare workspace URI (helps catch passing entity / session URIs).
  defp workspace_name_of!(%URI{scheme: "workspace", host: name}) when is_binary(name),
    do: name

  defp workspace_name_of!(other),
    do: raise(ArgumentError, "expected %URI{scheme: \"workspace\"}, got: #{inspect(other)}")

  # SPEC #366 (Allen 2026-05-26) — eliminate the silent `"default"`
  # template-class fallback. Callers MUST pass `:template_name` in opts.
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
end
