defmodule Ezagent.Entity.Session.Orchestrator do
  @moduledoc false

  require Logger

  # ensure_orchestrator — spawn / adopt the session's orchestrator agent
  # (2026-05-31 orchestrator-startup-atomicity §4 step 5; 2-way ownership)
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Ensure an orchestrator agent exists for `session_uri` in `workspace_uri`
  owned by `owner_uri`. Returns one of three shapes:

    * `{:ok, orchestrator_uri, :created | :already_present}` — orchestrator
      is alive in `KindRegistry`, owned by `owner_uri`, bound to
      `workspace_uri`. `:created` ⇔ this call started the worker;
      `:already_present` ⇔ the worker pre-existed.
    * `{:partial, %{orchestrator_pending: candidate_uri}}` — the URI is
      reserved but ownership classification is incomplete (lineage and/or
      workspace registries haven't caught up). LV / CLI should render
      "pending" + invite a retry.
    * `{:error, reason}` — orchestrator spawn failed OR positive foreign
      evidence (lineage/workspace POSITIVELY mismatch) was detected.

  Made public 2026-05-26 (SPEC `2026-05-26-session-create-orchestrator-unified`
  Gap A) so `EzagentDomainInstanceMessage.SessionCreator.create_session/3` can wire it in directly,
  giving the LV/CLI/bootstrap entry the same auto-spawn semantics the
  SessionTemplate.instantiate path always had. The internal logic is
  unchanged from when this was `defp` — only the visibility flipped.

  This call brings up the orchestrator's **Agent Kind GenServer** (the
  chat-domain identity for the orchestrator) AND its cc PTY +
  `claude` subprocess by calling `Agent.spawn_from_template_content/4`
  directly with the cc-orchestrator AgentTemplate's content slice. The
  orchestrator's "orchestrator" role — which causes the cc Template
  Class to load the `ezagent-session-orchestrator` skill into the
  per-agent config dir + append the CLAUDE.md hint + set
  `EZAGENT_AGENT_ROLE=orchestrator` in `cmd_env` — is carried on the
  cc-orchestrator AgentTemplate's content slice (seeded by
  `Ezagent.Orchestrator.CcOrchestratorSeed.seed/0`), threaded through
  `Ezagent.Entity.AgentTemplate.to_template_data/2`.

  ## codex PR #408 review CRIT — call spawn_from_template_content directly

  Pre-fix this branch called `Agent.spawn_fresh/4` directly, which goes
  through the spawn-registry detailed path → `Kind.spawn(Agent,
  ...)` and NEVER reaches `Template.instantiate`. The cc Template Class's
  `apply_orchestrator_role_bootstrap/2` therefore never ran on the
  auto-spawn path. Result: orchestrator agents created via
  `ensure_orchestrator` got no skill copy, no CLAUDE.md hint, and no
  `EZAGENT_AGENT_ROLE` env var — entire SPEC Gap B was dead.

  Post-fix this branch reads the cc-orchestrator AgentTemplate's content
  slice via `:sys.get_state` (the AgentTemplate Kind is the SOLE source
  of truth) and calls `Agent.spawn_from_template_content/4` — the same
  helper the `Behavior.Template :instantiate` action body calls, minus
  the dispatch-level CapBAC + the action-body's anti-cross-workspace
  workspace_uri check (`apps/ezagent_domain_session/.../behavior/template.ex`
  line 435 `resolve_workspace_uri/3` — "cross-workspace instantiation is
  not a V1 feature"). The cc-orchestrator AgentTemplate is system-scoped
  (`template://agent/system/cc-orchestrator`) but each tenant workspace's
  orchestrator agent must land in THEIR OWN workspace. This is a
  legitimate cross-workspace spawn the dispatch path was never designed
  for — going around the action body but still through the in-process
  helper gives us the cc Template Class's role-bootstrap while
  preserving structural ownership semantics (lineage + workspace bind
  happen inside `spawn_from_template_content/4`).

  The `role_degraded` info that `cc_agent` surfaces in its meta map
  when skill-copy fails (codex PR #408 review HIGH-3) is propagated
  through to `EzagentDomainInstanceMessage.SessionCreator.create_session/3`'s meta so the caller
  can notify the owner per Invariant #9.
  """
  @spec ensure_orchestrator(URI.t(), URI.t(), URI.t()) ::
          {:ok, URI.t(), :created | :already_present}
          | {:ok, URI.t(), :created | :already_present, map()}
          | {:error, term()}
  def ensure_orchestrator(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = owner_uri
      ) do
    # 2026-05-31 orchestrator-startup-atomicity §4 step 5 — ownership is
    # now 2-way (`:owned` / `:not_live` / `:foreign`). The
    # `:ownership_pending` retry loop (`retry_after_race`/`do_retry`/
    # `@retry_*`) is DELETED: with the dead Generator gone + adoption
    # removed, the atomic create commits lineage + workspace bind inside
    # the spawn before this classification runs, so there is no limbo
    # window for a freshly-spawned orchestrator. A live URI that does
    # NOT positively match us is `:foreign` (real cross-tenant collision
    # / corruption) → fail-loud. The caller
    # (`EzagentDomainInstanceMessage.SessionCreator.create_session/3`) rolls back on `{:error, _}`.
    candidate_uri = build_orchestrator_uri_for_create(session_uri, workspace_uri)
    orch_template_uri = Ezagent.URI.template(:system, :agent, "cc-orchestrator")
    instance_name = build_orchestrator_instance_name_for_create(session_uri)

    case check_orchestrator(candidate_uri, owner_uri, workspace_uri) do
      {:owned, ^candidate_uri} ->
        {:ok, candidate_uri, :already_present}

      :not_live ->
        # codex PR #408 review CRIT — instantiate via the cc Template
        # Class (`spawn_from_template_content/4`) so the role-bootstrap
        # runs, instead of bypass-spawning via `Agent.spawn_fresh/4`.
        #
        # 2026-05-31 codex-review Q4 — the pre-spawn `check_orchestrator`
        # above is a TOCTOU window: a concurrent registration of the same
        # orchestrator URI between this `:not_live` classification and
        # the template-instantiate makes `Agent.spawn_from_template_content`
        # ADOPT the existing worker (`fresh? == false`), and the adopted
        # path SKIPS the lineage + workspace obligations a fresh spawn
        # establishes. We therefore RE-VERIFY ownership AFTER the spawn
        # (`finalize_spawned_orchestrator/5`): an adopted worker has its
        # lineage + bind established idempotently so it carries the SAME
        # ownership records a fresh one does, and a post-spawn URI that
        # still does not classify `:owned` is a real foreign claim →
        # `{:error, _}` (→ caller rollback, fail-loud). No silent success
        # on an unverified adoption.
        spawn_result =
          case spawn_orchestrator_via_template_content(
                 candidate_uri,
                 orch_template_uri,
                 instance_name,
                 workspace_uri,
                 owner_uri
               ) do
            {:error, _} = err ->
              err

            {:ok, ^candidate_uri, outcome, fresh?, degraded_meta} ->
              finalize_spawned_orchestrator(
                candidate_uri,
                owner_uri,
                workspace_uri,
                outcome,
                fresh?,
                degraded_meta
              )
          end

        spawn_result

      {:foreign, evidence} ->
        # POSITIVE foreign evidence (lineage / workspace POSITIVELY
        # mismatches). Real corruption / cross-tenant collision.
        {:error, {:orchestrator_foreign, candidate_uri, evidence}}
    end
  end

  # 2026-05-31 codex-review Q4 — post-spawn ownership re-verification +
  # adopted-orchestrator lineage/bind establishment.
  #
  #   * `fresh? == true`  — `spawn_from_template_content/4` already ran
  #     `establish_post_spawn_obligations/3` (lineage + workspace bind)
  #     inside the spawn. We still RE-CHECK to close the race where a
  #     concurrent claimant overwrote our just-recorded ownership; a
  #     non-`:owned` result is fail-loud.
  #   * `fresh? == false` — ADOPTED a worker someone else (or a racing
  #     create) registered. The adopt path in `spawn_from_template_content/4`
  #     SKIPS the obligations, so we establish them HERE, idempotently
  #     (`AgentLineage.record/2` upserts; `WorkspaceRegistry.bind/2`
  #     overwrites), giving the adopted orchestrator the SAME lineage +
  #     bind a fresh one has — THEN re-check `:owned`.
  #
  # A `check_orchestrator/3` that is not `:owned` after this →
  # `{:error, {:orchestrator_not_owned_after_spawn, candidate_uri, ev}}`
  # so the caller (`EzagentDomainInstanceMessage.SessionCreator.create_session/3`) rolls back.
  defp finalize_spawned_orchestrator(
         %URI{} = candidate_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri,
         outcome,
         fresh?,
         degraded_meta
       ) do
    unless fresh? do
      _ = establish_orchestrator_ownership(candidate_uri, owner_uri, workspace_uri)
    end

    case check_orchestrator(candidate_uri, owner_uri, workspace_uri) do
      {:owned, ^candidate_uri} ->
        wrap_orchestrator_ok(candidate_uri, outcome, degraded_meta)

      other ->
        {:error, {:orchestrator_not_owned_after_spawn, candidate_uri, other}}
    end
  end

  # Idempotent ownership records for an ADOPTED orchestrator — the same
  # two writes `Agent.establish_post_spawn_obligations/3` performs for a
  # fresh worker, lifted here so the adopt path is not left without them.
  # Both are upsert/overwrite semantics, so a re-run (or running over a
  # worker that already had them) is a no-op.
  defp establish_orchestrator_ownership(
         %URI{} = orchestrator_uri,
         %URI{} = owner_uri,
         %URI{} = workspace_uri
       ) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and
         function_exported?(Ezagent.AgentLineage, :record, 2) do
      _ = Ezagent.AgentLineage.record(orchestrator_uri, owner_uri)
    end

    _ = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, workspace_uri)
    :ok
  end

  defp wrap_orchestrator_ok(%URI{} = candidate_uri, outcome, degraded_meta)
       when map_size(degraded_meta) == 0,
       do: {:ok, candidate_uri, outcome}

  defp wrap_orchestrator_ok(%URI{} = candidate_uri, outcome, degraded_meta),
    do: {:ok, candidate_uri, outcome, degraded_meta}

  # 2026-05-31 orchestrator-startup-atomicity §5 — the LIVE-join readiness
  # gate. Called AFTER the spawn + ownership finalize. On a spawn/finalize
  # error it short-circuits (no PTY to gate). On success it awaits the
  # live bridge join via a robust poll:
  #
  # codex PR #408 review CRIT — call `Agent.spawn_from_template_content/4`
  # directly after reading the cc-orchestrator AgentTemplate's content
  # slice. This routes the spawn through the cc Template Class's
  # `instantiate/3` (so role-bootstrap runs) but skips the dispatch's
  # action-body anti-cross-workspace check (`Behavior.Template.resolve_workspace_uri/3`)
  # — the cc-orchestrator template is `template://agent/system/...` but
  # each tenant workspace's orchestrator agent must land in THEIR OWN
  # workspace, which is a legitimate cross-workspace spawn the action
  # body intentionally refuses for V1.
  #
  # `instance_name` is the bare segment (e.g. `cc_orchestrator-<disc>`)
  # — `spawn_from_template_content/4`'s URI builder is given a fully-
  # formed `instance_uri` by us (the action body's flavor-prepending
  # is bypassed; we feed the URI verbatim).
  defp spawn_orchestrator_via_template_content(
         %URI{} = candidate_uri,
         %URI{} = orch_template_uri,
         instance_name,
         %URI{} = workspace_uri,
         %URI{} = owner_uri
       )
       when is_binary(instance_name) do
    with {:ok, content} <- read_orchestrator_template_content(orch_template_uri),
         {:ok, result} <-
           Ezagent.Entity.Agent.spawn_from_template_content(
             content,
             candidate_uri,
             owner_uri,
             workspace_uri,
             Ezagent.Entity.Session.orchestrator_spawn_template_opts(owner_uri, orch_template_uri)
           ) do
      # codex PR #408 review CRIT — return `candidate_uri` (URI.new!'d
      # form) as the canonical orchestrator URI, NOT `result.workers`'s
      # element (which is URI.parse'd by the cc Template Class — the
      # two are STRUCTURALLY different per `URI.parse` adding an
      # `authority` field that `URI.new!` omits, and downstream
      # callers/tests pinned against the URI.new! shape `spawn_fresh/4`
      # used pre-fix).
      #
      # 2026-05-31 codex-review Q4 — surface the raw `fresh?` flag so the
      # caller (`ensure_orchestrator/3` → `finalize_spawned_orchestrator/5`)
      # can re-verify ownership and establish lineage/bind on the adopt
      # path (`fresh? == false`). The 5-tuple is internal to this module.
      fresh? = Map.get(result, :fresh?, false) == true
      outcome = if fresh?, do: :created, else: :already_present

      degraded_meta =
        Map.take(result, [
          :role_degraded,
          :role_degraded_reason,
          # #17 (c) — OAuth credential-staleness reminder, surfaced to the owner.
          :credential_stale,
          :credential_stale_reason
        ])

      {:ok, candidate_uri, outcome, fresh?, degraded_meta}
    end
  end

  # Read the cc-orchestrator AgentTemplate's `:template` slice content
  # via `:sys.get_state` — same pattern `CcOrchestratorSeed.seed_status/0`
  # uses. The AgentTemplate Kind must be alive (the boot seed runs
  # before any `ensure_orchestrator` call); a missing Kind returns
  # `{:error, :orchestrator_template_not_alive}` so the operator can see
  # the boot-order issue rather than a downstream confusing error.
  defp read_orchestrator_template_content(%URI{} = orch_template_uri) do
    case Ezagent.KindRegistry.lookup(orch_template_uri) do
      :error ->
        {:error, {:orchestrator_template_not_alive, orch_template_uri}}

      {:ok, pid} ->
        case safe_get_template_content(pid) do
          %{} = content when map_size(content) > 0 ->
            {:ok, content}

          _ ->
            {:error, {:orchestrator_template_not_populated, orch_template_uri}}
        end
    end
  end

  # `:sys.get_state` on a Kind.Server returns `%{state: %{template: <slice>}}`.
  # Wrapped to swallow timeouts / restarts (the AgentTemplate Kind is
  # snapshot-persisted, so a brief restart races are normal) — returns
  # `%{}` on any failure so the caller surfaces
  # `:orchestrator_template_not_populated`.
  #
  # Lifecycle migration (SPEC 2026-05-29): `Ezagent.ActionSet.Template`
  # now uses `use Ezagent.Lifecycle`, so the `:template` slice is the
  # two-container `%{state: %{content: ...}, transients: %{}}` shape (the
  # framework persists only `:state`; `:content` is fully persistent).
  # This raw `:sys.get_state` read therefore matches the two-container
  # form FIRST, then falls back to the legacy flat `%{content: ...}` form
  # (a pre-migration snapshot or a non-Lifecycle Behavior). Reading the
  # raw process state (vs `Kind.get_slice/2`'s normalized view) is
  # deliberate here — it swallows restart-race timeouts the comment above
  # describes without a blocking `GenServer.call`.
  defp safe_get_template_content(pid) do
    case :sys.get_state(pid, 500) do
      %{state: %{template: %{state: %{content: content}}}} when is_map(content) -> content
      %{state: %{template: %{content: content}}} when is_map(content) -> content
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  # 2-way classification on a LIVE candidate (2026-05-31
  # orchestrator-startup-atomicity §4 step 5):
  #   :owned — BOTH lineage + workspace POSITIVELY match us
  #   {:foreign, ev} — anything else on a live URI (a positive mismatch
  #     OR a missing lineage/workspace binding under a URI someone else
  #     already registered). With adoption gone + the atomic create
  #     committing lineage+bind inside the spawn, there is no "spawn
  #     inflight" limbo to wait out — a live-but-unmatched URI is a real
  #     foreign claim, surfaced fail-loud so the caller rolls back.
  #   :not_live — KindRegistry lookup missed (we are clear to spawn)
  defp check_orchestrator(%URI{} = uri, %URI{} = owner_uri, %URI{} = workspace_uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        :not_live

      {:ok, _pid} ->
        lineage_state =
          case Ezagent.AgentLineage.lookup(uri) do
            {:ok, %URI{} = principal} ->
              if URI.to_string(principal) == URI.to_string(owner_uri),
                do: :match,
                else: {:mismatch, URI.to_string(principal)}

            :error ->
              :absent
          end

        workspace_state =
          case Ezagent.WorkspaceRegistry.lookup(uri) do
            {:ok, %URI{} = bound} ->
              if URI.to_string(bound) == URI.to_string(workspace_uri),
                do: :match,
                else: {:mismatch, URI.to_string(bound)}

            :error ->
              :absent
          end

        if lineage_state == :match and workspace_state == :match do
          {:owned, uri}
        else
          # Live URI that does not positively match us — a foreign claim
          # (mismatch) OR an incomplete binding under an already-registered
          # URI. No retry/limbo (adoption + Generator removed); fail-loud.
          {:foreign, %{lineage: lineage_state, workspace: workspace_state}}
        end
    end
  end

  @doc """
  Read the stored orchestrator agent URI for a session.

  The orchestrator is a session attribute stored in the Chat working-copy
  slice and resolved through `Ezagent.UriQuery`; callers must not infer it
  from URI segment names.
  """
  @spec orchestrator_uri(URI.t()) :: {:ok, URI.t()} | :none | {:error, term()}
  def orchestrator_uri(%URI{} = session_uri) do
    Ezagent.UriQuery.resolve(:orchestrator, session_uri)
  end

  @doc """
  Read the stored orchestrator instance name for a session.
  """
  @spec orchestrator_instance_name(URI.t()) :: {:ok, String.t()} | :none | {:error, term()}
  def orchestrator_instance_name(%URI{} = session_uri) do
    case orchestrator_uri(session_uri) do
      {:ok, %URI{} = orchestrator_uri} -> Ezagent.URI.name(orchestrator_uri)
      :none -> :none
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec planned_orchestrator_uri(URI.t(), URI.t()) :: URI.t()
  def planned_orchestrator_uri(%URI{} = session_uri, %URI{} = workspace_uri) do
    build_orchestrator_uri_for_create(session_uri, workspace_uri)
  end

  defp build_orchestrator_uri_for_create(%URI{} = session_uri, %URI{} = workspace_uri) do
    instance_name = build_orchestrator_instance_name_for_create(session_uri)

    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

    Ezagent.URI.agent(workspace_name, instance_name)
  end

  defp build_orchestrator_instance_name_for_create(%URI{} = session_uri) do
    # Preserve the historical "cc_orchestrator-<session_name>" shape.
    "cc_orchestrator-#{session_discriminator(session_uri)}"
  end

  @doc """
  Ownership predicate — a worker is "owned by us" iff its `AgentLineage`
  row points at our orchestrator AND its `WorkspaceRegistry` binding
  points at our workspace. URI comparison is canonical-string (registries
  store parsed structs derived from strings).

  Used by the orchestrator tools (`Ezagent.Orchestrator.Tools`) to gate
  worker adoption. (The Generator slot-reconcile call sites were deleted
  in the 2026-05-31 orchestrator-startup-atomicity pass.)
  """
  @spec worker_already_owned_by_us?(URI.t(), URI.t(), URI.t()) :: boolean()
  def worker_already_owned_by_us?(%URI{} = worker_uri, %URI{} = orch_uri, %URI{} = ws_uri) do
    case Ezagent.KindRegistry.lookup(worker_uri) do
      {:ok, _pid} ->
        lineage_ok? =
          case Ezagent.AgentLineage.lookup(worker_uri) do
            {:ok, %URI{} = sb} -> URI.to_string(sb) == URI.to_string(orch_uri)
            :error -> false
          end

        ws_ok? =
          case Ezagent.WorkspaceRegistry.lookup(worker_uri) do
            {:ok, %URI{} = bw} -> URI.to_string(bw) == URI.to_string(ws_uri)
            :error -> false
          end

        lineage_ok? and ws_ok?

      :error ->
        false
    end
  end

  @doc """
  Read the durable `template_working_copy` map from a live Session's
  `:chat` slice (or the default when the session isn't live).

  2026-05-31 orchestrator-startup-atomicity §4 step 4 — kept + made
  public so the atomic `EzagentDomainInstanceMessage.SessionCreator.create_session/3` can merge
  the OTU fields into the existing working copy before writing it back.
  """
  @spec read_template_working_copy(URI.t()) :: map()
  def read_template_working_copy(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        # Lifecycle migration (SPEC 2026-05-29 §2.3C): the Chat slice is now
        # two-container; the persistent `template_working_copy` lives under
        # its `:state`. The outer `Map.get(:state, ...)` reaches the
        # per-Kind slice store; the inner one unwraps the Chat two-container
        # (falling through for a not-yet-converted flat slice).
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Ezagent.ActionSet.Session.state_slice(), %{})

        chat_persistent = Map.get(chat_slice, :state, chat_slice)

        Ezagent.ActionSet.Session.template_working_copy(chat_persistent)

      :error ->
        Ezagent.ActionSet.Session.default_template_working_copy()
    end
  end

  @doc """
  Read the live Session's `:chat` member URIs as a list.

  2026-05-31 orchestrator-startup-atomicity §4 step 2 (codex-review Q2)
  — used by the completeness check for an already-existing session: an
  owner that is NOT a chat member is one symptom of a half-create that
  crashed before the step-8 member join. Reads the same two-container
  `:chat` slice `read_template_working_copy/1` does (the persistent
  `:members` map lives under `:state`). Returns `[]` when the Session
  Kind is not live (it cannot have members if it isn't running).
  """
  @spec session_member_uris(URI.t()) :: [URI.t()]
  def session_member_uris(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Ezagent.ActionSet.Session.state_slice(), %{})

        chat_persistent = Map.get(chat_slice, :state, chat_slice)

        chat_persistent
        |> Map.get(:members, %{})
        |> Map.keys()

      :error ->
        []
    end
  catch
    :exit, _ -> []
  end

  @doc """
  The live `:chat` slice's session-scoped legend registry (`name => entry`).

  team-routing-unification §3.6 (PR-6) — the legend-aware mention parsers
  (Feishu / LiveView) read this to resolve a `@legend` symbolic handle to its
  bound rule-set entry BEFORE the URI-mention path. Reads the same
  two-container `:chat` slice as `session_member_uris/1`; returns `%{}` when the
  Session Kind is not live (no legends if it isn't running).
  """
  @spec session_legends(URI.t()) :: map()
  def session_legends(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(Ezagent.ActionSet.Session.state_slice(), %{})

        chat_persistent = Map.get(chat_slice, :state, chat_slice)
        Ezagent.ActionSet.Session.legends_of(chat_persistent)

      :error ->
        %{}
    end
  catch
    :exit, _ -> %{}
  end

  # ─────────────────────────────────────────────────────────────────────
  @doc "Grant the orchestrator its scope-bounded delegation caps (RFC #402 caps #1–#4) at session create. Delegates to `Orchestrator.Caps`; idempotent (skips logically-equal re-grants)."
  defdelegate grant_orchestrator_scoped_caps(orchestrator_uri, session_uri, owner_uri),
    to: Ezagent.Entity.Session.Orchestrator.Caps

  @doc "Revoke exactly the scoped-cap set `grant_orchestrator_scoped_caps/3` adds — the rollback inverse on a failed create. Delegates to `Orchestrator.Caps`; best-effort + idempotent."
  defdelegate revoke_orchestrator_scoped_caps(
                orchestrator_uri,
                session_uri,
                owner_uri,
                workspace_uri
              ),
              to: Ezagent.Entity.Session.Orchestrator.Caps

  @doc "Whether two caps are logically equal ignoring volatile metadata (e.g. `granted_at`) — the idempotency comparator used by the scoped-cap grant/revoke. Delegates to `Orchestrator.Caps`."
  defdelegate cap_equal_ignoring_metadata?(left, right),
    to: Ezagent.Entity.Session.Orchestrator.Caps

  # register_orchestrator_mcp_context  (2026-05-31 §4 step 7)
  # ─────────────────────────────────────────────────────────────────────

  @doc """
  Register the orchestrator's MCP context (cache-fill).

  2026-05-31 orchestrator-startup-atomicity §4 step 7 — made public so
  the atomic `EzagentDomainInstanceMessage.SessionCreator.create_session/3` chokepoint can call it
  directly. The lazy `rebuild_from_durable` (now able to read OTU via
  the A+C2 unwrap fix) also reconstructs it on JOIN.
  """
  @spec register_orchestrator_mcp_context(URI.t(), URI.t(), URI.t(), URI.t(), URI.t()) ::
          :ok | {:error, term()}
  def register_orchestrator_mcp_context(
        %URI{} = orchestrator_uri,
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = owner_uri,
        %URI{} = parent_template_uri
      ) do
    Ezagent.Session.OrchestratorReadinessPort.register_context(orchestrator_uri,
      session_uri: session_uri,
      workspace_uri: workspace_uri,
      owner_uri: owner_uri,
      parent_template_uri: parent_template_uri
    )
  end

  @doc "Ensure the SessionTemplate Kind at `template_uri` is materialized/alive before it is read or instantiated. Delegates to `Ezagent.Entity.Session`."
  defdelegate ensure_template_alive(template_uri), to: Ezagent.Entity.Session

  @doc """
  Read a SessionTemplate's `:template` content slice via the
  `template.read` dispatch (under the `system://template-materialize`
  principal). Returns `{:ok, content}` | `{:error, reason}`.

  2026-05-31 orchestrator-startup-atomicity §4 — kept + made public so
  the atomic `EzagentDomainInstanceMessage.SessionCreator.create_session/3` can read the template's
  `orchestrator_template_uri` to materialize the session working copy.
  """
  @spec read_template_content(URI.t()) :: {:ok, map()} | {:error, term()}
  def read_template_content(%URI{} = session_template_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_template_uri)}?action=template.read")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           # #154 — `system://template-materialize` ELIMINATED. Reading template
           # content during materialization is system-mediated → runs under the
           # genesis admin entity with an INLINE narrow `template.read` cap
           # (granted_by admin; #533 refines). behavior: :any avoids a cross-app
           # `Behavior.Template` literal.
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps:
               MapSet.new([
                 %Ezagent.Capability{
                   Ezagent.Capability.cap(
                     :any,
                     :any,
                     :read,
                     Ezagent.URI.instance(target),
                     Ezagent.Capability.workspace_of(target)
                   )
                   | granted_by: Ezagent.Entity.User.admin_uri(),
                     granted_at: DateTime.utc_now()
                 }
               ]),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{content: content}} when is_map(content) -> {:ok, content}
      {:ok, %{content: nil}} -> {:error, :session_template_not_populated}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_template_read_result, other}}
    end
  end

  # session discriminator: the session URI's name segment.
  defp session_discriminator(%URI{} = session_uri) do
    case Ezagent.URI.name(session_uri) do
      {:ok, name} -> name
      :error -> session_uri.host || "session"
    end
  end

  # ─────────────────────────────────────────────────────────────────────
end
