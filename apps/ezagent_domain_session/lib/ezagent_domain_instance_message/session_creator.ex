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

  ## 2026-06-23 — pure session creation

  `create_session/3` is the internal atomic session materializer and the
  **single lower-level writer** (the dead Generator path
  `Session.spawn_from_template/2` was deleted — SPEC
  `docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`
  §1/§7). Rev6 decouples session creation from orchestrator startup:

    1. resolve + validate + build the `session://<template>/<ws>/<name>`
       URI; resolve `template_name` → a real SessionTemplate (fail-loud
       if absent);
    2. spawn the Session Kind (`{:already_started}`/`{:already_registered}`
       → return existing, idempotent, NO adoption re-finalize);
    3. bind the workspace (one idempotent `WorkspaceRegistry.bind`);
    4. record the template declaration (`session_template_uri` +
       `member_declarations`) and install template prompts/legends/rules;
    5. join only the owner and return `%{}`.

  Declared role members are provisioned on first route. Session creation
  never waits for a transport bridge and never rolls the session back because
  a role member failed to start.

  ## 2026-07-09 — contract restored (Allen)

  Between #1140 (07-03) and #1223 (07-07) this contract silently regressed:
  `materialize_template_team/4` grew an agent-spawn step (`DefinitionAgents`)
  and the `default` template's orchestrator moved from a lazily-provisioned
  legacy member declaration onto that eager create-time path. The guard test
  `session_create_orchestrator_decouple_test.exs` was REWRITTEN to assert the
  new behavior, so the suite never went red. Forensics:
  `docs/together/2026-07-09/cc-orchestrator-create-blocking-rootcause.zh_cn.md`.

  Restored shape — **the create transaction spawns no agent**:

    * `create_session/3` installs template CONFIG only
      (`TemplateTeam.materialize_template_config/3` — prompts / legends /
      routing rules) and joins the owner. `session_member_uris/1 == [owner]`.
    * Agent role slots are materialized by `install_session_socialware/1`, a
      SEPARATE transaction. `Workspace.create_session` fires it
      (`install_session_socialware_async/1`) the instant the owner-only session
      is durable, so the caller — and the UI — never block on an agent.
    * Before create reports success it persists a socialware-install obligation.
      Install failures are LOUD (log + telemetry) and retry from that durable
      record after Task failure or service restart; they never roll the session
      back or disappear as an untracked owner-only Session.

  Enforced by `EzagentCore.Architecture.SessionCreateNoAgentSpawnTest` (static
  call-graph gate) + the restored runtime assertion in the decouple test.
  """

  alias Ezagent.Socialware.{DefinitionEditor, Installation}
  alias Ezagent.Entity.{Session, User}

  alias EzagentDomainInstanceMessage.SessionCreator.{
    AgentAdmission,
    DefinitionAgents,
    Derivation,
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

  Returns `{:ok, session_uri, %{}}` on success. Role members, including the
  `orchestrator` role, are durable declarations at create time and are
  provisioned lazily by routing.

  Returns `{:error, reason}` when session creation, the workspace bind, or
  template declaration/rule materialization fails.

  Raises `ArgumentError` if neither `creator_uri` nor
  `opts[:workspace_uri]` is supplied (a `nil` creator with no explicit
  workspace cannot be assigned a workspace structurally).

  Idempotent re-spawn of same short_name returns `{:ok, existing_uri, meta}`
  (via `{:already_started, pid}` → reuse pid, NO adoption re-finalize).
  """
  @type create_session_meta :: %{
          optional(atom()) => term()
        }

  defdelegate rollback_session(session_uri, orchestrator_uri, opts \\ []), to: Rollback

  defdelegate materialize_template_team(session_uri, workspace_uri, granted_by, template_content),
    to: TemplateTeam

  @doc "Install a template's CONFIG (prompts / legends / routing rules). Spawns nothing."
  defdelegate materialize_template_config(session_uri, workspace_uri, template_content),
    to: TemplateTeam

  @doc """
  Record the durable template declaration (`session_template_uri` +
  `member_declarations`) on a session's working copy. `install_session_socialware/1`
  reads `member_declarations` to know which agent role slots to materialize, so a
  Template Class that hand-rolls its session create MUST call this (not a bare
  `system_set_working_copy`) or its declared team can never be installed.
  """
  defdelegate materialize_template_declaration(
                session_uri,
                session_template_uri,
                template_content
              ),
              to: Materializer

  defdelegate spawned_member_instance_name_public(
                flavor,
                source_template_uri,
                role_name,
                session_uri
              ),
              to: TemplateTeam

  defdelegate session_discriminator(session_uri), to: TemplateTeam

  @doc "List durable credential-gated role admissions for a session."
  defdelegate list_agent_admissions(session_uri), to: AgentAdmission, as: :list

  @doc "Start or resume a credential-gated role admission."
  defdelegate begin_agent_admission(session_uri, role_name, actor_uri, caps),
    to: AgentAdmission,
    as: :begin

  @doc "Complete a credential-gated role admission after validation."
  defdelegate complete_agent_admission(session_uri, role_name, attempt_id, actor_and_caps),
    to: AgentAdmission,
    as: :complete

  @doc "Cancel a credential-gated role admission."
  defdelegate cancel_agent_admission(session_uri, role_name, attempt_id, actor_and_caps),
    to: AgentAdmission,
    as: :cancel

  @doc "Expire a credential-gated role admission by attempt ID."
  defdelegate expire_agent_admission(session_uri, attempt_id), to: AgentAdmission, as: :expire

  @install_telemetry [:ezagent, :session, :socialware_install]

  @doc """
  Materialize the session's installed socialware agent role slots — the AGENT
  transaction that `create_session/3` deliberately does NOT run (rev6 / #912).

  Runs AFTER the session exists. A failure is LOUD (log + telemetry) and leaves
  the session intact: `create_session` never rolls back because a role member
  failed to start. Idempotent — a role already joined is skipped.
  """
  @spec install_session_socialware(URI.t()) :: :ok | {:error, term()}
  def install_session_socialware(%URI{scheme: "session"} = session_uri) do
    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = workspace_uri -> install_session_socialware(session_uri, workspace_uri)
      :any -> {:error, :install_requires_workspace}
    end
  end

  @spec install_session_socialware(URI.t(), URI.t() | {URI.t(), URI.t()}) ::
          {:ok, DefinitionAgents.summary()} | {:error, term()}
  def install_session_socialware(
        %URI{scheme: "session"} = session_uri,
        workspace_or_authorization
      ) do
    {workspace_uri, actor_uri} =
      case workspace_or_authorization do
        %URI{} = workspace -> {workspace, nil}
        {%URI{} = workspace, actor} -> {workspace, actor}
      end

    # `read_template_working_copy/1` returns the EMPTY default when the Session
    # Kind is not in the registry, and an empty declaration list is
    # indistinguishable from "this template declares no agent role slots" (the
    # `generic` case). Reading a dead Kind would therefore install nothing and
    # report SUCCESS. Demand-spawn first (idempotent — reuses this module's
    # existing SpawnRegistry chokepoint, no new spawn writer), then require the
    # durable declaration `create_session/3` step 4 wrote.
    _ = demand_spawn_member(session_uri)

    working_copy = Session.read_template_working_copy(session_uri)

    case Map.get(working_copy, :session_template_uri) do
      %URI{} ->
        Ezagent.Socialware.SessionInstaller.install(
          session_uri,
          workspace_uri,
          working_copy,
          actor_uri
        )

      _ ->
        {:error, {:no_template_declaration, session_uri}}
    end
  end

  @doc """
  The durable, queryable record of role slots this session DECLARES but could not
  fill — today only "the flavor needs credentials this installer cannot be given"
  (`Ezagent.Agent.CredentialPrecondition`).

  A server-side `Logger.error` alone is a silent drop at a user-facing surface
  (Invariant #9): the user asked for an orchestrator and got a session without
  one. This is the read model the world UI renders (`unfilled_agent_role_slots`
  mirrors the existing `human_role_slots` shape).
  """
  @spec unfilled_agent_role_slots(URI.t()) :: [map()]
  def unfilled_agent_role_slots(%URI{scheme: "session"} = session_uri) do
    session_uri
    |> Session.read_template_working_copy()
    |> Map.get(:unfilled_agent_role_slots, [])
  end

  # Written on EVERY install, so a retry that now succeeds CLEARS a stale record.
  @doc false
  def record_unfilled_role_slots(%URI{} = session_uri, skipped) when is_list(skipped) do
    rows =
      Enum.map(skipped, fn %{role_name: role_name, reason: reason} ->
        %{role_name: role_name, reason: reason_tag(reason)}
      end)

    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(:unfilled_agent_role_slots, rows)

    case Ezagent.ActionSet.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:record_unfilled_role_slots_failed, reason}}
      other -> {:error, {:record_unfilled_role_slots_failed, other}}
    end
  end

  # A stable atom for the UI to switch on; the full reason stays in the log +
  # telemetry, where operators (not end users) look.
  defp reason_tag({:no_credential_source, _flavor}), do: :missing_credentials
  defp reason_tag({:config_home_without_credentials, _flavor}), do: :missing_credentials
  # Env-backed flavors (deepseek today; #1449 cc-custom profiles) fail with a
  # DIFFERENT fix path — a deploy-env provider key, not a Claude login/source —
  # so the UI/operator must not read it as "adopt a credential source" (任务 B
  # DoD-3: 区分"缺 Claude 凭证" vs "缺 provider key").
  defp reason_tag({:credential_unavailable, _flavor}), do: :missing_provider_credential
  defp reason_tag(_other), do: :unavailable

  @doc """
  Persist a recoverable socialware-install obligation, then wake it immediately
  under a supervised Task.

  The database obligation is authoritative: `Workspace.create_session` reports
  success only after it exists. The Task is a latency optimization; if it cannot
  start or dies, `Ezagent.Session.SocialwareInstallSweeper` reclaims the lease
  and retries the idempotent installation after restart.
  """
  @spec install_session_socialware_async(URI.t() | {URI.t(), URI.t()}) ::
          :ok | {:error, term()}
  def install_session_socialware_async(session_or_authorization) do
    {session_uri, actor_uri} =
      case session_or_authorization do
        %URI{scheme: "session"} = session -> {session, nil}
        {%URI{scheme: "session"} = session, %URI{} = actor} -> {session, actor}
      end

    working_copy = Session.read_template_working_copy(session_uri)

    case working_copy do
      %{session_template_uri: %URI{}, member_declarations: []} ->
        :ok

      %{session_template_uri: %URI{}, member_declarations: [_ | _]} ->
        persist_and_wake_socialware_install(session_uri, actor_uri)

      _ ->
        {:error, {:socialware_install_not_persisted, :incomplete_template_declaration}}
    end
  end

  defp persist_and_wake_socialware_install(session_uri, actor_uri) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    with %URI{} <- workspace_uri,
         {:ok, obligation} <-
           Ezagent.Session.SocialwareInstallObligations.ensure_pending(
             session_uri,
             workspace_uri,
             actor_uri
           ) do
      wake_socialware_install(obligation.id, session_uri)
      :ok
    else
      :any ->
        {:error, :install_requires_workspace}

      {:error, reason} ->
        Logger.error(
          "could not persist socialware-install obligation for " <>
            "#{URI.to_string(session_uri)}: #{inspect(reason)}"
        )

        :telemetry.execute(
          @install_telemetry ++ [:failed],
          %{count: 1},
          %{session_uri: session_uri, reason: {:obligation_persist_failed, reason}}
        )

        {:error, {:socialware_install_not_persisted, reason}}
    end
  end

  defp wake_socialware_install(obligation_id, session_uri) do
    start_result =
      try do
        Task.Supervisor.start_child(Ezagent.Session.SocialwareInstallSupervisor, fn ->
          Ezagent.Session.SocialwareInstallSweeper.retry(obligation_id)
        end)
      catch
        :exit, reason -> {:error, {:supervisor_unavailable, reason}}
      end

    case start_result do
      {:ok, _pid} ->
        :ok

      other ->
        Logger.warning(
          "socialware-install immediate wake-up failed for #{URI.to_string(session_uri)}: " <>
            "#{inspect(other)}; durable obligation #{obligation_id} remains pending"
        )

        :ok
    end
  end

  @doc false
  def demand_spawn_member(%URI{} = member_uri), do: Ezagent.SpawnRegistry.spawn(member_uri)

  @doc false
  defdelegate join_session_members(session_uri, members), to: Materializer

  @doc false
  @spec grant_session_owner_membership(URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_session_owner_membership(%URI{} = session_uri, %URI{} = owner_uri) do
    Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(session_uri, owner_uri)
  end

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

    with :ok <-
           Ezagent.WorkspaceOwnerGate.assert_local_owner(
             workspace_uri,
             {:session_create, session_uri}
           ) do
      # 2026-05-31 orchestrator-startup-atomicity §4 — a thin per-URI lock.
      # With adoption gone + spawn idempotent, the `:fresh`-rollback vs
      # `:adopted`-commit interleave that originally justified this lock
      # (codex #409) no longer exists. We KEEP a thin per-URI lock because
      # it remains cheap and clearly safe inside the workspace owner runtime:
      # two callers racing the SAME URI would otherwise both run the 4-8 setup
      # + a possible rollback, tearing each other's partial state. The explicit
      # `[node()]` scope remains local and must not be treated as cross-runtime
      # ownership.
      lock_id =
        {{:ezagent_domain_session, :create_session, URI.to_string(session_uri)}, self()}

      try do
        true = :global.set_lock(lock_id, [node()])
        do_create_session(session_uri, workspace_uri, creator_uri, template_name)
      after
        _ = :global.del_lock(lock_id, [node()])
      end
    end
  end

  def create_session(_short_name, _creator, _opts), do: {:error, :short_name_required}

  @doc """
  Repair an EXISTING session's orchestrator (SPEC 2026-05-31 §6).

  Re-materializes the freeze-pinned declaration under a new binding epoch.
  Skip restores the active binding; definitive failure writes a discoverable
  same-URI tombstone. Authorization remains the caller surface's responsibility.
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

  @spec repair_orchestrator(URI.t(), URI.t() | {URI.t(), URI.t()} | nil) ::
          {:ok, URI.t(), create_session_meta()} | {:error, term()}
  def repair_orchestrator(
        %URI{scheme: "session"} = session_uri,
        workspace_or_authorization
      ) do
    case workspace_or_authorization do
      nil ->
        {:error, :repair_requires_workspace}

      workspace_or_actor ->
        {workspace_uri, actor_uri} =
          case workspace_or_actor do
            %URI{} = workspace -> {workspace, nil}
            {%URI{} = workspace, %URI{} = actor} -> {workspace, actor}
          end

        _template_name = Ezagent.URI.type!(session_uri)

        with :ok <-
               Ezagent.WorkspaceOwnerGate.assert_local_owner(
                 workspace_uri,
                 {:session_repair, session_uri}
               ) do
          # The SAME per-URI lock ResourceId the create flow uses (`:create_session`,
          # NOT a distinct `:repair_orchestrator` id) so a repair and a concurrent
          # create/repair of the same session actually serialize on one lock. (codex Q4.)
          lock_id =
            {{:ezagent_domain_session, :create_session, URI.to_string(session_uri)}, self()}

          try do
            true = :global.set_lock(lock_id, [node()])
            do_repair_orchestrator(session_uri, workspace_uri, actor_uri)
          after
            _ = :global.del_lock(lock_id, [node()])
          end
        end
    end
  end

  defp do_repair_orchestrator(%URI{} = session_uri, %URI{} = workspace_uri, actor_uri) do
    template_name = Ezagent.URI.type!(session_uri)

    # The session OWNER carries the orchestrator ownership obligations; read
    # it from the live/durable session so the re-materialize + ensure use
    # the SAME owner the session was created with (NOT the repairing
    # operator — same constraint as the LV restart's `spawned_by` lineage).
    with {:ok, %URI{} = effective_owner} <- Session.owner(session_uri) do
      case TemplateResolver.resolve_for_repair(session_uri, template_name, workspace_uri) do
        {:error, _} = err ->
          err

        {:ok, session_template_uri, template_content} ->
          # Freeze-pin (§4.4) MUST cover the repair/rematerialization path: the
          # recorded SessionTemplate content is UNPINNED (only the per-session
          # install RECORDS carry the frozen `config_id`), so re-materializing from
          # it raw would resolve each install LIVE and let a later publish/retract
          # change this EXISTING session's behaviors. Re-pin from the session's own
          # install records so repair rebuilds from the SAME frozen revision the
          # session was created with.
          pinned_content = Installation.pin_installs_from_session(session_uri, template_content)

          with :ok <-
                 Materializer.materialize_template_declaration(
                   session_uri,
                   session_template_uri,
                   pinned_content
                 ),
               {:ok, _binding} <-
                 Materializer.prepare_orchestrator_binding(session_uri, workspace_uri) do
            case materialize_template_team(
                   session_uri,
                   workspace_uri,
                   {effective_owner, actor_uri},
                   pinned_content
                 ) do
              :ok ->
                {:ok, session_uri, %{}}

              {:error, reason, _partial} = error ->
                _ = Materializer.tombstone_orchestrator_binding(session_uri, reason)
                error

              {:error, reason} = error ->
                _ = Materializer.tombstone_orchestrator_binding(session_uri, reason)
                error
            end
          end
      end
    else
      _ -> {:error, {:no_session_owner, session_uri}}
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

    # Step 1b — preserve an existing session's exact template pin; otherwise
    # resolve `template_name` in the session's workspace (SPEC §4 step 1).
    case TemplateResolver.resolve_for_repair(session_uri, template_name, workspace_uri) do
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
         raw_template_content
       ) do
    # SPEC §4.1/§4.4 (Decision A) — freeze-pin BEFORE resolving behaviors: resolve
    # each install to its CURRENT revision and bake the pin into the content's
    # `installs`. The frozen content threads into BOTH behavior resolution and the
    # per-session install records (via `finalize_fresh_session`), so a later
    # publish does NOT change this session's behaviors. This is one of the two
    # production `behavior_set_for_template/2` call sites the freeze MUST cover.
    with {:ok, template_content} <-
           Installation.freeze_template_installs(raw_template_content, workspace_uri) do
      do_create_frozen(
        session_uri,
        workspace_uri,
        effective_owner,
        session_template_uri,
        template_content
      )
    end
  end

  defp do_create_frozen(
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
    with {:ok, behaviors} <-
           Installation.behavior_set_for_template(template_content, workspace_uri),
         :ok <-
           Derivation.record(session_uri, {effective_owner, workspace_uri, session_template_uri}) do
      # derivation-edge: recorded-by Derivation.record/2 in this with-chain
      case Ezagent.Kind.spawn(Session, %{
             uri: session_uri,
             owner_uri: effective_owner,
             # P4 socialware-unification: the SessionTemplate's `installs`
             # field resolves through ConfigStore-backed socialware definitions
             # and selects the explicit per-instance behavior set.
             behaviors: behaviors
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
    if session_complete?(session_uri, workspace_uri, effective_owner, template_content) do
      case Installation.install_template_installs(
             session_uri,
             workspace_uri,
             template_content,
             effective_owner
           ) do
        :ok -> {:ok, session_uri, %{}}
        {:error, reason} -> {:error, reason}
      end
    else
      Logger.warning(
        "EzagentDomainInstanceMessage.SessionCreator.create_session: existing session=" <>
          "#{URI.to_string(session_uri)} is INCOMPLETE (half-create residue) — " <>
          "rolling it back fully then recreating fresh (SPEC 2026-05-31 §4 " <>
          "step 2, codex-review Q2)."
      )

      rollback_session(session_uri, nil,
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
    with {:ok, behaviors} <-
           Installation.behavior_set_for_template(template_content, workspace_uri),
         :ok <-
           Derivation.record(session_uri, {effective_owner, workspace_uri, session_template_uri}) do
      # derivation-edge: recorded-by Derivation.record/2 in this with-chain
      case Ezagent.Kind.spawn(Session, %{
             uri: session_uri,
             owner_uri: effective_owner,
             behaviors: behaviors
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
  end

  # Completeness predicate for an already-existing Session. A complete
  # rev6 session is bound to a workspace, has the owner joined, and carries
  # the durable template declaration record. Live role members are
  # provisioned lazily by routing and are NOT part of create completeness.
  defp session_complete?(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = owner_uri,
         template_content
       ) do
    bound? = match?({:ok, _}, Ezagent.WorkspaceRegistry.lookup(session_uri))
    owner_member? = owner_uri in Session.session_member_uris(session_uri)
    wc = Session.read_template_working_copy(session_uri)

    declarations =
      case DefinitionEditor.member_declarations_for_template(template_content, workspace_uri) do
        {:ok, list} -> Enum.filter(list, &template_member_declaration?/1)
        {:error, _} -> []
      end

    bound? and owner_member? and
      match?(%URI{}, Map.get(wc, :session_template_uri)) and
      Map.get(wc, :member_declarations, []) == declarations
  end

  defp template_member_declaration?(member) when is_map(member) do
    (Map.get(member, :in_session_template) || Map.get(member, "in_session_template")) == true
  end

  defp template_member_declaration?(_), do: false

  # Best-effort wait for the Session Kind to leave the KindRegistry after
  # a rollback terminate (so the recreate re-spawn is clean). Bounded
  # poll; returns `:ok` once gone or `:timeout` after `deadline_ms`.
  defp await_terminated(%URI{} = session_uri, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_terminated(session_uri, deadline)
  end

  defp do_await_terminated(%URI{} = session_uri, deadline) do
    if Ezagent.Kind.alive?(session_uri) do
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(20)
        do_await_terminated(session_uri, deadline)
      end
    else
      :ok
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
    result =
      with :ok <- Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri),
           :ok <-
             Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(
               session_uri,
               effective_owner
             ),
           :ok <-
             Materializer.materialize_template_declaration(
               session_uri,
               session_template_uri,
               template_content
             ),
           # P1 I7: commit the exact URI before async install can expose it.
           {:ok, _binding} <-
             Materializer.prepare_orchestrator_binding(session_uri, workspace_uri),
           :ok <- Materializer.join_session_members(session_uri, [effective_owner]),
           # F7 PR-A: grant every session owner the member-scoped authority to
           # remove participants. `granted_by: owner`, #154-clean and idempotent.
           :ok <-
             Materializer.grant_owner_remove_participant_cap(
               session_uri,
               effective_owner,
               workspace_uri
             ),
           :ok <-
             Materializer.grant_owner_assign_role_cap(
               session_uri,
               effective_owner,
               workspace_uri
             ),
           :ok <-
             Installation.install_template_installs(
               session_uri,
               workspace_uri,
               template_content,
               effective_owner
             ),
           # rev6 step 4 — CONFIG ONLY (prompts / legends / routing rules).
           # Agent role slots are an AGENT transaction and are materialized
           # AFTER create returns, by `install_session_socialware/1`. See the
           # moduledoc + `session_create_orchestrator_decouple_test.exs`.
           :ok <-
             TemplateTeam.materialize_template_config(
               session_uri,
               workspace_uri,
               template_content
             ),
           # Seed the Surface from a "published" template's captured page
           # (`content.seed_surface`) so the new session renders the same page as
           # the one it was published from — no conversation history. Best-effort:
           # `SurfaceSeed.seed/3` always returns `:ok`, so a seed hiccup never
           # rolls back an otherwise-valid session.
           :ok <-
             Ezagent.Session.SurfaceSeed.seed(
               session_uri,
               seed_surface_of(template_content),
               effective_owner
             ) do
        {:ok, session_uri, %{}}
      end

    case result do
      {:ok, _, _} = ok ->
        ok

      {:error, reason} ->
        # Step 9: this arm spawned no orchestrator; revoke the owner caps too.
        rollback_session(session_uri, nil,
          owner_uri: effective_owner,
          workspace_uri: workspace_uri
        )

        {:error, reason}
    end
  end

  # The captured page a "published" template carries (nil for ordinary templates).
  defp seed_surface_of(content) when is_map(content),
    do: Map.get(content, :seed_surface) || Map.get(content, "seed_surface")

  defp seed_surface_of(_), do: nil

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

  @spec list_sessions(URI.t(), URI.t() | nil) :: [URI.t()]
  defdelegate list_sessions(workspace_uri, caller_uri), to: Listing

  @spec list_persisted_sessions(URI.t()) :: [URI.t()]
  defdelegate list_persisted_sessions(workspace_uri), to: Listing

  @doc """
  Return live sessions in the agent's workspace whose chat membership includes
  `agent_uri`. Used by operator surfaces to block destructive agent deletion
  while the agent is still bound to a running session.
  """
  @spec agent_live_sessions(URI.t()) :: {:ok, [URI.t()]} | {:error, term()}
  defdelegate agent_live_sessions(agent_uri), to: Listing

  @doc "True when `agent_uri` is a member of at least one live session."
  @spec agent_in_live_session?(URI.t()) :: {:ok, boolean()} | {:error, term()}
  defdelegate agent_in_live_session?(agent_uri), to: Listing
end
