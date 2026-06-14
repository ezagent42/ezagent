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

  The orchestrator URI is the deterministic identity of the session's
  orchestrator (`planned_orchestrator_uri/2`), and `ensure_orchestrator/3`
  spawns + gates exactly that planned URI; the live MCP join resolves only by an
  EXACT match against the stored working-copy `:orchestrator_uri`. So this
  ensures the durable binding equals the planned URI before the gate:

    * stored already EQUALS planned → `:skipped` (nothing to do);
    * stored is ABSENT or a MISMATCHED/stale URI → overwrite it with the planned
      URI so the joining (planned) orchestrator resolves — a repair of a session
      carrying a stale binding heals instead of timing out (codex review HIGH) —
      and return `{:stored, prior}` so the caller can RESTORE `prior` if the
      subsequent readiness/finalize fails on a path that keeps the live session
      (the repair path; the fresh-create path instead deletes the whole snapshot
      via `rollback_session/3`).
  """
  @spec prestore_planned_orchestrator_uri(URI.t(), URI.t()) ::
          {:stored, URI.t() | nil} | :skipped | {:error, term()}
  def prestore_planned_orchestrator_uri(%URI{} = session_uri, %URI{} = workspace_uri) do
    planned = Session.planned_orchestrator_uri(session_uri, workspace_uri)
    current = Map.get(Session.read_template_working_copy(session_uri), :orchestrator_uri)

    if is_struct(current, URI) and URI.to_string(current) == URI.to_string(planned) do
      :skipped
    else
      case store_session_orchestrator_uri(session_uri, planned) do
        :ok -> {:stored, current}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Restore the session's durable working-copy `:orchestrator_uri` to a prior
  value — the transactional compensation for a `prestore_planned_orchestrator_uri/2`
  that returned `{:stored, prior}` when the subsequent orchestrator readiness/
  finalize then FAILS on a path that keeps the live session (the repair path).

  `prior` is whatever was bound before the pre-store: a `%URI{}` (a pre-existing
  binding we overwrote — restored verbatim) or `nil`/absent (the key is removed).
  Without this a failed repair would leave the PLANNED binding for an
  orchestrator that never finalized, from which
  `Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1` / `session_complete?/4`
  would report FALSE readiness (codex review HIGH).
  """
  @spec restore_session_orchestrator_uri(URI.t(), URI.t() | nil) :: :ok | {:error, term()}
  def restore_session_orchestrator_uri(%URI{} = session_uri, prior) do
    wc = Session.read_template_working_copy(session_uri)

    working_copy =
      case prior do
        %URI{} -> Map.put(wc, :orchestrator_uri, prior)
        _ -> Map.delete(wc, :orchestrator_uri)
      end

    case Ezagent.Behavior.Session.system_set_working_copy(session_uri, working_copy) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_set_working_copy_result, other}}
    end
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
      target = Ezagent.URI.with_action(owner_uri, :identity, :grant_cap)
      cap = %{want | granted_at: DateTime.utc_now()}

      result =
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

      case result do
        {:ok, _} -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, {:orchestrator_admin_cap_grant_failed, reason}}
        other -> {:error, {:orchestrator_admin_cap_grant_unexpected, other}}
      end
    end
  end

  def join_session_members(%URI{} = session_uri, members) when is_list(members) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    Enum.reduce_while(members, :ok, fn %URI{} = member_uri, :ok ->
      _ = EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(member_uri)

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{member: member_uri},
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
end
