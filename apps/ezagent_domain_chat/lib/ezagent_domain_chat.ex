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
  def repair_orchestrator(%URI{scheme: "session", host: template_name} = session_uri, %URI{} = workspace_uri)
      when is_binary(template_name) and template_name != "" do
    # The SAME per-URI lock ResourceId the create flow uses (`:create_session`,
    # NOT a distinct `:repair_orchestrator` id) so a repair and a concurrent
    # create/repair of the same session actually serialize on one lock. (codex Q4.)
    lock_id = {{:ezagent_domain_chat, :create_session, URI.to_string(session_uri)}, self()}

    try do
      true = :global.set_lock(lock_id, [node()])
      do_repair_orchestrator(session_uri, workspace_uri)
    after
      _ = :global.del_lock(lock_id, [node()])
    end
  end

  def repair_orchestrator(%URI{scheme: "session"}, nil),
    do: {:error, :repair_requires_workspace}

  defp do_repair_orchestrator(%URI{host: template_name} = session_uri, %URI{} = workspace_uri) do
    # The session OWNER carries the orchestrator ownership obligations; read
    # it from the live/durable session so the re-materialize + ensure use
    # the SAME owner the session was created with (NOT the repairing
    # operator — same constraint as the LV restart's `spawned_by` lineage).
    effective_owner =
      case Session.owner(session_uri) do
        {:ok, %URI{} = owner} -> owner
        _ -> User.admin_uri()
      end

    case resolve_repair_template(session_uri, template_name, workspace_uri) do
      {:error, _} = err ->
        err

      {:ok, session_template_uri, template_content} ->
        orchestrator_template_uri = orchestrator_template_uri_of(template_content)

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
              ensure_orchestrated_session(
                session_uri,
                workspace_uri,
                effective_owner,
                session_template_uri
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
    orchestrator_template_uri = orchestrator_template_uri_of(template_content)

    if session_complete?(session_uri, workspace_uri, effective_owner, orchestrator_template_uri) do
      {:ok, session_uri, existing_orchestrator_meta(session_uri, workspace_uri)}
    else
      Logger.warning(
        "EzagentDomainChat.create_session: existing session=" <>
          "#{URI.to_string(session_uri)} is INCOMPLETE (half-create residue) — " <>
          "rolling it back fully then recreating fresh (SPEC 2026-05-31 §4 " <>
          "step 2, codex-review Q2)."
      )

      orch_uri =
        if match?(%URI{}, orchestrator_template_uri) do
          Session.derive_orchestrator_uri(session_uri, workspace_uri)
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
            orch_uri = Session.derive_orchestrator_uri(session_uri, derive_workspace(session_uri))

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

  # The session's bound workspace (for orchestrator URI derivation in the
  # completeness check). Falls back to the session URI's own workspace
  # segment when the binding is absent — but in that case `bound?` is
  # already false, so the orchestrator check is short-circuited anyway.
  defp derive_workspace(%URI{} = session_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, %URI{} = ws} -> ws
      :error -> Ezagent.Capability.workspace_of(session_uri)
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
        # `ensure_orchestrator/3` self-cleans the orchestrator it spawned
        # on its own failure paths (Fix Q4 + `spawn_from_template_content`
        # round-10), so the orchestrator URI is nil here. Still pass owner
        # + workspace to revoke any owner cap (defensive — none granted
        # yet at this point).
        rollback_session(session_uri, nil,
          owner_uri: effective_owner,
          workspace_uri: workspace_uri
        )

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
            # Step 9 — rollback including the spawned orchestrator Kind +
            # its registry/lineage/bind/snapshot + the granted caps
            # (owner restart cap + orchestrator scoped caps), reversed.
            rollback_session(session_uri, orchestrator_uri,
              owner_uri: effective_owner,
              workspace_uri: workspace_uri
            )

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
  # Repair-time template resolution: prefer the EXACT content-addressed
  # SessionTemplate version the session already recorded in its working copy
  # (`:session_template_uri`) over a bare-name lookup, which could pick a
  # different/newer version and re-materialize OTU + parent context from the
  # wrong template. Falls back to name resolution when the session has no
  # recorded version (old/never-materialized session) or it's unreadable.
  # (codex final-review Q4.)
  defp resolve_repair_template(%URI{} = session_uri, template_name, %URI{} = workspace_uri) do
    wc = Session.read_template_working_copy(session_uri)

    case Map.get(wc, :session_template_uri) do
      %URI{} = recorded ->
        with {:ok, _pid} <- Session.ensure_template_alive(recorded),
             {:ok, content} <- Session.read_template_content(recorded) do
          {:ok, recorded, content}
        else
          _ -> resolve_session_template!(template_name, workspace_uri)
        end

      _ ->
        resolve_session_template!(template_name, workspace_uri)
    end
  end

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
      "EzagentDomainChat.create_session: rolling back freshly-created " <>
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
      _ = Ezagent.Kind.terminate(orchestrator_uri)
      safe(fn -> Ezagent.WorkspaceRegistry.unbind(orchestrator_uri) end)
      forget_lineage(orchestrator_uri)
      safe(fn -> Ezagent.Ecto.KindSnapshot.delete(URI.to_string(orchestrator_uri)) end)

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

    # 3. Session Kind + its workspace binding + its snapshot row
    #    (`Kind.Server.init/1` wrote it synchronously at spawn time —
    #    Session.persistence/0 = {:snapshot, :on_change}).
    _ = Ezagent.Kind.terminate(session_uri)
    safe(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    safe(fn -> Ezagent.Ecto.KindSnapshot.delete(URI.to_string(session_uri)) end)
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
          caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
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
