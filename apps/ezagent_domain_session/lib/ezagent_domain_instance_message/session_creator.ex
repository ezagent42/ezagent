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

  alias Ezagent.KindRegistry
  alias Ezagent.Entity.{Session, User}

  alias EzagentDomainInstanceMessage.SessionCreator.{
    Listing,
    Materializer,
    Rollback,
    TemplateResolver,
    TemplateTeam
  }

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

  defdelegate rollback_session(session_uri, orchestrator_uri, opts \\ []), to: Rollback

  defdelegate materialize_template_team(session_uri, workspace_uri, granted_by, template_content),
    to: TemplateTeam

  defdelegate spawned_member_instance_name_public(
                flavor,
                source_template_uri,
                role_name,
                session_uri
              ),
              to: TemplateTeam

  defdelegate session_discriminator(session_uri), to: TemplateTeam

  @doc false
  def demand_spawn_member(%URI{} = member_uri), do: Ezagent.SpawnRegistry.spawn(member_uri)

  @doc false
  def list_caps_for_materialization(%URI{} = actor_uri),
    do: Ezagent.Identity.list_caps_for(actor_uri)

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
      {{:ezagent_domain_session, :create_session, URI.to_string(session_uri)}, self()}

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
      {{:ezagent_domain_session, :create_session, URI.to_string(session_uri)}, self()}

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
               Materializer.materialize_orchestrator_working_copy(
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
    # so `Behavior.Session.init_slice/1` records it on the session's `:chat`
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
    case Ezagent.Kind.spawn(Session, %{
           uri: session_uri,
           owner_uri: effective_owner,
           # P5-0b: explicit chat behavior set → non-nil :kind_base (scoped
           # guard). P5-1b: `Session.behaviors/0` is now the UNION, so this
           # passes `chat_behaviors/0` (the chat subset) — selects
           # {Session, Publisher, ExternalMirror}, excludes Turn/Surface so the
           # P1 per-instance gate denies them on chat instances.
           behaviors: Session.chat_behaviors()
         }) do
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
    case Ezagent.Kind.spawn(Session, %{
           uri: session_uri,
           owner_uri: effective_owner,
           # P5-0b: explicit chat behavior set on the recreate-after-rollback
           # path too → non-nil :kind_base. P5-1b: now the chat SUBSET of the
           # union (`chat_behaviors/0`), not the union itself.
           behaviors: Session.chat_behaviors()
         }) do
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
  #     `OrchestratorReadinessPort.ready?/1` → true (the registry row OR
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

            # PR-8 (transport #53) — route the orchestrator-MCP readiness check
            # through the session-owned port (returns a boolean) instead of
            # naming the now-cc-resident `McpServer`. The port's `ready?/1`
            # wraps the same `match?({:ok, _}, McpServer.from_orchestrator_uri/1)`.
            match?(%URI{}, orch_uri) and
              Ezagent.Session.OrchestratorReadinessPort.ready?(orch_uri)
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
             Materializer.materialize_orchestrator_working_copy(
               session_uri,
               session_template_uri,
               orchestrator_template_uri
             ) do
        case orchestrator_template_uri do
          nil ->
            # Step 4 — plain session (no orchestrator). Join the creator
            # only; skip 5-7. Then materialize the template team (PR-7).
            with :ok <- Materializer.join_session_members(session_uri, [effective_owner]),
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

    # Step 4.5 — pre-persist the deterministic planned orchestrator URI to the
    # durable session working-copy BEFORE the step-5 readiness gate, so the
    # live orchestrator's MCP bridge join can self-register (McpServer lazy
    # rebuild from the durable snapshot) DURING the gate's poll. Without this
    # the join is rejected `:orchestrator_not_registered` until step 6 — which
    # runs AFTER the gate — so the gate times out (90s) and rolls the create
    # back. See docs/notes/2026-06-15-live-orchestrator-mcp-registration-bug.md.
    #
    # ONLY on the fresh-create path (`new_session?: true`). There, EVERY failure
    # rolls the whole freshly-created session back (`rollback_session/3` deletes
    # the Session Kind + snapshot — atomicity Q1), so a failed gate cannot leave
    # a stale pre-stored binding behind. The repair path (`new_session?: false`)
    # deliberately keeps the live session on failure (lines below), so
    # pre-storing there could persist a planned `:orchestrator_uri` for an
    # orchestrator that never finalized → `McpServer.from_orchestrator_uri/1` /
    # `session_complete?/4` would then report FALSE readiness from that artifact
    # (codex adversarial-review HIGH/NO-SHIP, 2026-06-15). Repair-path pre-store
    # would need transactional compensation; tracked as follow-up in
    # docs/futures/todo.md. The repair path's pre-existing live-join timing is
    # unchanged by this PR.
    if new_session? do
      _ = Materializer.prestore_planned_orchestrator_uri(session_uri, workspace_uri)
    end

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
        with :ok <- Materializer.store_session_orchestrator_uri(session_uri, orchestrator_uri),
             :ok <-
               Session.grant_orchestrator_scoped_caps(
                 orchestrator_uri,
                 session_uri,
                 effective_owner
               ),
             :ok <-
               Materializer.grant_owner_orchestrator_admin_cap(
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
             # Transport #53 Decision C — spawn the per-orchestrator MCP
             # executor (`Ezagent.Session.SessionManager` GenServer) alongside
             # the transport-context registration. The cc MCP transport reaches
             # it by orchestrator URI; it verifies the bridge token, reconstructs
             # the orchestrator's caps session-side, and runs each tool with the
             # Session cap-checked at the dispatch chokepoint. Terminated with
             # the session.
             {:ok, _sm_pid} <-
               Ezagent.Session.SessionManager.ensure_started(
                 orchestrator_uri: orchestrator_uri,
                 session_uri: session_uri,
                 workspace_uri: workspace_uri,
                 owner_uri: effective_owner,
                 parent_template_uri: session_template_uri
               ),
             :ok <-
               Materializer.join_session_members(session_uri, [
                 effective_owner,
                 orchestrator_uri
               ]),
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
