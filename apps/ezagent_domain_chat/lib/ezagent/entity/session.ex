defmodule Ezagent.Entity.Session do
  @moduledoc """
  Session Kind — the "room" in Phase 2's chat routing model.

  A Session is the entity that holds a set of member URIs and routes
  outbound chat messages to them. Per Decision #61 + P2-D2 K-path:
  Session handles `:send / :join / :leave` actions; the member-side
  `:receive` action runs on the recipient Kind (User / Agent).

  Phase 2 spawns exactly one default instance — `session://default/default/main` —
  at `EzagentDomainChat.Application.start/2`. Multi-Session support is
  intentionally out of scope (Phase 3+).

  ## Persistence: {:snapshot, :on_change} — session membership survives restart

  Phase 2 originally used `:ephemeral` — members / monitors /
  last_seen were rebuilt at each boot from PubSub re-announcements
  and admin User re-join in `handle_continue(:announce_ready)`.
  Historical message stream was persisted (via `Ezagent.MessageStore`);
  only in-flight membership was ephemeral.

  **Allen V1 acceptance 2026-05-22**: adding an agent (cc_demo) to a
  session at runtime, then a phx restart, wiped it from `members`.
  Root cause — `persistence/0` was still `:ephemeral`, so the Session
  Kind's in-memory Chat slice (members map, last_seen, the
  orchestrator's working-copy) was never snapshotted; any restart lost
  every runtime mutation. ("Phase 7 PR 44/46" was supposed to flip
  this for orchestrator working-copy durability — SPEC §7-3 — but the
  flip never landed; only the moduledoc was updated to claim it had.)

  `persistence/0` is now `{:snapshot, :on_change}` — the same mode the
  `Ezagent.Entity.User` Kind already uses. After every Chat-slice
  mutation (`:send` / `:join` / `:leave` / `:DOWN`), `Ezagent.Kind.Server`
  writes the slice to `kind_snapshots`; on (re)spawn,
  `Ezagent.Kind.Snapshot.load_or_init/3` rehydrates it. Membership,
  last_seen, and the orchestrator working-copy now survive an unclean
  crash, not just a graceful shutdown.

  ### Slice serialization

  The Chat slice (`Ezagent.Behavior.Chat`) holds `members`
  (`%{URI => %{online: bool}}`), `monitors` (`%{reference => URI}`),
  and `last_seen` (`%{URI => DateTime}`). `URI` structs, `DateTime`,
  booleans, and `reference()` are all serializable via
  `:erlang.term_to_binary/1` and decode safely under the `[:safe]`
  flag — no pids, no funs, no anonymous closures. `monitors` refs are
  stale across a restart (a `reference()` is only meaningful for a
  live monitor), but that is harmless: a stale ref simply never
  matches an incoming `:DOWN`, and a member rejoin via `chat.join`
  re-monitors the live pid. `last_seen` reflects history, not live
  state. Members get re-validated when their owning Kind comes up.

  ### WorkspaceRegistry rebind (invariant 4)

  When a Session Kind rehydrates after a restart, its
  `WorkspaceRegistry` binding must be re-established so workspace-scoped
  routing rules still fire. Per Phase 9 PR-7 the workspace lives in the
  3-segment session URI (`session://<template>/<workspace>/<name>`), so
  `WorkspaceRegistry` is a consistency cache and the binding is derived
  structurally from the URI. The chat plugin's `session` spawn fn
  (`EzagentDomainChat.Application.register_spawn_fns/0`) calls
  `WorkspaceRegistry.bind/2` on every spawn — covering the lazy
  demand-spawn rehydrate path as well as `EzagentDomainChat.create_session/2`.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :session

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Chat]

  # Allen V1 acceptance 2026-05-22 — session membership + chat config
  # must survive a phx restart (even an unclean crash, hence :on_change
  # not :on_terminate). The Chat slice is fully serializable; see the
  # moduledoc "Slice serialization" section. Same persistence mode the
  # User Kind already uses.
  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): Session Kinds live under the
  # chat domain's SessionSupervisor. `Ezagent.Kind.spawn/2` reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainChat.SessionSupervisor

  @doc """
  URI of the default Session instance spawned at boot.

  SPEC v3 §3.6 (Phase 9 PR-7) — sessions are 3-segment:
  `session://<template>/<workspace>/<name>`. The default session is
  the canonical entry point and lives in `workspace://default` under
  the `default` template name.
  """
  @spec default_uri() :: URI.t()
  def default_uri, do: URI.new!("session://default/default/main")

  @doc """
  Phase 7 PR 41 — the **Generator**: instantiate a Session from a
  SessionTemplate.

  Per SPEC D7-2 + Allen 2026-05-18 round 2: "创建一个新 session(自带
  orchestrator)的一段程序是 generator". Not an agent — just the spawn
  program. Each new session gets its own orchestrator instance baked in.

  ## Args

  - `session_template_uri` — `template://session/<name>@<version_hash>` or
    `template://session/<name>:<tag>` (resolved via template_tags
    registry in future; PR 41 accepts hash form only)
  - `owner_uri` — `%URI{}` of the human / principal triggering the
    instantiation. Becomes `granted_by` for orchestrator spawn (so
    orchestrator's `{:spawned_by, owner_uri}` cap shapes work via
    AgentLineage from PR 40).

  ## Return

  `{:ok, %{session_uri: URI.t(), orchestrator_uri: URI.t()}}` on success,
  `{:error, reason}` on lookup / spawn / lineage failures.

  ## PR 41 minimal scope

  Spawns ONLY the orchestrator (not the agent_slots workers). Per
  Allen's design + SPEC §7-3 §"Orchestrator" section: the orchestrator
  is the team-builder, and its tools (PR 46) populate the worker
  agent_slots via dispatch. PR 41 ships the Generator's spawn-the-
  orchestrator path; PR 46 ships the orchestrator-spawns-workers path.

  Routing rule installation + working-copy slice initialization + full
  agent_slots iteration are deferred to PR 46.

  ## CapBAC gate

  Generator is NOT a dispatched Behavior action (it's a public function
  callable from LV / CLI / programmatic). Cap check happens at the
  caller's surface — LV checks `owner_uri` has `template:instantiate`
  cap on the SessionTemplate URI before invoking. PR 41 ships the
  function; the LV `template:instantiate` cap check lands when the LV
  "instantiate session from template" button lands (likely PR 46 era).

  Conservative interim: callers MUST verify owner_uri has the
  necessary caps before invoking; Generator trusts the caller.
  """
  @spec spawn_from_template(URI.t(), URI.t()) ::
          {:ok, %{session_uri: URI.t(), orchestrator_uri: URI.t()}} | {:error, term()}
  def spawn_from_template(%URI{} = session_template_uri, %URI{} = owner_uri) do
    with {:ok, _template_pid} <- ensure_template_alive(session_template_uri),
         {:ok, session_uri} <- spawn_fresh_session(),
         {:ok, workspace_uri} <- default_workspace_for_session(session_uri),
         :ok <- Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri),
         {:ok, orchestrator_uri} <-
           spawn_orchestrator(session_uri, workspace_uri, owner_uri),
         :ok <- grant_scoped_caps(orchestrator_uri, session_uri, owner_uri) do
      {:ok, %{session_uri: session_uri, orchestrator_uri: orchestrator_uri}}
    else
      err -> err
    end
  end

  defp ensure_template_alive(%URI{} = template_uri) do
    case Ezagent.KindRegistry.lookup(template_uri) do
      {:ok, pid} -> {:ok, pid}
      :error -> Ezagent.SpawnRegistry.spawn(template_uri)
    end
  end

  defp spawn_fresh_session do
    # SPEC v3 §3.6 (Phase 9 PR-7) — sessions are 3-segment:
    # session://<template>/<workspace>/<name>. The Generator path
    # builds `session://generic/default/gen-<unique>` so dispatch can
    # extract workspace structurally without a registry lookup.
    unique_suffix = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.default_workspace_uri()
    workspace_name = workspace_uri.host
    session_uri = URI.new!("session://generic/#{workspace_name}/gen-#{unique_suffix}")

    case Ezagent.SpawnRegistry.spawn(session_uri) do
      {:ok, _pid} -> {:ok, session_uri}
      err -> err
    end
  end

  defp default_workspace_for_session(_session_uri) do
    # Phase 8c PR-E (Allen 2026-05-20): canonical name is
    # `workspace://default` per `Ezagent.URI` docs. The earlier
    # `workspace://generated-sessions` name was a Phase 7 stop-gap.
    # Sessions that don't override via SessionTemplate's
    # `default_workspace_uri` field land here.
    Ezagent.WorkspaceRegistry.default_workspace_uri()
  end

  defp spawn_orchestrator(session_uri, workspace_uri, owner_uri) do
    # Spawn the cc-orchestrator (PR 45 seed) under a fresh instance
    # name keyed to this session for traceability. SPEC v3 §3.6 PR-7
    # — orchestrator template is workspace-scoped to `default`.
    template_uri = URI.parse("template://agent/default/cc-orchestrator")
    # session_uri.path = "/<workspace>/<name>" → use name as suffix
    session_name =
      case session_uri.path do
        "/" <> rest ->
          case String.split(rest, "/", parts: 2) do
            [_ws, name] -> name
            _ -> session_uri.host
          end

        _ ->
          session_uri.host
      end

    instance_name = "orchestrator-#{session_name}"

    Ezagent.Entity.Agent.spawn(template_uri, instance_name, workspace_uri, owner_uri)
  end

  # Phase 7 PR 47 — scope-bounded delegation per SPEC D7-3.
  #
  # After the orchestrator agent spawns, grant it two scope-tuple caps
  # so its authority is bounded to its session + to agents it spawns:
  #
  # 1. `{kind: :session, behavior: :any, instance: {:within_session, S}}`
  #    — orchestrator can dispatch on any URI inside its session S, but
  #    nothing outside S
  # 2. `{kind: :agent, behavior: :any, instance: {:spawned_by, orch}}`
  #    — orchestrator can dispatch on agents it spawned (via Agent.spawn/4
  #    recording lineage in Ezagent.AgentLineage), but not on agents
  #    spawned by other orchestrators or operators
  #
  # Both granted by the human owner who triggered Generator. Decision
  # #137 marker: this is the v1 scope-bounded-delegation baseline.
  defp grant_scoped_caps(orchestrator_uri, session_uri, owner_uri) do
    # Phase 9 PR-3 (SPEC v3 §4): scope the orchestrator's bounded
    # caps to the session's workspace. The session must already be
    # bound (invariant 4 — Workspace.Loader.invoke_template /
    # SessionTemplate spawn paths call WorkspaceRegistry.bind);
    # without a binding we let it crash rather than silently grant
    # a cross-workspace cap.
    session_workspace =
      case Ezagent.WorkspaceRegistry.lookup(session_uri) do
        {:ok, ws} ->
          ws

        :error ->
          raise "session #{URI.to_string(session_uri)} has no workspace binding " <>
                  "— cannot derive workspace_uri for orchestrator scope caps"
      end

    caps = [
      %Ezagent.Capability{
        kind: :session,
        behavior: :any,
        instance: {:within_session, session_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: DateTime.utc_now()
      },
      %Ezagent.Capability{
        kind: :agent,
        behavior: :any,
        instance: {:spawned_by, orchestrator_uri},
        workspace_uri: session_workspace,
        granted_by: owner_uri,
        granted_at: DateTime.utc_now()
      }
    ]

    target = URI.new!("#{URI.to_string(orchestrator_uri)}?action=identity.grant_cap")

    ctx = %{
      caller: owner_uri,
      caps: Ezagent.Entity.User.admin_caps(),
      reply: :ignore
    }

    results =
      Enum.map(caps, fn cap ->
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{cap: cap},
          ctx: ctx
        })
      end)

    case Enum.reject(results, &match?({:ok, _}, &1)) do
      [] -> :ok
      [err | _] -> {:error, {:scoped_cap_grant_failed, err}}
    end
  end
end
