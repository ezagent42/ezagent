defmodule EzagentDomainInstanceMessage.SessionCreator do
  @moduledoc """
  Internal session materialization entry for the instance-message domain.

  Operator and user surfaces create sessions through
  `Ezagent.Workspace.create_session/3`. This module keeps the lower-level
  atomic materialization sequence as an implementation detail for the
  Workspace behavior.

  ## PR-J (Phase 8c, Allen 2026-05-20)

  The previous `:main_is_static` restriction was removed. `session://default/system/main`
  is no longer a hardcoded static supervisor child of
  `EzagentDomainInstanceMessage.Application` — it now goes through the same code
  path as every other session, created by the first-login wizard. The
  test environment seeds it via this same facade in
  `EzagentDomainInstanceMessage.Application` (test-only branch).

  ## 2026-05-31 — atomic, single-entry session creation

  `create_session/3` is the internal atomic session materializer and the
  **single lower-level writer** (the dead Generator path
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
  alias EzagentDomainInstanceMessage.SessionCreator.{Listing, TemplateResolver}

  require Logger

  @doc """
  Spawn a new Session Kind under `EzagentDomainInstanceMessage.SessionSupervisor`,
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
                    "EzagentDomainInstanceMessage.SessionCreator.create_session/3 requires either a non-nil " <>
                      "entity creator_uri (to derive workspace structurally) or " <>
                      "an explicit opts[:workspace_uri]. Got creator_uri=" <>
                      "#{inspect(creator_uri)}, opts=#{inspect(opts)}."
          end
      end

    template_name = TemplateResolver.require_template_name!(opts)
    workspace_name = workspace_name_of!(workspace_uri)

    session_uri = Ezagent.URI.session(workspace_name, template_name, short_name)

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
    lock_id =
      {{:ezagent_domain_instance_message, :create_session, URI.to_string(session_uri)}, self()}

    try do
      true = :global.set_lock(lock_id, [node()])
      do_create_session(session_uri, workspace_uri, creator_uri, template_name)
    after
      _ = :global.del_lock(lock_id, [node()])
    end
  end

  def create_session(_short_name, _creator, _opts), do: {:error, :short_name_required}

  @doc """
  Repair an EXISTING session's orchestrator (SPEC 2026-05-31 §6).

  Fixes sessions whose `orchestrator_template_uri` (OTU) is nil — the
  `main` / `orch-feishu-7429` class created before the atomic flow set
  OTU, and any session whose orchestrator died. Unlike a plain restart
  (which only re-dispatched `template.instantiate` + respawned the PTY,
  NEVER setting OTU), this:

    1. resolves the session's SessionTemplate from its 3-segment URI
       (`session://<template>/<ws>/<name>` — the `<template>` segment is
       the host) and reads its content (fail-loud if absent);
    2. RE-MATERIALIZES the working copy — writes `orchestrator_template_uri`
       + `session_template_uri` (`materialize_orchestrator_working_copy/3`,
       the same write the create flow does);
    3. runs the §5 atomic orchestrator-ensure gate + cap grants + MCP
       registration + member join (`ensure_orchestrated_session/4`).

  Returns `{:ok, session_uri, meta}` (same `create_session_meta` shape) or
  `{:error, reason}`. A plain (no-orchestrator) template is a no-op success.

  Cap-gated by the caller: the LV's `restart_orchestrator` path checks
  `Ezagent.Behavior.OrchestratorAdmin :restart` BEFORE dispatching here.
  """
  @spec repair_orchestrator(URI.t()) ::
          {:ok, URI.t(), create_session_meta()} | {:error, term()}
  def repair_orchestrator(%URI{scheme: "session"} = session_uri) do
    workspace_uri =
      case Ezagent.Capability.workspace_of(session_uri) do
        %URI{} = ws -> ws
        :any -> nil
      end

    repair_orchestrator(session_uri, workspace_uri)
  end

  @spec repair_orchestrator(URI.t(), URI.t() | nil) ::
          {:ok, URI.t(), create_session_meta()} | {:error, term()}
  def repair_orchestrator(
        %URI{scheme: "session"} = session_uri,
        %URI{} = workspace_uri
      ) do
    _template_name = Ezagent.URI.type!(session_uri)

    # The SAME per-URI lock ResourceId the create flow uses (`:create_session`,
    # NOT a distinct `:repair_orchestrator` id) so a repair and a concurrent
    # create/repair of the same session actually serialize on one lock. (codex Q4.)
    lock_id =
      {{:ezagent_domain_instance_message, :create_session, URI.to_string(session_uri)}, self()}

    try do
      true = :global.set_lock(lock_id, [node()])
      do_repair_orchestrator(session_uri, workspace_uri)
    after
      _ = :global.del_lock(lock_id, [node()])
    end
  end

  def repair_orchestrator(%URI{scheme: "session"}, nil),
    do: {:error, :repair_requires_workspace}

  defp do_repair_orchestrator(%URI{} = session_uri, %URI{} = workspace_uri) do
    template_name = Ezagent.URI.type!(session_uri)

    # The session OWNER carries the orchestrator ownership obligations; read
    # it from the live/durable session so the re-materialize + ensure use
    # the SAME owner the session was created with (NOT the repairing
    # operator — same constraint as the LV restart's `spawned_by` lineage).
    effective_owner =
      case Session.owner(session_uri) do
        {:ok, %URI{} = owner} -> owner
        _ -> User.admin_uri()
      end

    case TemplateResolver.resolve_for_repair(session_uri, template_name, workspace_uri) do
      {:error, _} = err ->
        err

      {:ok, session_template_uri, template_content} ->
        orchestrator_template_uri =
          TemplateResolver.orchestrator_template_uri_of(template_content)

        with :ok <-
               materialize_orchestrator_working_copy(
                 session_uri,
                 session_template_uri,
                 orchestrator_template_uri
               ) do
          case orchestrator_template_uri do
            nil ->
              # Plain template — nothing to repair (no orchestrator role).
              {:ok, session_uri, plain_session_meta()}

            %URI{} ->
              # REPAIR of an EXISTING live session — `new_session?: false`. A
              # materialization failure here must compensate ONLY the
              # materialization residue (newly-spawned members + newly-inserted
              # rule rows, already self-swept by `materialize_template_team/4`)
              # and LEAVE the pre-existing session Kind + its members alive
              # (codex cycle-2 MAJOR #3). Full `rollback_session/3` (which
              # terminates the Session Kind + deletes its snapshot) is RESERVED
              # for the create-NEW path.
              ensure_orchestrated_session(
                session_uri,
                workspace_uri,
                effective_owner,
                session_template_uri,
                template_content,
                new_session?: false
              )
          end
        end
    end
  end

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
    case TemplateResolver.resolve_session_template!(template_name, workspace_uri) do
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
    # Step 2 — spawn the Session Kind. A fresh spawn runs the full
    # finalize. `{:already_started}` / `{:already_registered}` →
    # VERIFY COMPLETENESS (codex-review Q2): a crash mid-create can leave
    # a half-session (Session spawned + bound but no OTU / no caps / no
    # orchestrator / owner not joined); returning that as success is the
    # half-start the SPEC forbids. A COMPLETE session is returned
    # idempotently; an INCOMPLETE one is rolled back fully (§4 step 9)
    # then RECREATED fresh.
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
        verify_or_recreate(
          session_uri,
          workspace_uri,
          effective_owner,
          session_template_uri,
          template_content
        )

      {:error, {:already_registered, _}} ->
        verify_or_recreate(
          session_uri,
          workspace_uri,
          effective_owner,
          session_template_uri,
          template_content
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # codex-review Q2 — for an already-existing Session: verify it is a
  # COMPLETE session; if so return it (idempotent success); if not, roll
  # it back FULLY (Fix Q1) then RECREATE fresh (re-spawn + full
  # finalize). Never return an incomplete session as success.
  defp verify_or_recreate(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = effective_owner,
         %URI{} = session_template_uri,
         template_content
       ) do
    orchestrator_template_uri = TemplateResolver.orchestrator_template_uri_of(template_content)

    if session_complete?(session_uri, workspace_uri, effective_owner, orchestrator_template_uri) do
      {:ok, session_uri, existing_orchestrator_meta(session_uri, workspace_uri)}
    else
      Logger.warning(
        "EzagentDomainInstanceMessage.SessionCreator.create_session: existing session=" <>
          "#{URI.to_string(session_uri)} is INCOMPLETE (half-create residue) — " <>
          "rolling it back fully then recreating fresh (SPEC 2026-05-31 §4 " <>
          "step 2, codex-review Q2)."
      )

      orch_uri =
        if match?(%URI{}, orchestrator_template_uri) do
          Session.planned_orchestrator_uri(session_uri, workspace_uri)
        else
          nil
        end

      rollback_session(session_uri, orch_uri,
        owner_uri: effective_owner,
        workspace_uri: workspace_uri
      )

      # Give the supervisor a moment to actually terminate the Session
      # Kind so the re-spawn below gets a clean `:ok` (not another
      # `:already_started`).
      _ = await_terminated(session_uri, 2_000)

      recreate_fresh(
        session_uri,
        workspace_uri,
        effective_owner,
        session_template_uri,
        template_content
      )
    end
  end

  # Re-spawn the (now-rolled-back) Session Kind fresh and run the full
  # finalize. A `:already_started` here means the prior Kind has not yet
  # fully terminated — surfaced as `{:error, _}` (fail-loud) rather than
  # looping, so a genuinely-stuck Kind doesn't spin.
  defp recreate_fresh(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = effective_owner,
         %URI{} = session_template_uri,
         template_content
       ) do
    case Ezagent.Kind.spawn(Session, %{uri: session_uri, owner_uri: effective_owner}) do
      {:ok, _pid} ->
        finalize_fresh_session(
          session_uri,
          workspace_uri,
          effective_owner,
          session_template_uri,
          template_content
        )

      {:error, reason} ->
        {:error, {:recreate_after_incomplete_failed, reason}}
    end
  end

  # Completeness predicate (codex-review Q2). For an orchestrator-bearing
  # template ALL must hold; for a plain template only bound + owner-member.
  #
  #   * workspace bound — `WorkspaceRegistry.lookup(session_uri)` hits;
  #   * owner is a chat member — `Session.session_member_uris/1` includes
  #     the owner (the step-8 join ran);
  #   * (orchestrator only) working-copy OTU set — the step-4
  #     materialization ran;
  #   * (orchestrator only) orchestrator registered-or-rebuildable —
  #     `McpServer.from_orchestrator_uri/1` → {:ok} (the registry row OR
  #     a durable rebuild succeeds — the step-5/7 outcome).
  defp session_complete?(
         %URI{} = session_uri,
         %URI{} = _workspace_uri,
         %URI{} = owner_uri,
         orchestrator_template_uri
       ) do
    bound? = match?({:ok, _}, Ezagent.WorkspaceRegistry.lookup(session_uri))
    owner_member? = owner_uri in Session.session_member_uris(session_uri)

    case orchestrator_template_uri do
      nil ->
        # Plain session — bound + owner-member is the whole contract.
        bound? and owner_member?

      %URI{} ->
        wc = Session.read_template_working_copy(session_uri)
        otu_set? = match?(%URI{}, Map.get(wc, :orchestrator_template_uri))

        orchestrator_ok? =
          if bound? do
            orch_uri = Map.get(wc, :orchestrator_uri)

            match?(%URI{}, orch_uri) and
              match?(
                {:ok, _},
                Ezagent.Orchestrator.McpServer.from_orchestrator_uri(orch_uri)
              )
          else
            false
          end

        bound? and owner_member? and otu_set? and orchestrator_ok?
    end
  end

  # Best-effort wait for the Session Kind to leave the KindRegistry after
  # a rollback terminate (so the recreate re-spawn is clean). Bounded
  # poll; returns `:ok` once gone or `:timeout` after `deadline_ms`.
  defp await_terminated(%URI{} = session_uri, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_terminated(session_uri, deadline)
  end

  defp do_await_terminated(%URI{} = session_uri, deadline) do
    case KindRegistry.lookup(session_uri) do
      :error ->
        :ok

      {:ok, _pid} ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(20)
          do_await_terminated(session_uri, deadline)
        end
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
    orchestrator_template_uri = TemplateResolver.orchestrator_template_uri_of(template_content)

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
            # only; skip 5-7. Then materialize the template team (PR-7).
            with :ok <- join_session_members(session_uri, [effective_owner]),
                 :ok <-
                   materialize_template_team(
                     session_uri,
                     workspace_uri,
                     effective_owner,
                     template_content
                   ) do
              {:ok, session_uri, plain_session_meta()}
            end

          %URI{} ->
            # CREATE of a brand-NEW session — `new_session?: true`. A failure
            # in steps 5-8 rolls the whole freshly-created session back
            # (`rollback_session/3` terminates the Session Kind + snapshot).
            ensure_orchestrated_session(
              session_uri,
              workspace_uri,
              effective_owner,
              session_template_uri,
              template_content,
              new_session?: true
            )
        end
      end

    case result do
      {:ok, _, _} = ok ->
        ok

      {:error, reason} ->
        # Step 9 — rollback of the freshly-created session. No
        # orchestrator was spawned in THIS arm (the orchestrator-bearing
        # branch delegates to `ensure_orchestrated_session/4`, which owns
        # its own rollback), so the orchestrator URI is nil — but we
        # still pass owner + workspace so any owner cap is revoked.
        rollback_session(session_uri, nil,
          owner_uri: effective_owner,
          workspace_uri: workspace_uri
        )

        {:error, reason}
    end
  end

  # Steps 5-8 for an orchestrator-bearing session.
  #
  # `new_session?` decides the failure-compensation policy (codex cycle-2
  # MAJOR #3):
  #   * `true`  (create a brand-NEW session) — a steps 5-8 failure rolls the
  #     whole freshly-created session back via `rollback_session/3` (terminate
  #     the Session Kind + snapshot + orchestrator + caps).
  #   * `false` (repair / re-materialize an EXISTING live session) — a failure
  #     must NEVER tear down the pre-existing session. `materialize_template_team/4`
  #     already self-compensates the residue it created (newly-spawned members
  #     + newly-inserted rule rows); we leave the live session + its members
  #     intact and just surface the error.
  defp ensure_orchestrated_session(
         session_uri,
         workspace_uri,
         effective_owner,
         session_template_uri,
         template_content,
         opts
       )
       when is_list(opts) do
    new_session? = Keyword.fetch!(opts, :new_session?)

    # Step 5 — ensure orchestrator (2-way ownership; ensure failure →
    # rollback → {:error,_}).
    case Session.ensure_orchestrator(session_uri, workspace_uri, effective_owner) do
      {:error, reason} ->
        # `ensure_orchestrator/3` self-cleans the orchestrator it spawned
        # on its own failure paths (Fix Q4 + `spawn_from_template_content`
        # round-10), so the orchestrator URI is nil here. On the create path
        # roll the freshly-created session back (revoking any owner cap); on
        # the repair path the pre-existing session stays alive — there is no
        # residue to sweep (the orchestrator self-cleaned, no caps granted).
        if new_session? do
          rollback_session(session_uri, nil,
            owner_uri: effective_owner,
            workspace_uri: workspace_uri
          )
        end

        {:error, {:orchestrator_ensure_failed, reason}}

      ensure_ok ->
        {orchestrator_uri, degraded_meta} = decompose_ensure(ensure_ok)

        # Steps 6-8.
        with :ok <- store_session_orchestrator_uri(session_uri, orchestrator_uri),
             :ok <-
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
             :ok <- join_session_members(session_uri, [effective_owner, orchestrator_uri]),
             :ok <-
               materialize_template_team(
                 session_uri,
                 workspace_uri,
                 orchestrator_uri,
                 template_content
               ) do
          {:ok, session_uri,
           ready_meta(orchestrator_uri, effective_owner, session_uri, degraded_meta)}
        else
          {:error, reason} ->
            if new_session? do
              # Step 9 (create-NEW only) — rollback including the spawned
              # orchestrator Kind + its registry/lineage/bind/snapshot + the
              # granted caps (owner restart cap + orchestrator scoped caps),
              # reversed.
              rollback_session(session_uri, orchestrator_uri,
                owner_uri: effective_owner,
                workspace_uri: workspace_uri
              )
            else
              # REPAIR of an EXISTING live session (codex cycle-2 MAJOR #3) —
              # do NOT tear the session/orchestrator down. The only residue a
              # materialization failure creates (freshly-spawned members +
              # newly-inserted rule rows) is ALREADY self-compensated inside
              # `materialize_template_team/4` before it returns `{:error,_}`.
              # The pre-existing session Kind + its members + snapshot stay
              # alive; the caller (`repair_orchestrator/2`) surfaces the error.
              Logger.warning(
                "EzagentDomainInstanceMessage.repair_orchestrator: re-materialization FAILED for " <>
                  "EXISTING session=#{URI.to_string(session_uri)} reason=#{inspect(reason)} " <>
                  "— the live session is LEFT INTACT (materialization residue self-swept); " <>
                  "no Session-Kind teardown (codex cycle-2 MAJOR #3)."
              )
            end

            {:error, reason}
        end
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

  defp store_session_orchestrator_uri(%URI{} = session_uri, %URI{} = orchestrator_uri) do
    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(:orchestrator_uri, orchestrator_uri)

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
            caps:
              "template-materialize"
              |> Ezagent.SystemPrincipal.uri()
              |> Ezagent.SystemPrincipal.caps(),
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
            caps:
              "session-internal"
              |> Ezagent.SystemPrincipal.uri()
              |> Ezagent.SystemPrincipal.caps(),
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

  # SPEC §4 step 9 — idempotent rollback that MIRRORS create's writes in
  # REVERSE (codex-review Q1). By the time a LATE step (cap grant / MCP
  # register / member join) fails, create has written, for an
  # orchestrator-bearing session: the orchestrator workspace bind +
  # orchestrator lineage (`Agent.establish_post_spawn_obligations/3`) +
  # orchestrator snapshot + MCP registry context + the owner
  # `OrchestratorAdmin :restart` cap + the orchestrator scoped caps —
  # PLUS the Session's own bind + snapshot. The pre-Q1 rollback only tore
  # down the Kinds + Session bind + Session snapshot, leaving the MCP
  # registry row, the orchestrator lineage/bind/snapshot, and (the
  # durable one) the owner restart cap behind.
  #
  # Reverse order (un-register → un-bind/forget/terminate orchestrator →
  # revoke caps → tear down Session). Each step best-effort + idempotent
  # (absent → :ok) so the original failure reason still surfaces and a
  # double-rollback is harmless. `opts` carries `:owner_uri` +
  # `:workspace_uri` so the cap revokes can reconstruct the granted caps
  # by identity-key; absent (the arity-2 unit-test path) → cap revoke is
  # skipped (nothing was granted in that scenario).
  @doc false
  @spec rollback_session(URI.t(), URI.t() | nil) :: :ok
  @spec rollback_session(URI.t(), URI.t() | nil, keyword()) :: :ok
  def rollback_session(session_uri, orchestrator_uri, opts \\ [])

  def rollback_session(%URI{} = session_uri, orchestrator_uri, opts) when is_list(opts) do
    owner_uri = Keyword.get(opts, :owner_uri)
    workspace_uri = Keyword.get(opts, :workspace_uri)

    Logger.warning(
      "EzagentDomainInstanceMessage.SessionCreator.create_session: rolling back freshly-created " <>
        "session=#{URI.to_string(session_uri)} after a 4-8 failure — " <>
        "reversing create's writes (MCP unregister + orchestrator " <>
        "lineage/bind/snapshot/Kind + granted caps + Session Kind/bind/" <>
        "snapshot) (SPEC 2026-05-31 §4 step 9, codex-review Q1)."
    )

    # 1. Orchestrator-side teardown (only if an orchestrator was spawned).
    if match?(%URI{}, orchestrator_uri) do
      # 1a. MCP registry context (the step-7 write).
      safe(fn -> Ezagent.Orchestrator.McpRegistry.unregister(orchestrator_uri) end)

      # 1b. Orchestrator scoped caps (the step-6 grant TO the orchestrator).
      #     Needs owner + workspace to reconstruct the cap identity-keys.
      if match?(%URI{}, owner_uri) and match?(%URI{}, workspace_uri) do
        safe(fn ->
          Session.revoke_orchestrator_scoped_caps(
            orchestrator_uri,
            session_uri,
            owner_uri,
            workspace_uri
          )
        end)
      end

      # 1c. Orchestrator Kind + its lineage + workspace binding (the
      #     spawn's `establish_post_spawn_obligations/3` writes) + its
      #     own snapshot row.
      # Kind teardown via the Lifecycle destroy primitive (runs developer
      # destroy hooks → clears the snapshot row + ever-created marker →
      # terminates the process). #533 5a (persistence-access discipline):
      # domain code must NOT hand-roll `terminate + KindSnapshot.delete`
      # — that skipped the destroy hooks (e.g. Sandbox config_dir cleanup)
      # on rollback. Go through `Lifecycle.destroy/2`.
      safe(fn -> Ezagent.Lifecycle.destroy(orchestrator_uri, :rollback) end)
      safe(fn -> Ezagent.WorkspaceRegistry.unbind(orchestrator_uri) end)
      forget_lineage(orchestrator_uri)

      # 1d. Live-join durable readiness marker (codex #505 review HIGH).
      #     If the gate already saw the orchestrator's bridge join (step 5
      #     succeeded) and a LATER step 6-8 failed, the `{orchestrator_uri,
      #     true}` row survives Kind teardown — a retry of the SAME URI
      #     would then satisfy `LiveJoinRegistry.joined?/1` instantly,
      #     before the new live bridge actually joins. Clear it so the
      #     gate re-arms (mirrors `Session.kill_orchestrator/1`).
      safe(fn -> Ezagent.Orchestrator.LiveJoinRegistry.clear(orchestrator_uri) end)
    end

    # 2. Owner `OrchestratorAdmin :restart` cap (the step-6 grant on the
    #    DURABLE owner User Kind — the residue that outlives Kind
    #    teardown). Best-effort + idempotent (revoke matches by
    #    identity-key; an absent cap is a clean no-op).
    if match?(%URI{}, owner_uri) and match?(%URI{}, workspace_uri) do
      safe(fn -> revoke_owner_orchestrator_admin_cap(session_uri, owner_uri, workspace_uri) end)
    end

    # 3. Materialized template rule rows (codex MAJOR #3) — every rule
    #    `materialize_template_team/4` installs is stamped `created_by =
    #    session_uri`, so the create-rollback can sweep ALL of this
    #    session's rule rows by identity. `materialize_template_team/4`
    #    already self-compensates its own mid-batch failure; this is the
    #    belt-and-braces sweep for any rule that outlived a partial create.
    safe(fn -> delete_session_rule_rows(session_uri) end)

    # 4. Session Kind + its workspace binding + its snapshot row
    #    (`Kind.Server.init/1` wrote it synchronously at spawn time —
    #    Session.persistence/0 = {:snapshot, :on_change}).
    # #533 5a — Kind teardown through the Lifecycle destroy primitive
    # (hooks → snapshot+marker clear → terminate), not a hand-rolled
    # terminate + KindSnapshot.delete.
    safe(fn -> Ezagent.Lifecycle.destroy(session_uri, :rollback) end)
    safe(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok
  end

  # Delete ALL durable routing-rule rows this session's materialization
  # created (keyed by `created_by = session_uri`). Force-deletes (they are
  # `system_default` source). Best-effort + idempotent. Reloads the live
  # RoutingRegistry so the swept rules also leave ETS.
  defp delete_session_rule_rows(%URI{} = session_uri) do
    table = Ezagent.Routing.Resolver.default_routing_table()
    session_str = URI.to_string(session_uri)

    Ezagent.Routing.RuleStore.list(table)
    |> Enum.filter(fn row -> row.created_by == session_str end)
    |> Enum.each(fn row ->
      safe(fn -> Ezagent.Routing.RuleStore.delete(row.id, force: true) end)
    end)

    safe(fn -> Ezagent.Routing.RuleStore.load_into_registry(table) end)
    :ok
  end

  # Idempotent lineage forget for the orchestrator (mirror of
  # `Agent.undo_fresh_workers/1`'s lineage cleanup). Guarded because
  # `AgentLineage` may not be loaded in a minimal test boot.
  defp forget_lineage(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :forget, 1) do
      safe(fn -> Ezagent.AgentLineage.forget(uri) end)
    end

    :ok
  end

  # Revoke the single owner `OrchestratorAdmin :restart` cap
  # `grant_owner_orchestrator_admin_cap/3` adds. Mirror of that grant.
  # Idempotent via `:revoke_cap`'s identity-key match.
  defp revoke_owner_orchestrator_admin_cap(
         %URI{} = session_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    cap = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.Behavior.OrchestratorAdmin,
      action: :restart,
      instance: session_uri,
      workspace_uri: workspace_uri,
      granted_by: owner_uri,
      granted_at: nil
    }

    target = Ezagent.URI.with_action(owner_uri, :identity, :revoke_cap)

    _ =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{cap: cap},
        ctx: %{
          caller: owner_uri,
          caps:
            "template-materialize"
            |> Ezagent.SystemPrincipal.uri()
            |> Ezagent.SystemPrincipal.caps(),
          reply: {:caller_inbox, self()}
        }
      })

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
    orch_uri = stored_or_planned_orchestrator_uri(session_uri, workspace_uri)

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

  defp stored_or_planned_orchestrator_uri(%URI{} = session_uri, %URI{} = workspace_uri) do
    case Session.orchestrator_uri(session_uri) do
      {:ok, %URI{} = uri} ->
        uri

      :none ->
        Session.planned_orchestrator_uri(session_uri, workspace_uri)

      {:error, reason} ->
        raise ArgumentError, "orchestrator URI lookup failed: #{inspect(reason)}"
    end
  end

  # codex PR #408 review HIGH-3 — notify the session owner that the
  # orchestrator's role-bootstrap (skill copy / CLAUDE.md hint) failed.
  # The agent itself is alive; the orchestrator-specific UX is degraded.
  # Best-effort: a notify failure logs but never bubbles up.
  defp notify_orchestrator_role_degraded(
         %URI{scheme: "entity"} = owner_uri,
         %URI{} = session_uri,
         %URI{} = orch_uri,
         degraded_meta
       ) do
    unless Ezagent.URI.type?(owner_uri, :user) do
      notify_orchestrator_role_degraded(:non_user_owner, session_uri, orch_uri, degraded_meta)
    else
      reason = Map.get(degraded_meta, :role_degraded_reason)

      Logger.warning(
        "EzagentDomainInstanceMessage.SessionCreator.create_session: orchestrator role-bootstrap DEGRADED for " <>
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
            "EzagentDomainInstanceMessage.SessionCreator.create_session: notify(:orchestrator_role_degraded) to " <>
              "#{URI.to_string(owner_uri)} raised #{inspect(error)} — the orchestrator " <>
              "is still alive; this is the notification path failing, not the spawn."
          )
      end

      :ok
    end
  end

  # Non-user owner (e.g. system principal or agent) — no inbox to notify.
  defp notify_orchestrator_role_degraded(_owner, %URI{} = session_uri, %URI{} = orch_uri, meta) do
    reason = Map.get(meta, :role_degraded_reason)

    Logger.warning(
      "EzagentDomainInstanceMessage.SessionCreator.create_session: orchestrator role-bootstrap DEGRADED for " <>
        "session=#{URI.to_string(session_uri)} orchestrator=#{URI.to_string(orch_uri)} " <>
        "reason=#{inspect(reason)} — owner is not a user URI; no inbox notification sent."
    )

    :ok
  end

  # workspace://<name> → "<name>". Raises ArgumentError if the URI isn't a
  # bare workspace URI (helps catch passing entity / session URIs).
  # ── PR-7 — SessionTemplate team materialization (spec §3.7) ──────────
  #
  # After the owner + orchestrator have joined (the pre-PR-7 contract),
  # MATERIALIZE the rest of the template's team so an instantiated/forked
  # template actually PRODUCES the working team (the load-bearing contract
  # codex flagged). For the template content we:
  #
  #   1. recreate + join each `in_session_template: true` member —
  #      a member with `source_template_uri` is a SPAWNED agent member
  #      (recreated from that AgentTemplate via the unified `Agent.spawn/4`
  #      path); a member without one is a plain invited member (its `uri`
  #      is joined directly). Each is joined with its `role_name` +
  #      `in_session_template: true` (+ the spawn-source facet so a future
  #      respawn can rebuild it). provenance is DEFERRED (PR-5b/PR-8) —
  #      we register role_name + in_session_template only.
  #   2. install the named `prompt_templates` (§3.4) via the trusted
  #      `system://session-internal` `chat.set_prompt_templates` path;
  #   3. install the `legends` (§3.6) via `chat.set_legends`;
  #   4. install the rule-set routing rules (§3.3) — resolving each rule's
  #      role_name receivers to the just-materialized member URIs, then
  #      writing the rows + reloading the live RoutingRegistry.
  #
  # `granted_by` is the principal that authorizes the spawned-member
  # creation (the orchestrator for an orchestrated session; the owner for a
  # plain one) — recorded in AgentLineage for `{:spawned_by, _}` caps.
  #
  # A template with none of these fields is a no-op `:ok` (behaviour-
  # preserving for the boot `default` template + every pre-PR-7 template).
  @doc false
  # Public for the materialization idempotency test (codex BLOCKER #1) +
  # the repair path — re-materializing the SAME session must be idempotent
  # (same member URIs, no duplicate rule rows). NOT a stable external API.
  @spec materialize_template_team(URI.t(), URI.t(), URI.t(), map()) :: :ok | {:error, term()}
  def materialize_template_team(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
        template_content
      )
      when is_map(template_content) do
    # codex MAJOR #3 — materialization spawns members + inserts rule rows
    # sequentially; a failure midway must NOT leave orphan Agent Kinds /
    # lineage / bindings or inserted RuleStore rows. We TRACK the
    # side-effects (the member URIs THIS call freshly spawned + the rule row
    # ids it inserted) and COMPENSATE them on any failure before returning
    # the error. The outer create-rollback (`rollback_session/3`) tears down
    # the Session + orchestrator; this compensation owns the team residue
    # the create-rollback never saw.
    case materialize_template_members(session_uri, workspace_uri, granted_by, template_content) do
      {:error, reason} ->
        # Members reduce-while self-compensates the members IT spawned
        # before the failing one (it carries the accumulator); nothing else
        # was written yet.
        {:error, reason}

      {:ok, role_to_uri, spawned_uris} ->
        result =
          with :ok <- install_template_prompt_templates(session_uri, template_content),
               :ok <- install_template_legends(session_uri, template_content),
               {:ok, _rule_ids} <-
                 install_template_rule_sets(
                   session_uri,
                   workspace_uri,
                   template_content,
                   role_to_uri
                 ) do
            :ok
          end

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            # A post-member step failed. The rule-set install already
            # self-compensated its own inserted rows on its internal halt;
            # here we additionally tear down the spawned members (+ their
            # lineage/bind/snapshot) this materialization created.
            compensate_spawned_members(spawned_uris)
            {:error, reason}
        end
    end
  end

  # A non-map / nil content can't carry a team — nothing to materialize.
  def materialize_template_team(_session, _ws, _granted_by, _content), do: :ok

  # Terminate + un-bind + forget-lineage + delete-snapshot for each member
  # URI this materialization freshly spawned (codex MAJOR #3). Best-effort +
  # idempotent — mirrors the orchestrator teardown in `rollback_session/3`.
  defp compensate_spawned_members(spawned_uris) when is_list(spawned_uris) do
    Enum.each(spawned_uris, fn %URI{} = uri ->
      # #533 5a — teardown via the Lifecycle destroy primitive, not a
      # hand-rolled terminate + KindSnapshot.delete (which skipped hooks).
      safe(fn -> Ezagent.Lifecycle.destroy(uri, :rollback) end)
      safe(fn -> Ezagent.WorkspaceRegistry.unbind(uri) end)
      forget_lineage(uri)
    end)

    :ok
  end

  # Step 1 — recreate + join each `in_session_template: true` member.
  # Returns `{:ok, role_to_uri, spawned_uris}` where `role_to_uri` maps each
  # member's `role_name` → its live member URI (used by the rule-set install
  # to resolve role_name receivers) and `spawned_uris` is the list of member
  # URIs THIS call freshly spawned (codex MAJOR #3 — the rollback set). On a
  # member failure mid-way it SELF-COMPENSATES the members spawned before
  # the failing one (so the Nth-member-fails case leaves no orphans) and
  # returns `{:error, _}`. Owner/orchestrator joins already ran.
  defp materialize_template_members(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = granted_by,
         template_content
       ) do
    members = template_members_of(template_content)

    result =
      Enum.reduce_while(members, {:ok, %{}, []}, fn member, {:ok, acc, spawned} ->
        case materialize_one_member(session_uri, workspace_uri, granted_by, member) do
          {:ok, %URI{} = member_uri, role_name, fresh?} ->
            acc = if is_binary(role_name), do: Map.put(acc, role_name, member_uri), else: acc
            spawned = if fresh?, do: [member_uri | spawned], else: spawned
            {:cont, {:ok, acc, spawned}}

          # codex cycle-2 MAJOR #2 — a member that was freshly SPAWNED
          # (`spawn_fresh` bound the workspace + recorded lineage) but whose
          # JOIN then failed returns its URI here so it enters the
          # compensation set TOO. Without this, the spawned-but-unjoined URI
          # was dropped → orphan Agent Kind + lineage + binding survived the
          # rollback.
          {:error, reason, %URI{} = orphan_uri} ->
            {:halt,
             {:error, {:member_materialize_failed, member, reason}, [orphan_uri | spawned]}}

          {:error, reason} ->
            {:halt, {:error, {:member_materialize_failed, member, reason}, spawned}}
        end
      end)

    case result do
      {:ok, role_to_uri, spawned} ->
        {:ok, role_to_uri, spawned}

      {:error, reason, spawned} ->
        # Tear down the members already spawned in THIS materialization
        # before the failing member (codex MAJOR #3 — the Nth-member-fails
        # rollback). No rules / prompt_templates / legends written yet.
        compensate_spawned_members(spawned)
        {:error, reason}
    end
  end

  # Recreate (if spawned) + join ONE template member. A spawned member
  # (`source_template_uri` present) is rebuilt via the unified
  # `Agent.spawn/4` path; a plain invited member uses its declared `uri`.
  defp materialize_one_member(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = granted_by,
         member
       )
       when is_map(member) do
    role_name = member_field(member, :role_name)
    source_template_uri = member_uri_field(member, :source_template_uri)

    with {:ok, %URI{} = member_uri, fresh?} <-
           ensure_member_present(
             member,
             workspace_uri,
             granted_by,
             source_template_uri,
             role_name,
             session_uri
           ) do
      facets =
        %{in_session_template: true}
        |> maybe_put(:role_name, role_name)
        |> maybe_put(:source_template_uri, source_template_uri)

      case join_member_with_facets(session_uri, member_uri, facets) do
        :ok ->
          {:ok, member_uri, role_name, fresh?}

        # codex cycle-2 MAJOR #2 — spawn-succeeds/join-fails. If THIS call
        # freshly spawned the member (`spawn_fresh` already bound the
        # workspace + recorded lineage), surface its URI in the error so the
        # caller folds it into the compensation set BEFORE the join was
        # attempted — otherwise it orphans. A pre-existing (adopted, not
        # fresh) member is NOT ours to tear down, so the plain 2-tuple stands.
        {:error, reason} when fresh? ->
          {:error, reason, member_uri}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # SPAWNED member — recreate from its AgentTemplate via the unified spawn
  # path (demand-spawn; idempotent if already live). The instance name is
  # `<flavor>_<role_name|template_name>` during PR-B only; the flavor is read
  # from the source AgentTemplate's content and passed through
  # `spawn_from_template_content/4` as the stored launch attribute. The new
  # Agent URI itself is opaque and is not parsed for flavor.
  #
  # PR-8 SEAM (clearly-marked): the FULL spawn model — flavor-class launch
  # params, generation/live_worker_uri bookkeeping, repoint-on-update — is
  # PR-8's. PR-7 uses the documented `Agent.spawn/4` primitive + the member
  # `source_template_uri` facet so a materialized spawned member is a real,
  # joinable Agent Kind recreated from its template; PR-8 completes the
  # spawn/regeneration model on top of this facet.
  defp ensure_member_present(
         _member,
         %URI{} = workspace_uri,
         %URI{} = granted_by,
         %URI{} = source_template_uri,
         role_name,
         %URI{} = session_uri
       ) do
    with {:ok, content, flavor} <- source_template_content_and_flavor(source_template_uri) do
      instance_name =
        spawned_member_instance_name(flavor, source_template_uri, role_name, session_uri)

      workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

      agent_uri = Ezagent.URI.agent(workspace_name, instance_name)

      # Route through the Template Class instantiate chokepoint, not bare
      # `spawn_fresh/4`: first spawn cannot resolve flavor from the new opaque
      # Agent URI because its sandbox slice does not exist yet. The source
      # AgentTemplate content is the stored launch attribute.
      case Ezagent.Entity.Agent.spawn_from_template_content(
             content,
             agent_uri,
             granted_by,
             workspace_uri,
             caller: granted_by,
             caps: Ezagent.Identity.list_caps_for(granted_by),
             source_template_uri: source_template_uri
           ) do
        {:ok, %{fresh?: fresh?}} -> {:ok, agent_uri, fresh?}
        {:error, _} = err -> err
      end
    end
  end

  # PLAIN invited member — no spawn source; use its declared `uri`,
  # demand-spawning its Kind so `chat.join` finds it alive (idempotent). A
  # plain member is a pre-declared Kind (not template-spawned by US), so it
  # is NOT in the materialization rollback set — `fresh?: false`.
  defp ensure_member_present(member, _workspace_uri, _granted_by, nil, _role_name, _session_uri) do
    case member_uri_field(member, :uri) do
      %URI{} = member_uri ->
        _ = Ezagent.SpawnRegistry.spawn(member_uri)
        {:ok, member_uri, false}

      _ ->
        {:error, :member_missing_uri}
    end
  end

  # Read the source AgentTemplate's `:template` content once (demand-spawning
  # the template Kind first). The flavor field is a stored template attribute:
  # it derives the temporary PR-B instance-name prefix and selects the Template
  # Class inside `Agent.spawn_from_template_content/4`.
  defp source_template_content_and_flavor(%URI{} = source_template_uri) do
    with {:ok, _pid} <- Session.ensure_template_alive(source_template_uri),
         {:ok, content} <- Session.read_template_content(source_template_uri) do
      case Map.get(content, :flavor) || Map.get(content, "flavor") do
        flavor when is_binary(flavor) and flavor != "" -> {:ok, content, flavor}
        _ -> {:error, {:source_template_missing_flavor, source_template_uri}}
      end
    end
  end

  # codex BLOCKER #1 — the spawned-member instance name MUST be unique per
  # (session, role_name). The pre-fix `"#{flavor}_#{role_name}"` carried NO
  # session discriminator, so two sessions materialized from the SAME
  # template in the SAME workspace collided on the same
  # `entity://agent/<ws>/<flavor>_<role>` URI — the exact isolation bug the
  # Agent session-unique worker naming (`Ezagent.Entity.Agent.session_instance_name/3`,
  # added for the Generator/slot path's CRITICAL+HIGH-6 finding) was built to
  # fix. We REUSE that primitive: it folds the session discriminator (the
  # session URI's name segment) + an injective slot hash into the name, so:
  #   * two sessions from one template → DISTINCT member URIs (isolation);
  #   * a respawn within the SAME session for the SAME role_name → the SAME
  #     name (deterministic, generation 0), so re-materialization is
  #     idempotent (the `{:already_started}` path re-derives the same URI).
  # PR-B keeps the historical `<flavor>_...` name shape only so main stays
  # green before PR-E drops it. Behavior no longer reads that prefix:
  # AgentFlavorRegistry resolution flows through the stored template flavor via
  # `Ezagent.UriQuery.resolve(:flavor, agent_uri)`.
  # PR-8 (§3.8): the orchestrator's `add_managed_member` tool spawns a
  # member the SAME way materialization does — so it shares this canonical
  # session-unique, flavor-prefixed instance name (one source of truth for
  # the per-(session, role) member URI). Exposed via
  # `spawned_member_instance_name_public/4`.
  @doc false
  def spawned_member_instance_name_public(
        flavor,
        %URI{} = source_template_uri,
        role_name,
        %URI{} = session_uri
      ),
      do: spawned_member_instance_name(flavor, source_template_uri, role_name, session_uri)

  defp spawned_member_instance_name(
         flavor,
         %URI{} = source_template_uri,
         role_name,
         %URI{} = session_uri
       )
       when is_binary(flavor) do
    slot =
      if is_binary(role_name) and role_name != "" do
        role_name
      else
        # `template://agent/<ws>/<name>` → `<name>`; fall back to a slug.
        source_template_uri.path
        |> to_string()
        |> String.split("/", trim: true)
        |> List.last() || "member"
      end

    session_unique =
      Ezagent.Entity.Agent.session_instance_name(slot, session_discriminator(session_uri))

    # PR-E: agent URI names carry NO flavor prefix. Flavor is stored
    # (AgentTemplate.flavor) and read via `UriQuery.resolve(:flavor, _)`; the
    # session-unique suffix alone gives per-(session, role) isolation.
    session_unique
  end

  # codex BLOCKER (cycle 2) — the session discriminator MUST be derived from
  # the FULL session URI, not just its name segment. A session URI is
  # `session://<template>/<workspace>/<name>` (host = template), so two
  # sessions from DIFFERENT templates in the SAME workspace with the SAME
  # `<name>` —
  #   `session://templateA/team/main`  and
  #   `session://templateB/team/main`
  # — share the name segment `main`. The pre-fix name-only discriminator fed
  # the SAME value into `Ezagent.Entity.Agent.session_instance_name/3`,
  # collapsing both sessions onto ONE `entity://agent/<ws>/<flavor>_<hash>`
  # member URI — the exact cross-session isolation bug. We now feed the
  # FULL canonical URI string (`URI.to_string/1` — host + full path), which
  # `session_instance_name/3` sanitizes + folds into a wide injective hash:
  #   * distinct session URIs (any differing segment, incl. the template
  #     host) → DISTINCT discriminators → DISTINCT member URIs (isolation);
  #   * the SAME session URI → the SAME discriminator → the SAME member URI
  #     (deterministic; re-materialize / respawn is idempotent).
  @doc false
  # codex PR-7 cycle-3 BLOCKER: `session_instance_name/3` SANITIZES (slugs) its
  # discriminator (the hash there is applied to the slot_name, not the
  # discriminator), so passing the raw URI string lets two session URIs whose
  # slug forms collide (differ only in sanitizer-stripped chars) produce the
  # SAME member URI. Hash the FULL canonical URI to a 128-bit lowercase-hex
  # token: hex is sanitize-stable (identity under sanitize_segment) + injective
  # across distinct session URIs (negligible collision), while the SAME URI
  # stays stable → idempotent respawn. Public so tests share one source of truth.
  def session_discriminator(%URI{} = session_uri) do
    :crypto.hash(:sha256, URI.to_string(session_uri))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  # Dispatch a faceted `chat.join` under the trusted `system://session-internal`
  # principal (same authority class `join_session_members/2` uses), carrying the
  # PR-7 member facets (role_name / in_session_template / source_template_uri).
  defp join_member_with_facets(%URI{} = session_uri, %URI{} = member_uri, facets)
       when is_map(facets) do
    target = Ezagent.URI.with_action(session_uri, :chat, :join)

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: Map.put(facets, :member, member_uri),
        ctx: %{
          caller: Ezagent.SystemPrincipal.uri("session-internal"),
          caps:
            "session-internal"
            |> Ezagent.SystemPrincipal.uri()
            |> Ezagent.SystemPrincipal.caps(),
          reply: {:caller_inbox, self()}
        }
      })

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:member_join_failed, member_uri, reason}}
      other -> {:error, {:member_join_unexpected, member_uri, other}}
    end
  end

  # Step 2 — install the template's named prompt-template map (§3.4).
  defp install_template_prompt_templates(%URI{} = session_uri, template_content) do
    case template_map_field(template_content, :prompt_templates) do
      pts when map_size(pts) == 0 ->
        :ok

      pts ->
        case Ezagent.Behavior.Chat.system_set_prompt_templates(session_uri, pts) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:install_prompt_templates_failed, reason}}
        end
    end
  end

  # Step 3 — install the template's legend registry (§3.6).
  defp install_template_legends(%URI{} = session_uri, template_content) do
    case template_map_field(template_content, :legends) do
      legends when map_size(legends) == 0 ->
        :ok

      legends ->
        case Ezagent.Behavior.Chat.system_set_legends(session_uri, legends) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:install_legends_failed, reason}}
        end
    end
  end

  # Step 4 — install the template's rule-set routing rules (§3.3). Each
  # rule's `role_name` receivers are resolved to the just-materialized
  # member URIs (a magic token / concrete URI string passes through). Rows
  # are written workspace-scoped + STAMPED `created_by = session_uri` (the
  # per-session rule identity, codex MAJOR #4), then the live
  # RoutingRegistry is reloaded so the rules fire immediately.
  #
  # codex MAJOR #4 — IDEMPOTENT per (session, rule_set, position): a rule
  # that already exists for THIS session+rule_set+position is SKIPPED, so a
  # repeated repair / re-materialize does NOT duplicate durable rule rows.
  # codex MAJOR #3 — returns `{:ok, inserted_ids}` (the rows THIS call
  # inserted) and SELF-COMPENSATES (deletes) them if a later rule in the
  # batch fails, so a mid-batch failure leaves no orphan rows.
  defp install_template_rule_sets(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         template_content,
         role_to_uri
       )
       when is_map(role_to_uri) do
    rules = template_routing_rules_of(template_content)

    if rules == [] do
      {:ok, []}
    else
      table = Ezagent.Routing.Resolver.default_routing_table()

      result =
        Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, inserted_ids} ->
          case install_one_rule(table, session_uri, workspace_uri, role_to_uri, rule) do
            {:ok, :exists} ->
              {:cont, {:ok, inserted_ids}}

            {:ok, {:inserted, id}} ->
              {:cont, {:ok, [id | inserted_ids]}}

            {:error, reason} ->
              # Self-compensate the rows inserted earlier in THIS batch
              # before the failing rule (codex MAJOR #3).
              delete_rule_rows(inserted_ids)
              {:halt, {:error, {:install_rule_failed, rule, reason}}}
          end
        end)

      with {:ok, inserted_ids} <- result do
        :ok = Ezagent.Routing.RuleStore.load_into_registry(table)
        {:ok, inserted_ids}
      end
    end
  end

  defp install_one_rule(table, %URI{} = session_uri, %URI{} = workspace_uri, role_to_uri, rule)
       when is_map(rule) do
    matcher = Map.get(rule, :matcher) || Map.get(rule, "matcher")
    rule_set = Map.get(rule, :rule_set) || Map.get(rule, "rule_set")
    position = Map.get(rule, :position) || Map.get(rule, "position") || 0

    # codex MAJOR #4 — idempotency: skip if THIS session already installed a
    # rule at this (rule_set, position). `created_by = session_uri` is the
    # per-session identity the reconcile keys on.
    case Ezagent.Routing.RuleStore.find_by_identity(table, session_uri, rule_set, position) do
      %Ezagent.Routing.RuleStore{} ->
        {:ok, :exists}

      nil ->
        with {:ok, receivers} <-
               resolve_rule_receivers(
                 Map.get(rule, :receivers) || Map.get(rule, "receivers") || [],
                 role_to_uri
               ) do
          add_result =
            Ezagent.Routing.RuleStore.add(
              table,
              matcher,
              receivers,
              # created_by — the SESSION whose materialization created this
              # rule (the per-session identity for idempotent reconcile +
              # rollback). Was `system://session-internal` pre-fix.
              session_uri,
              source: Ezagent.Routing.RuleStore.system_default_source(),
              workspace_uri: workspace_uri,
              rule_set: rule_set,
              position: position,
              prompt_template_ref:
                Map.get(rule, :prompt_template_ref) || Map.get(rule, "prompt_template_ref")
            )

          case add_result do
            {:ok, %Ezagent.Routing.RuleStore{id: id}} -> {:ok, {:inserted, id}}
            {:error, _} = err -> err
          end
        end
    end
  end

  # Delete RuleStore rows by id — force-delete (the materialized rows are
  # `system_default` source, protected from a plain `delete/1`). Best-effort
  # + idempotent (codex MAJOR #3).
  defp delete_rule_rows(ids) when is_list(ids) do
    Enum.each(ids, fn id ->
      safe(fn -> Ezagent.Routing.RuleStore.delete(id, force: true) end)
    end)

    :ok
  end

  # Resolve a rule's declared receivers to concrete receiver values. codex
  # MAJOR #2 — a receiver that is NONE of {a magic token, a concrete
  # `%URI{}`/valid URI-string, a `role_name` among the just-materialized
  # members} is a DANGLING receiver: pre-fix it passed through unchanged,
  # was stored, then `Ezagent.URI.new!/1` raised at send-time (a silent
  # config bug surfacing as a runtime crash). Fail loud HERE instead, so the
  # create rolls back with a clear `{:unknown_rule_receiver, r}` and no
  # partial install. Returns `{:ok, [receiver]}` or
  # `{:error, {:unknown_rule_receiver, r}}`.
  defp resolve_rule_receivers(receivers, role_to_uri) when is_list(receivers) do
    Enum.reduce_while(receivers, {:ok, []}, fn receiver, {:ok, acc} ->
      case resolve_one_receiver(receiver, role_to_uri) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_one_receiver(%URI{} = uri, _role_to_uri), do: {:ok, uri}

  defp resolve_one_receiver(r, role_to_uri) when is_binary(r) do
    cond do
      Ezagent.Routing.Resolver.magic_token?(r) ->
        {:ok, r}

      Map.has_key?(role_to_uri, r) ->
        {:ok, Map.fetch!(role_to_uri, r)}

      true ->
        # Not a role_name + not a magic token — only valid if it is a
        # concrete, well-formed Ezagent URI string. `parse/1` is the
        # non-raising boundary constructor; an arbitrary label (e.g. a
        # mis-typed role_name) fails it → dangling receiver.
        case Ezagent.URI.parse(r) do
          {:ok, %URI{} = uri} -> {:ok, uri}
          {:error, _} -> {:error, {:unknown_rule_receiver, r}}
        end
    end
  end

  defp resolve_one_receiver(other, _role_to_uri),
    do: {:error, {:unknown_rule_receiver, other}}

  # ── PR-7 content-field accessors (tolerate atom/string keys) ─────────

  defp template_members_of(content) when is_map(content) do
    case Map.get(content, :members) || Map.get(content, "members") do
      list when is_list(list) -> Enum.filter(list, &member_in_session_template?/1)
      _ -> []
    end
  end

  defp member_in_session_template?(member) when is_map(member),
    do: member_field(member, :in_session_template) == true

  defp member_in_session_template?(_), do: false

  defp template_routing_rules_of(content) when is_map(content) do
    case Map.get(content, :routing_rules) || Map.get(content, "routing_rules") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp template_map_field(content, key) when is_map(content) do
    case Map.get(content, key) || Map.get(content, Atom.to_string(key)) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp member_field(member, key) when is_map(member) do
    Map.get(member, key) || Map.get(member, Atom.to_string(key))
  end

  defp member_uri_field(member, key) when is_map(member) do
    case member_field(member, key) do
      %URI{} = uri -> uri
      s when is_binary(s) and s != "" -> Ezagent.URI.new!(s)
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp workspace_name_of!(%URI{scheme: "workspace"} = uri), do: Ezagent.URI.name!(uri)

  defp workspace_name_of!(other),
    do: raise(ArgumentError, "expected %URI{scheme: \"workspace\"}, got: #{inspect(other)}")

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
  defdelegate list_sessions, to: Listing

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
  defdelegate list_sessions(workspace_uri), to: Listing
end
