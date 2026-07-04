defmodule EzagentPluginHello.Migrate do
  @moduledoc """
  One-time, idempotent migration: give every EXISTING hello session the invisible
  `hello.orchestrator` front desk it was created before.

  A hello session created before the orchestrator model has no `orch_<name>`
  member, so under the new ingress (all user messages are mentioned to the
  orchestrator) its messages would go nowhere. This adds the orchestrator to each
  such session; from then on the orchestrator routes messages and lazily (re)spawns
  the builder / concierge on demand.

  Safe by construction:

    * The published PAGE is untouched — it lives on the session's `Behavior.Surface`,
      not on any agent, so nothing here can lose it.
    * The stale pre-migration builder/concierge members (which reference the removed
      `Entity.HelloBuilder`/`HelloConcierge` Kinds) are LEFT ALONE — they are never
      addressed again (messages go to the orchestrator, which drives generation via
      admin-authority `TurnDriver`, not via those agents), so they are harmless.
    * Idempotent — re-running is a no-op (`ensure_session_orchestrator` tolerates an
      already-joined orchestrator).

  Runs IN the serving node (a separate CLI node cannot revive the running node's
  sessions), opt-in via `HELLO_MIGRATE_ORCHESTRATOR=1` at boot
  (`EzagentPluginHello.Application`).
  """

  require Logger

  @type report :: %{migrated: [String.t()], skipped: [String.t()], failed: [{String.t(), term()}]}

  @doc "Add the orchestrator to every persisted hello session. Returns a per-session report."
  @spec migrate_all() :: report()
  def migrate_all do
    sessions = hello_sessions()
    Logger.info("hello orchestrator migration: #{length(sessions)} hello session(s) found")

    Enum.reduce(sessions, %{migrated: [], skipped: [], failed: []}, fn uri, acc ->
      s = URI.to_string(uri)

      case migrate_one(uri) do
        {:ok, _orch} -> Map.update!(acc, :migrated, &[s | &1])
        :ignore -> Map.update!(acc, :skipped, &[s | &1])
        {:error, reason} -> Map.update!(acc, :failed, &[{s, reason} | &1])
      end
    end)
  end

  @doc """
  Migrate one hello session: revive it in-node (cold sessions are not auto-live at
  boot), then ensure its orchestrator. `:ignore` if it is not a page/hello session.
  """
  @spec migrate_one(URI.t()) :: {:ok, URI.t()} | :ignore | {:error, term()}
  def migrate_one(%URI{} = session_uri) do
    # Bring the persisted session live so the join lands + the page-session check
    # (a slice read) sees the Surface. `ensure_live` is the sanctioned respawn.
    _ = Ezagent.SpawnRegistry.ensure_live(session_uri)

    # A pre-existing orchestrator from an earlier migration is the WRONG flavor
    # (`native`, which drops chat). Replace it in place: terminate the live agent,
    # drop its snapshot + flavor attribute so the recreate is a FRESH `"hello"`-flavor
    # agent (not a revive of the native one), at the SAME URI so the membership holds.
    orch_uri = EzagentPluginHello.App.orchestrator_uri(session_uri)
    _ = Ezagent.Kind.terminate(orch_uri)
    _ = Ezagent.SnapshotStore.delete(orch_uri)
    _ = Ezagent.AgentFlavorAttributes.delete(orch_uri)

    EzagentPluginHello.App.ensure_session_orchestrator(session_uri)
  rescue
    e -> {:error, e}
  end

  # Every persisted `session://<ws>/hello/<name>` snapshot (across all workspaces).
  # Mirrors `SessionCreator.Listing.persisted_session_uris/0`'s snapshot scan.
  defp hello_sessions do
    Ezagent.Ecto.KindSnapshot.list_all()
    |> Enum.flat_map(fn snap ->
      with "session" <- Map.get(snap, :kind_type),
           uri when is_binary(uri) <- Map.get(snap, :uri),
           {:ok, %URI{} = u} <- Ezagent.URI.parse(uri),
           true <- hello_session?(u) do
        [u]
      else
        _ -> []
      end
    end)
    |> Enum.uniq_by(&URI.to_string/1)
  rescue
    _ -> []
  end

  # `session://<ws>/hello/<name>` — the first path segment is the template "hello".
  defp hello_session?(%URI{} = uri) do
    case uri.path |> to_string() |> String.split("/", trim: true) do
      ["hello" | _] -> true
      _ -> false
    end
  end
end
