defmodule EzagentDomainInstanceMessage.SessionCreator.Materializer do
  @moduledoc false

  alias Ezagent.Invocation
  alias Ezagent.Entity.Session

  # Write `orchestrator_template_uri` + `session_template_uri` to the
  # session's durable working copy before the orchestrator can join.
  def materialize_orchestrator_working_copy(
        %URI{} = session_uri,
        %URI{} = session_template_uri,
        orchestrator_template_uri
      ) do
    prior = Session.read_template_working_copy(session_uri)

    working_copy =
      prior
      |> Map.put(:orchestrator_template_uri, orchestrator_template_uri)
      |> Map.put(:session_template_uri, session_template_uri)

    case Ezagent.Behavior.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  def store_session_orchestrator_uri(%URI{} = session_uri, %URI{} = orchestrator_uri) do
    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(:orchestrator_uri, orchestrator_uri)

    case Ezagent.Behavior.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
  end

  @doc """
  Pre-persist the deterministic *planned* orchestrator URI into the session's
  durable working copy BEFORE the step-5 orchestrator-readiness gate runs.

  The live orchestrator's MCP bridge join self-registers by lazily rebuilding
  its context from this durable binding (`Ezagent.Orchestrator.McpServer`
  read-through cache). The binding was previously only written at step 6
  (`store_session_orchestrator_uri/2`), which runs AFTER `ensure_orchestrator`
  — but `ensure_orchestrator`'s readiness gate POLLS for that very join. So in
  production (live claude) every join was rejected `:orchestrator_not_registered`
  for the whole 90s gate → timeout → full create rollback, blocking the
  orchestrator + admin UI on a fresh stack. Deterministic tests masked it
  (test-mode signals readiness without a live MCP join). See
  `docs/notes/2026-06-15-live-orchestrator-mcp-registration-bug.md`.

  Applied ONLY on the fresh-create path (`new_session?: true`), where a fresh
  session has no `:orchestrator_uri` yet and EVERY downstream failure rolls the
  whole session back (`rollback_session/3` deletes the snapshot — atomicity Q1),
  so a failed gate cannot leave a stale pre-stored binding behind. The
  repair/restart path is NOT pre-stored here — its existing binding (== planned,
  preserved by `materialize_orchestrator_working_copy/3`) already resolves the
  live join; the narrower nil-orchestrator repair case needs a separate
  readiness-vs-binding separation and is tracked in docs/futures/todo.md (the
  `:orchestrator_uri` field doubles as the `session_complete?/4` readiness proof,
  so pre-storing it on the keep-the-live-session repair path could read as
  premature readiness — codex review).
  """
  @spec prestore_planned_orchestrator_uri(URI.t(), URI.t()) :: :ok | {:error, term()}
  def prestore_planned_orchestrator_uri(%URI{} = session_uri, %URI{} = workspace_uri) do
    planned = Session.planned_orchestrator_uri(session_uri, workspace_uri)
    store_session_orchestrator_uri(session_uri, planned)
  end

  def grant_owner_orchestrator_admin_cap(
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

    current =
      EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(owner_uri)

    if Enum.any?(current, &Session.cap_equal_ignoring_metadata?(&1, want)) do
      :ok
    else
      # Grant chokepoint (SPEC 2026-06-17 §4 PR-2, site #6). The cap is
      # `session/OrchestratorAdmin/:restart/<session_uri>` — concrete
      # instance + concrete action, so `IdentityAdmin.rule_cap_bounded?/1`
      # is true → authorized via the `{:rule, …}` branch (Decision #154).
      # `template-materialize` is no longer the authorizer; the configurer
      # of the orchestrator-template-materialization rule is the session
      # OWNER (also the entity `granted_by`).
      result =
        Ezagent.Identity.Grant.grant_cap(
          owner_uri,
          want,
          {:rule, :template_materialize, owner_uri}
        )

      case result do
        :ok -> :ok
        {:error, reason} -> {:error, {:orchestrator_admin_cap_grant_failed, reason}}
      end
    end
  end

  @doc """
  Grant the session owner a `Behavior.Manage :any` cap OVER the orchestrator
  agent (SPEC 2026-06-16 §5, codex P2 prerequisite, Decision #88).

  The orchestrator spawn path (`Session.ensure_orchestrator` →
  `Agent.spawn_from_template_content/5`) does NOT route through `CreatorGrant`
  / `Workspace.grant_creator_manage_cap/4`, so the owner is NOT a manager of
  the orchestrator and could not equip it via the new manager-delegated
  `grant_cap` path. This wires the missing Manage cap, making the owner the
  orchestrator's manager — the same `cap(:agent, Manage, :any, orchestrator_uri,
  ws)` shape every other created Kind grants its creator at create.

  Delegates to `Ezagent.Workspace.grant_creator_manage_cap/4`, which is
  idempotent (skips a logically-equal re-grant) and dispatches under the
  closed bootstrap system principal because `Manage :any` is a
  wildcard-action cap whose target Behavior has no data owner (Identity's
  grant boundary correctly requires admin authority for that shape). The
  issued cap still records `granted_by: owner_uri`.
  """
  @spec grant_owner_orchestrator_manage_cap(URI.t(), URI.t()) :: :ok | {:error, term()}
  def grant_owner_orchestrator_manage_cap(%URI{} = orchestrator_uri, %URI{} = owner_uri) do
    workspace_uri =
      case Ezagent.WorkspaceRegistry.lookup(orchestrator_uri) do
        {:ok, %URI{} = ws} ->
          ws

        :error ->
          raise "orchestrator #{URI.to_string(orchestrator_uri)} has no workspace binding " <>
                  "— cannot derive workspace_uri for the owner Manage cap"
      end

    Ezagent.Workspace.grant_creator_manage_cap(
      :agent,
      orchestrator_uri,
      workspace_uri,
      owner_uri
    )
  end

  def join_session_members(%URI{} = session_uri, members) when is_list(members) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    Enum.reduce_while(members, :ok, fn %URI{} = member_uri, :ok ->
      _ = EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(member_uri)

      admin_uri = Ezagent.Entity.User.admin_uri()

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{member: member_uri},
          # #154 — `system://session-internal` ELIMINATED. Joining a configured
          # member during session MATERIALIZATION is system-mediated → runs under
          # the genesis admin entity with an inline `session.join` cap (granted_by
          # admin; #533 refines to per-creator/owner). Same play as
          # template-materialize.
          ctx: %{
            caller: admin_uri,
            caps:
              MapSet.new([
                %Ezagent.Capability{
                  Ezagent.Capability.cap(
                    :session,
                    :any,
                    :join,
                    Ezagent.URI.instance(session_uri),
                    Ezagent.Capability.workspace_of(session_uri)
                  )
                  | granted_by: admin_uri,
                    granted_at: DateTime.utc_now()
                }
              ]),
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
end
