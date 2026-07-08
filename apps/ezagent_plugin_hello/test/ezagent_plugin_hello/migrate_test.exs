defmodule EzagentPluginHello.MigrateTest do
  @moduledoc """
  Task 6 — bring existing hello sessions to the declarative team idempotently.

    * "already declarative" — `migrate_one/1` on a session `App.ensure_app/2`
      already fully materialized is a no-op-safe re-run (same members, no
      errors).
    * "missing team" — `migrate_one/1` on a session that has behaviors +
      template binding installed but NO team materialized yet (the shape a
      pre-`Definition.roles` session left the substrate in) lands the full
      orchestrator/builder/concierge team.
    * "stale orchestrator" (Task-4-flagged hardening) — a session whose
      `role_name: "front-desk"` slot is occupied by the WRONG recipe (a stale
      member left by a prior half-migration, or built the old imperative way)
      is reflavored: the stale member is removed and the real
      `hello.orchestrator` agent is materialized in its place. See
      `EzagentPluginHello.Migrate` moduledoc "Hardening" for the mechanism.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentPluginHello.{App, Members, Migrate}

  setup do
    # `ensure_app` / the bare fixture below resolve `hello.*` recipes through the
    # "role-as-data" RecipeRegistry. Boot seeds it, but that write is outside this
    # DataCase sandbox transaction (and the ETS cache can be flushed by another
    # test) — so seed the roles here (idempotent), mirroring
    # `hello_page_e2e_test.exs`.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    ws = "hello-migrate-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws, %{})

    %{ws: ws}
  end

  describe "migrate_one/1 on an already-declarative session" do
    test "is idempotent — re-running does not disturb the materialized team", %{ws: ws} do
      {:ok, session_uri, orch_uri} = App.ensure_app(ws, "current")

      assert {:ok, ^orch_uri} = Members.role_uri(session_uri, "front-desk")
      assert {:ok, builder_uri} = Members.role_uri(session_uri, "builder")
      assert {:ok, concierge_uri} = Members.role_uri(session_uri, "concierge")

      assert {:ok, ^session_uri} = Migrate.migrate_one(session_uri)

      # Same members, same recipe — a true no-op re-run.
      assert {:ok, ^orch_uri} = Members.role_uri(session_uri, "front-desk")
      assert {:ok, ^builder_uri} = Members.role_uri(session_uri, "builder")
      assert {:ok, ^concierge_uri} = Members.role_uri(session_uri, "concierge")
      assert {:ok, "hello.front-desk"} = Ezagent.AgentRecipeAttributes.fetch(orch_uri)

      # And migrate_all/0 (the boot entry point) reports it migrated, not failed.
      report = Migrate.migrate_all()
      s = URI.to_string(session_uri)
      assert s in report.migrated
      assert report.failed == []
    end
  end

  describe "migrate_one/1 on a session missing the declarative team" do
    test "materializes orchestrator + builder + concierge from scratch", %{ws: ws} do
      {session_uri, _owner_uri, _workspace_uri} = bare_hello_session(ws, "bare")

      # Before migrate: behaviors + template binding exist, but NO team.
      assert :error = Members.role_uri(session_uri, "front-desk")
      assert :error = Members.role_uri(session_uri, "builder")
      assert :error = Members.role_uri(session_uri, "concierge")

      assert {:ok, ^session_uri} = Migrate.migrate_one(session_uri)

      assert {:ok, orch_uri} = Members.role_uri(session_uri, "front-desk")
      assert {:ok, _builder_uri} = Members.role_uri(session_uri, "builder")
      assert {:ok, _concierge_uri} = Members.role_uri(session_uri, "concierge")
      assert {:ok, "hello.front-desk"} = Ezagent.AgentRecipeAttributes.fetch(orch_uri)
    end
  end

  describe "migrate_one/1 hardening — a stale (wrong-recipe) orchestrator" do
    test "removes the stale member and re-materializes the real hello.orchestrator", %{ws: ws} do
      {session_uri, owner_uri, workspace_uri} = bare_hello_session(ws, "stale")

      # Simulate the Task-4-flagged bug scenario: a prior half-migration (or the
      # old imperative build) left some OTHER recipe's agent occupying the
      # "front-desk" role_name slot. Reuses the SAME production materialization
      # plumbing (spawn → faceted join → grant caps) `repair_orchestrator` itself
      # calls — just fed the WRONG recipe for this role, on purpose.
      assert :ok =
               SessionCreator.DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 workspace_uri,
                 owner_uri,
                 [
                   %{
                     role_name: "front-desk",
                     fill: :agent,
                     recipe: "hello.builder",
                     flavor: "native"
                   }
                 ]
               )

      assert {:ok, stale_uri} = Members.role_uri(session_uri, "front-desk")
      assert {:ok, "hello.builder"} = Ezagent.AgentRecipeAttributes.fetch(stale_uri)
      # builder/concierge were never materialized in this bare fixture.
      assert :error = Members.role_uri(session_uri, "builder")
      assert :error = Members.role_uri(session_uri, "concierge")

      assert {:ok, ^session_uri} = Migrate.migrate_one(session_uri)

      assert {:ok, fresh_uri} = Members.role_uri(session_uri, "front-desk")
      refute URI.to_string(fresh_uri) == URI.to_string(stale_uri)
      assert {:ok, "hello.front-desk"} = Ezagent.AgentRecipeAttributes.fetch(fresh_uri)

      # The repair that follows the reflavor also lands the rest of the team.
      assert {:ok, _builder_uri} = Members.role_uri(session_uri, "builder")
      assert {:ok, _concierge_uri} = Members.role_uri(session_uri, "concierge")

      # Re-running is now a no-op (the correct recipe short-circuits the check).
      assert {:ok, ^session_uri} = Migrate.migrate_one(session_uri)
      assert {:ok, ^fresh_uri} = Members.role_uri(session_uri, "front-desk")
    end
  end

  # --- helpers ----------------------------------------------------------------

  # Mirrors `EzagentPluginHello.App.ensure_app/2` up to (but stopping BEFORE)
  # `SessionCreator.materialize_template_team/4` — a live socialware session
  # with behaviors installed + its template working copy bound, but with NO
  # team materialized. This is the shape a session predating `Definition.roles`
  # (or a session whose team materialization crashed mid-way) is left in.
  defp bare_hello_session(ws, name) do
    session_uri = Ezagent.URI.session(ws, :hello, name)
    workspace = Ezagent.Capability.workspace_of(session_uri)
    socialware_name = "hello-#{name}-#{System.unique_integer([:positive])}"
    admin = User.admin_uri()
    raw_content = %{name: socialware_name, installs: [socialware_name]}

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(
        App.hello_definition_attrs(socialware_name),
        workspace_uri: workspace,
        actor_uri: admin
      )

    {:ok, content} = Installation.freeze_template_installs(raw_content, workspace)
    {:ok, owner_uri} = Installation.owner_uri_for_template(content, workspace, admin)
    {:ok, tmpl} = Ezagent.Entity.SessionTemplate.persist_version_as_system(content, ws)
    {:ok, behaviors} = Installation.behavior_set_for_template(content, workspace)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        owner_uri: owner_uri,
        behaviors: behaviors
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace)
    :ok = Installation.install_template_installs(session_uri, workspace, content, admin)

    {:ok, _} =
      Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy(session_uri, %{
        session_template_uri: tmpl
      })

    {session_uri, owner_uri, workspace}
  end
end
