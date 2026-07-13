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
  `apply_orchestrator_recipe_bootstrap/2` therefore never ran on the
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
    lock_id = {{:ezagent_domain_session, :create_session, URI.to_string(session_uri)}, self()}

    try do
      true = :global.set_lock(lock_id, [node()])
      ensure_orchestrator_compat(session_uri, workspace_uri, owner_uri)
    after
      _ = :global.del_lock(lock_id, [node()])
    end
  end

  defp ensure_orchestrator_compat(
         %URI{} = session_uri,
         %URI{} = workspace_uri,
         %URI{} = owner_uri
       ) do
    case orchestrator_member_uri(session_uri) do
      %URI{} = orchestrator_uri ->
        with {:ok, binding} <-
               EzagentDomainInstanceMessage.SessionCreator.Materializer.ensure_orchestrator_binding(
                 session_uri,
                 orchestrator_uri
               ),
             :ok <-
               register_orchestrator_mcp_context(
                 orchestrator_uri,
                 session_uri,
                 workspace_uri,
                 owner_uri,
                 compat_parent_template_uri(session_uri),
                 binding.epoch
               ),
             :ok <-
               grant_orchestrator_scoped_caps(orchestrator_uri, session_uri, owner_uri) do
          {:ok, orchestrator_uri, :already_present}
        end

      nil ->
        candidate_uri = build_orchestrator_uri_for_create(session_uri, workspace_uri)

        case check_orchestrator(candidate_uri, owner_uri, workspace_uri) do
          {:owned, ^candidate_uri} ->
            adopt_legacy_orchestrator_member(
              session_uri,
              workspace_uri,
              owner_uri,
              candidate_uri
            )

          :not_live ->
            materialize_orchestrator_definition(session_uri, workspace_uri, owner_uri)

          {:foreign, evidence} ->
            {:error, {:orchestrator_foreign, candidate_uri, evidence}}
        end
    end
  end

  defp adopt_legacy_orchestrator_member(session_uri, workspace_uri, owner_uri, candidate_uri) do
    with :ok <- install_orchestrator_definition(session_uri, workspace_uri, owner_uri),
         {:ok, _summary} <-
           EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents.materialize_definition_agents(
             session_uri,
             workspace_uri,
             owner_uri,
             [
               %{
                 recipe: "orchestrator",
                 role_name: "orchestrator",
                 flavor: "cc",
                 install_mode: :reuse,
                 reuse_agent_uri: candidate_uri
               }
             ]
           ),
         %URI{} = orchestrator_uri <- orchestrator_member_uri(session_uri) do
      {:ok, orchestrator_uri, :already_present}
    else
      nil -> {:error, {:orchestrator_adoption_failed, :member_not_joined}}
      {:error, _} = error -> error
      other -> {:error, {:orchestrator_adoption_failed, other}}
    end
  end

  defp materialize_orchestrator_definition(session_uri, workspace_uri, owner_uri) do
    with :ok <- install_orchestrator_definition(session_uri, workspace_uri, owner_uri),
         :ok <-
           EzagentDomainInstanceMessage.SessionCreator.materialize_template_team(
             session_uri,
             workspace_uri,
             owner_uri,
             %{installs: ["orchestrator"]}
           ),
         %URI{} = orchestrator_uri <- orchestrator_member_uri(session_uri) do
      {:ok, orchestrator_uri, :created}
    else
      nil -> {:error, {:orchestrator_materialize_failed, :member_not_joined}}
      {:error, _} = error -> error
      other -> {:error, {:orchestrator_materialize_failed, other}}
    end
  end

  defp install_orchestrator_definition(session_uri, workspace_uri, owner_uri) do
    Ezagent.Socialware.Installation.install_template_installs(
      session_uri,
      workspace_uri,
      %{installs: ["orchestrator"]},
      owner_uri
    )
  end

  defp orchestrator_member_uri(%URI{} = session_uri) do
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
        |> Ezagent.ActionSet.Session.Members.role_name_to_uri("orchestrator")

      :error ->
        nil
    end
  catch
    :exit, _ -> nil
  end

  defp compat_parent_template_uri(%URI{} = session_uri) do
    case read_template_working_copy(session_uri) do
      %{session_template_uri: %URI{} = uri} -> uri
      %{"session_template_uri" => %URI{} = uri} -> uri
      %{session_template_uri: uri} when is_binary(uri) and uri != "" -> Ezagent.URI.new!(uri)
      %{"session_template_uri" => uri} when is_binary(uri) and uri != "" -> Ezagent.URI.new!(uri)
      _ -> Ezagent.URI.template(:system, :session, "default")
    end
  rescue
    _ -> Ezagent.URI.template(:system, :session, "default")
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
  Member URIs extracted from a DECODED durable snapshot state map (the
  `Ezagent.Ecto.KindSnapshot.decode_state/1` result) — the cold-Kind
  counterpart of `session_member_uris/1`, reading the SAME two-container
  session slice shape (`:members` under the slice's persistent `:state`)
  WITHOUT spawning the Kind.

  2026-07-08 cold-boot listing fix — sessions are NOT auto-respawned on
  boot, so after a restart `session_member_uris/1` returns `[]` for every
  durably-persisted session and the membership-filtered workspace listing
  (#1217) wrongly excluded members. The listing evaluates cold membership
  from the snapshot via this function; it stays read-only (no
  `ensure_live` from a listing).

  Kept next to `session_member_uris/1` on purpose: this module is the
  single source of truth for the session-slice unwrap. Fail-closed — a
  missing / malformed slice yields `[]` (never a broader member set).

  ## Slice key (codex #1257 MED)

  Reads via the CANONICAL `Ezagent.ActionSet.Session.state_slice()` key
  (auto-derived `:session` since the 2026-06-12 chat→session rename) —
  never a hardcoded key — i.e. exactly the shape
  `Ezagent.Session.SliceMigration` serves post-cutover. Legacy
  `:chat`-keyed rows are deliberately NOT dual-read: the rename was a
  NO-back-compat ordered cutover (`SliceMigration` moduledoc "Deploy
  ordering") and the live restore path likewise defaults such a slice to
  empty and prunes it (`Snapshot.prune_orphan_slices/2`) — a listing that
  showed members from an unmigrated row would advertise state that
  opening the session destroys. Unmigrated rows are an operator error
  surfaced by `mix ezagent.session.migrate_slice --gate`; here they are
  fail-closed (`[]`).
  """
  @spec member_uris_from_snapshot_state(term()) :: [URI.t()]
  def member_uris_from_snapshot_state(state) when is_map(state) do
    chat_slice = Map.get(state, Ezagent.ActionSet.Session.state_slice())

    chat_persistent =
      case chat_slice do
        %{} = slice ->
          case Map.get(slice, :state, slice) do
            %{} = persistent -> persistent
            _ -> %{}
          end

        _ ->
          %{}
      end

    case Map.get(chat_persistent, :members, %{}) do
      members when is_map(members) ->
        members |> Map.keys() |> Enum.filter(&match?(%URI{}, &1))

      _ ->
        []
    end
  end

  def member_uris_from_snapshot_state(_), do: []

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
  Register the orchestrator's MCP context and start its session-owned executor.

  2026-05-31 orchestrator-startup-atomicity §4 step 7 — made public so
  the atomic `EzagentDomainInstanceMessage.SessionCreator.create_session/3` chokepoint can call it
  directly. The lazy `rebuild_from_durable` reconstructs the same context from
  the durable role/member binding on JOIN after a restart.
  """
  @spec register_orchestrator_mcp_context(
          URI.t(),
          URI.t(),
          URI.t(),
          URI.t(),
          URI.t(),
          String.t()
        ) ::
          :ok | {:error, term()}
  def register_orchestrator_mcp_context(
        %URI{} = orchestrator_uri,
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = owner_uri,
        %URI{} = parent_template_uri,
        binding_epoch
      ) do
    with :ok <-
           Ezagent.Session.OrchestratorContextPort.register_context(orchestrator_uri,
             session_uri: session_uri,
             workspace_uri: workspace_uri,
             owner_uri: owner_uri,
             parent_template_uri: parent_template_uri,
             binding_epoch: binding_epoch
           ),
         {:ok, _pid} <-
           Ezagent.Session.SessionManager.ensure_started(
             orchestrator_uri: orchestrator_uri,
             session_uri: session_uri,
             workspace_uri: workspace_uri,
             owner_uri: owner_uri,
             parent_template_uri: parent_template_uri
           ) do
      :ok
    end
  end

  @doc "Ensure the SessionTemplate Kind at `template_uri` is materialized/alive before it is read or instantiated. Delegates to `Ezagent.Entity.Session`."
  defdelegate ensure_template_alive(template_uri), to: Ezagent.Entity.Session

  @doc """
  Read a SessionTemplate's `:template` content slice via the
  `template.read` dispatch (under the `system://template-materialize`
  principal). Returns `{:ok, content}` | `{:error, reason}`.

  2026-05-31 orchestrator-startup-atomicity §4 — kept + made public so
  the session creator can read SessionTemplate definition data. A definition's
  `orchestrator_template_uri` remains valid here; it is not a runtime binding.
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
