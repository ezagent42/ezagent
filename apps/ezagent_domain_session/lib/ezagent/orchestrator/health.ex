defmodule Ezagent.Orchestrator.Health do
  @moduledoc """
  Per-session orchestrator-instance health classifier — operator UI helper.

  The cc-orchestrator template seed status surfaced on `/plugins` is
  *system-level* boot health (the template is registered + seeded). What
  operators actually need when triaging a session is the *per-session
  instance* health: is the orchestrator agent for THIS session alive,
  crashed, or never spawned in the first place?

  This module is the pure read-side classifier. It does NOT mutate any
  state, dispatch any action, or hold a process. It is a thin composition
  of:

  * `Ezagent.Entity.Session.orchestrator_uri/1` — stored session attribute
    * `Ezagent.Runtime.Resolver.alive?/1` — live-process liveness BY URI
      (V5 A1c; was `KindRegistry.lookup/1` + a defensive `Process.alive?/1`
      double-check — the pid never enters domain code now)
    * `Ezagent.Ecto.KindSnapshot.get/1` — persisted snapshot row

  The three classification outcomes:

    * `:alive` — the orchestrator is live (the resolver seam registers the
      URI).
    * `:crashed` — no live process, BUT a `kind_snapshots` row exists for
      the orchestrator URI. The instance was spawned at some point and
      its slice persisted; it is no longer running. Restart is meaningful.
    * `:not_spawned` — no live process AND no snapshot row. This session
      has not yet needed (or never used) cc orchestration.

  Workspace binding: the orchestrator URI is stored on the session working
  copy. We read the workspace from
  `Ezagent.WorkspaceRegistry.lookup/1`. If the session is not bound
  (e.g. test fixture missing the `WorkspaceRegistry.bind/2` call) the
  caller gets `{:error, :session_not_workspace_bound}` — there is no
  silent fallback per `feedback_let_it_crash_no_workarounds`.

  ## Result shape

      %{
        uri: %URI{},
        instance_name: "cc_orchestrator-<disc>",
        workspace_uri: %URI{},
        template_uri: %URI{},
        status: :alive | :crashed | :not_spawned,
        snapshot_updated_at: DateTime.t() | nil
      }

  `template_uri` is always `template://agent/<workspace>/cc-orchestrator`
  — the seed template every cc session uses. Surfaced so the UI's Restart
  button has the dispatch target without recomputing it.
  """

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.Session
  alias Ezagent.WorkspaceRegistry

  @type status :: :alive | :crashed | :not_spawned

  @type t :: %{
          uri: URI.t(),
          instance_name: String.t(),
          workspace_uri: URI.t(),
          template_uri: URI.t(),
          status: status(),
          snapshot_updated_at: DateTime.t() | nil
        }

  @doc """
  Classify the orchestrator instance for `session_uri`.

  Returns `{:ok, health}` (always — the three statuses are part of the
  health value) or `{:error, :session_not_workspace_bound}` when the
  session URI has no `WorkspaceRegistry` binding.

  Per `feedback_let_it_crash_no_workarounds`: unexpected failures (e.g.
  the Registry process not started in a misconfigured test) propagate
  rather than being silently squashed to `:not_spawned` — that would
  hide bugs.
  """
  @spec classify(URI.t()) :: {:ok, t()} | {:error, :session_not_workspace_bound}
  def classify(%URI{} = session_uri) do
    case WorkspaceRegistry.lookup(session_uri) do
      {:ok, %URI{} = workspace_uri} ->
        {:ok, classify_in_workspace(session_uri, workspace_uri)}

      :error ->
        {:error, :session_not_workspace_bound}
    end
  end

  @doc """
  Classify the orchestrator instance for `session_uri` with the
  workspace URI supplied directly. Bypasses the `WorkspaceRegistry`
  lookup — useful for the UI layer that already has both URIs in hand
  and wants to avoid the extra ETS read.
  """
  @spec classify_in_workspace(URI.t(), URI.t()) :: t()
  def classify_in_workspace(%URI{} = session_uri, %URI{} = workspace_uri) do
    orch_uri = stored_or_planned_orchestrator_uri(session_uri, workspace_uri)
    instance_name = Ezagent.URI.name!(orch_uri)
    template_uri = orchestrator_template_uri(workspace_uri)

    {status, _pid} = lookup_status(orch_uri)
    snapshot_updated_at = snapshot_updated_at_for(orch_uri)

    # If the seam reports the URI not registered AND we have a snapshot, the
    # orchestrator was spawned but isn't live → :crashed. Otherwise
    # :not_spawned.
    final_status =
      case {status, snapshot_updated_at} do
        {:alive, _} -> :alive
        {:not_alive, %DateTime{}} -> :crashed
        {:not_alive, nil} -> :not_spawned
      end

    # V5 A1c — the health struct carries NO pid: `status` already conveys
    # liveness, and callers address the orchestrator by `uri`.
    %{
      uri: orch_uri,
      instance_name: instance_name,
      workspace_uri: workspace_uri,
      template_uri: template_uri,
      status: final_status,
      snapshot_updated_at: snapshot_updated_at
    }
  end

  # The cc-orchestrator seed template lives at a SYSTEM-scoped URI —
  # `template://agent/system/cc-orchestrator`. There is no per-tenant
  # orchestrator template Kind today; `Session.ensure_orchestrator/3`
  # at apps/ezagent_domain_session/lib/ezagent/entity/session.ex:567 hard-
  # codes the same URI. The workspace_uri argument is preserved in the
  # signature for future per-tenant template support but currently
  # unused; we use `_workspace_uri` to mark intent.
  #
  # Codex review PR #376 P2: returning the per-tenant URI here meant
  # Restart for any session outside `workspace://system` dispatched at
  # a non-existent template Kind. Aligned with the seed location now.
  defp orchestrator_template_uri(%URI{} = _workspace_uri) do
    Ezagent.URI.template(:system, :agent, "cc-orchestrator")
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

  # Liveness through the resolver seam BY URI (V5 A1c) — the pid never
  # enters this module; only the `:alive | :not_alive` verdict is used.
  defp lookup_status(%URI{} = orch_uri) do
    if Ezagent.Runtime.Resolver.alive?(orch_uri) do
      {:alive, nil}
    else
      {:not_alive, nil}
    end
  end

  defp snapshot_updated_at_for(%URI{} = orch_uri) do
    case KindSnapshot.get(URI.to_string(orch_uri)) do
      %KindSnapshot{updated_at: %DateTime{} = at} -> at
      %KindSnapshot{} -> nil
      nil -> nil
    end
  end
end
