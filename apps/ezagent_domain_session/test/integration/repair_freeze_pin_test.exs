defmodule EzagentDomainInstanceMessage.Integration.RepairFreezePinTest do
  @moduledoc """
  T-Pin (repair path) — freeze-pin MUST cover repair/rematerialization
  (codex completeness gap).

  Fresh create freezes each install to the revision CURRENT at create time and
  threads the pinned `config_id` into the session's per-session install records.
  `repair_orchestrator/1,2` re-reads the (unpinned) SessionTemplate content and
  re-materializes the template declaration + team. Before the fix it resolved
  every install LIVE, so a `publish`/`retract` between create and repair silently
  swapped an EXISTING session's behaviors on repair — violating the freeze-pin
  invariant ("a later publish does NOT change a running session"). The repair path
  now re-pins from the session's own install records, so it rebuilds from the SAME
  frozen revision it was created with.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.KindRegistry
  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}
  alias EzagentDomainInstanceMessage.SessionCreator

  @ws "workspace://system"

  defp uniq, do: System.unique_integer([:positive])

  setup do
    :ok = seed_builtins()
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  test "repair_orchestrator rebuilds an existing session from its FROZEN revision (R1), not a later publish (R2)" do
    def_name = "repair-pin-#{uniq()}"

    # R1 — the revision CURRENT when the session is created. Declares a member
    # `r1role` so the resolved config (and thus the session's recorded
    # member_declarations) is behaviorally distinguishable from R2.
    _r1 = write_def!(def_name, "r1role")

    template_name = "repair-pin-tpl-#{uniq()}"
    persist_template(template_content(template_name, [def_name]))

    {:ok, session_uri, %{}} =
      SessionCreator.create_session("repair-pin-sess-#{uniq()}", User.admin_uri(),
        template_name: template_name
      )

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionSupervisor, session_uri)
    end)

    # At create the session froze R1: its recorded member_declarations reflect R1.
    assert "r1role" in member_roles(session_uri)
    refute "r2role" in member_roles(session_uri)

    # A LATER publish advances the def's current pointer to R2 (different member).
    r2 = write_def!(def_name, "r2role")
    # sanity: an UNPINNED live resolution now follows R2 (the control that proves
    # the repair path would regress without the freeze).
    {:ok, [{_d, live_obj, _i}]} =
      Installation.resolved_template_installs(%{installs: [def_name]}, @ws)

    assert live_obj.id == r2.id

    # Repair the existing session. It re-reads the (unpinned) SessionTemplate
    # content — WITHOUT the fix it would rebuild from R2.
    assert {:ok, ^session_uri, %{}} =
             EzagentDomainInstanceMessage.repair_orchestrator(session_uri)

    # Freeze-pin holds across repair: still R1, never R2.
    assert "r1role" in member_roles(session_uri),
           "repair MUST rebuild from the frozen revision R1"

    refute "r2role" in member_roles(session_uri),
           "repair MUST NOT follow the later publish R2 (freeze-pin invariant)"
  end

  test "repair rebuilds from the frozen revision even after the def is RETRACTED (freeze-pin ∘ retract-grandfather)" do
    def_name = "repair-pin-ret-#{uniq()}"
    _r1 = write_def!(def_name, "r1role")

    template_name = "repair-pin-ret-tpl-#{uniq()}"
    persist_template(template_content(template_name, [def_name]))

    {:ok, session_uri, %{}} =
      SessionCreator.create_session("repair-pin-ret-sess-#{uniq()}", User.admin_uri(),
        template_name: template_name
      )

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionSupervisor, session_uri)
    end)

    assert "r1role" in member_roles(session_uri)

    # Retract the def from the catalog (a NEW install could no longer select it).
    {:ok, _} = DefinitionRegistry.set_retracted(@ws, def_name, true, User.admin_uri())
    refute Enum.any?(DefinitionRegistry.list(@ws), &(&1.name == def_name))

    # Repair STILL rebuilds the grandfathered session from the pinned R1 — the
    # per-session record resolves via fetch_object(config_id), bypassing the
    # retract-aware lookup.
    assert {:ok, ^session_uri, %{}} =
             EzagentDomainInstanceMessage.repair_orchestrator(session_uri)

    assert "r1role" in member_roles(session_uri),
           "a grandfathered session must still rebuild from its frozen revision after retract"
  end

  defp write_def!(name, member_role) do
    {:ok, definition} =
      Definition.new(%{
        name: name,
        title: "Repair pin #{name}",
        bases: [Ezagent.ActionSet.Session],
        shape: [],
        roles: [
          %{role_name: member_role, fill: :human}
        ],
        visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
      })

    {:ok, object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @ws,
        caller_workspace_uri: @ws,
        actor_uri: User.admin_uri()
      )

    object
  end

  defp member_roles(session_uri) do
    session_uri
    |> Session.read_template_working_copy()
    |> Map.get(:member_declarations, [])
    |> Enum.map(&(Map.get(&1, :role_name) || Map.get(&1, "role_name")))
  end

  defp template_content(name, installs) do
    %{
      name: name,
      description: "repair freeze-pin regression",
      default_workspace_uri: Ezagent.URI.workspace(:system),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: nil,
      roles: [],
      prompt_templates: %{},
      legends: %{},
      routing_rules: [],
      installs: installs
    }
  end

  defp persist_template(content) do
    hash = SessionTemplate.compute_version_hash(content)
    uri = SessionTemplate.build_uri(content.name, hash, workspace: "system")
    :ok = KindSnapshot.delete(URI.to_string(uri))

    {:ok, uri} = SessionTemplate.persist_version_as_system(content, "system")

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionTemplateSupervisor, uri)
    end)

    uri
  end

  defp terminate_if_alive(supervisor, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)

      :error ->
        :ok
    end
  end

  defp seed_builtins do
    case DefinitionRegistry.seed_builtin_definitions() do
      :ok -> :ok
      {:error, {:socialware_definition_seed_collision, _}} -> :ok
    end
  end
end
