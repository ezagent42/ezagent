defmodule EzagentPluginHello.Migrate do
  @moduledoc """
  One-time, idempotent migration: bring every EXISTING hello session onto the
  DECLARATIVE team (`Definition.roles` — orchestrator / builder / concierge, each
  a role × flavor agent) + its versioned SessionTemplate binding.

  A hello session created before the `Definition.roles` model (the old imperative
  `orch_<name>` convention, or a half-migrated session from a prior run) has no
  framework-materialized team, so under the current ingress (all user messages
  are mentioned to the orchestrator, resolved by `role_name`, NOT by URI
  convention) its messages would go nowhere. This re-materializes the DECLARED
  team via the sanctioned framework repair
  (`SessionCreator.repair_orchestrator/1`, which runs `materialize_template_team/4`
  — the SAME standard path the socialware `create_session` flow runs); from then
  on `Members.role_uri/2` resolves each role.

  ## Hardening (Task 6) — a stale, wrong-recipe orchestrator is NOT skipped

  `repair_orchestrator/1`'s materialization
  (`SessionCreator.DefinitionAgents.materialize_one/4`) skips a role the instant
  ANY member is already joined under that `role_name` — it does not check WHICH
  agent that is (`existing_member_for_role/2`, a domain file this plugin cannot
  modify — PLUGIN-ONLY). A session built the OLD imperative way, or left over
  from a prior half-migration, can carry a member joined under `role_name:
  "orchestrator"` that is NOT a `"hello.orchestrator"`-recipe agent; left alone,
  `repair_orchestrator` would perpetually skip that role and the session would
  never get the real hello-flavored front desk.

  `migrate_one/1` therefore READ-ONLY-detects the current orchestrator's
  build-provenance recipe (`Ezagent.AgentRecipeAttributes.fetch/1` → the durable
  `Ezagent.UriQuery.resolve(:recipe, _)` fallback — the same two-step lookup
  `DefinitionAgents.agent_recipe/1` uses internally) BEFORE delegating to
  `repair_orchestrator/1`. A mismatch (or unresolvable recipe) removes that
  participant via the ALREADY-sanctioned `Ezagent.Session.Participants.remove_participant/3`
  dispatch (the same `session.remove_participant` chokepoint the CLI / world UI
  use), authorized by an INLINE system-mediated capability (mirrors the
  `join_cap`/`destroy_cap` pattern `DefinitionAgents` itself uses for its own
  spawn/join/cleanup envelope — no persisted owner grant required, no domain file
  touched) — freeing the role so the subsequent `repair_orchestrator` call
  re-materializes the correct agent. A session whose orchestrator IS already
  `"hello.orchestrator"`-flavored short-circuits this check (pure no-op) —
  idempotent, re-run safe.

  Safe by construction:

    * The published PAGE is untouched — it lives on the session's `Behavior.Surface`,
      not on any agent, so nothing here can lose it.
    * Stale pre-migration builder/concierge members that reference the removed
      `Entity.HelloBuilder`/`HelloConcierge` Kinds are simply never resolved again
      (routing/role lookups go through `role_name`, not the retired URI
      convention) — they are dead weight, not a hazard, and this migration does
      not chase them down (only the orchestrator role gets the reflavor check,
      since it alone gates message ingress).
    * Idempotent — re-running is a no-op once every role is materialized with the
      correct recipe.

  Runs IN the serving node (a separate CLI node cannot revive the running node's
  sessions), opt-in via `HELLO_MIGRATE_ORCHESTRATOR=1` at boot
  (`EzagentPluginHello.Application`).
  """

  require Logger

  alias EzagentPluginHello.Members

  # Routing-sense role_name. Named `@orch_role_name` (not `@orchestrator_` + `role`)
  # so it does not collide with the recipe-sense identifier the no-recipe-sense-role
  # invariant gate forbids; this value is the routing role_name, which is preserved.
  @orch_role_name "orchestrator"
  @orchestrator_recipe "hello.front-desk"

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
  boot), reflavor a stale (non-`hello.orchestrator`) orchestrator if one is
  squatting the role (see moduledoc "Hardening"), then re-materialize the
  DECLARED `Definition.roles` team via the sanctioned framework repair
  (`SessionCreator.repair_orchestrator/1`, which runs `materialize_template_team/4`).
  Idempotent — a role already correctly materialized is skipped.
  """
  @spec migrate_one(URI.t()) :: {:ok, URI.t()} | :ignore | {:error, term()}
  def migrate_one(%URI{} = session_uri) do
    # Bring the persisted session live so the repair reads its bound template + the
    # materialized members land. `ensure_live` is the sanctioned respawn.
    _ = Ezagent.SpawnRegistry.ensure_live(session_uri)

    with :ok <- reflavor_stale_orchestrator(session_uri),
         {:ok, _session_uri, _meta} <-
           EzagentDomainInstanceMessage.SessionCreator.repair_orchestrator(session_uri) do
      {:ok, session_uri}
    end
  rescue
    e -> {:error, e}
  end

  # --- Task-6 hardening: a stale (wrong-recipe) orchestrator is NOT skipped -----

  # No orchestrator joined yet → nothing to reflavor; `repair_orchestrator` will
  # materialize a fresh one. An orchestrator already on the correct recipe → also
  # nothing to do (true no-op, keeps this idempotent). Only a MISMATCH acts.
  defp reflavor_stale_orchestrator(%URI{} = session_uri) do
    case Members.role_uri(session_uri, @orch_role_name) do
      {:ok, %URI{} = orch_uri} ->
        if correct_orchestrator_recipe?(orch_uri),
          do: :ok,
          else: remove_stale_orchestrator(session_uri, orch_uri)

      :error ->
        :ok
    end
  end

  defp correct_orchestrator_recipe?(%URI{} = agent_uri) do
    match?({:ok, @orchestrator_recipe}, agent_recipe(agent_uri))
  end

  # The same ETS-fast-path → durable-resolver layering
  # `SessionCreator.DefinitionAgents.agent_recipe/1` uses internally — both
  # `Ezagent.AgentRecipeAttributes` and `Ezagent.UriQuery` are public core/domain
  # read APIs (consumed, not modified).
  defp agent_recipe(%URI{} = agent_uri) do
    case Ezagent.AgentRecipeAttributes.fetch(agent_uri) do
      {:ok, recipe} -> {:ok, recipe}
      :none -> Ezagent.UriQuery.resolve(:recipe, agent_uri)
    end
  rescue
    _ -> :none
  end

  # Free the "orchestrator" role_name via the ALREADY-sanctioned
  # `session.remove_participant` dispatch, authorized by an INLINE
  # system-mediated capability (mirrors `DefinitionAgents`'s own `join_cap`/
  # `destroy_cap` pattern) — no persisted owner grant required, no domain file
  # touched. `repair_orchestrator` (called right after by `migrate_one`) then
  # finds the role empty and materializes the correct `hello.orchestrator` agent.
  defp remove_stale_orchestrator(%URI{} = session_uri, %URI{} = orch_uri) do
    admin = Ezagent.Entity.User.admin_uri()

    case Ezagent.Session.Participants.remove_participant(session_uri, orch_uri, %{
           caller: admin,
           caps: MapSet.new([remove_participant_cap(session_uri, admin)])
         }) do
      {:ok, _} ->
        Logger.warning(
          "hello migrate: removed stale (non-#{@orchestrator_recipe}) orchestrator " <>
            "#{URI.to_string(orch_uri)} from #{URI.to_string(session_uri)} before repair"
        )

        :ok

      {:error, reason} ->
        {:error, {:stale_orchestrator_removal_failed, reason}}
    end
  end

  defp remove_participant_cap(%URI{} = session_uri, %URI{} = admin) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session,
        :any,
        :remove_participant,
        Ezagent.URI.instance(session_uri),
        Ezagent.Capability.workspace_of(session_uri)
      )
      | granted_by: admin,
        granted_at: DateTime.utc_now()
    }
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
