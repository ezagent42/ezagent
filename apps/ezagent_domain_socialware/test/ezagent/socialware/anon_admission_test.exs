defmodule Ezagent.Socialware.AnonAdmissionTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate}

  alias Ezagent.Socialware.{
    AnonAdmission,
    AnonBinding,
    AnonUser,
    ChatFeed,
    DefinitionRegistry,
    Installation
  }

  alias Ezagent.{Capability, KindRegistry}

  @workspace "team-alpha"
  @owner Ezagent.URI.user(:system, :admin)

  defp public_session(flag \\ true) do
    u = System.unique_integer([:positive])

    name = "anon-admission-def-#{u}"

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(definition(name, flag),
        workspace_uri: Ezagent.URI.workspace(@workspace)
      )

    content = %{name: "anon-admission-tmpl-#{u}", installs: [name]}

    {:ok, tmpl_uri} = SessionTemplate.persist_version_as_system(content, @workspace)

    session_uri = Ezagent.URI.new!("session://#{@workspace}/default/anon-admission-#{u}")

    {:ok, behaviors} =
      Installation.behavior_set_for_template(content, Ezagent.URI.workspace(@workspace))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        owner_uri: @owner,
        behaviors: behaviors
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    :ok =
      Installation.install_template_installs(
        session_uri,
        Ezagent.URI.workspace(@workspace),
        content,
        @owner
      )

    {:ok, _} =
      ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl_uri})

    on_exit(fn -> terminate(session_uri) end)
    session_uri
  end

  defp definition(name, web_anon_access) do
    %{
      name: name,
      bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
      shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
      owner_policy: %{type: :installer},
      visibility_policy: %{publish_policy: :auto, web_anon_access: web_anon_access}
    }
  end

  defp terminate(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

      :error ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp member?(session, member) do
    case Ezagent.Kind.get_slice(session, :session) do
      {:ok, %{state: %{members: members}}} when is_map(members) -> Map.has_key?(members, member)
      {:ok, %{members: members}} when is_map(members) -> Map.has_key?(members, member)
      _ -> false
    end
  end

  describe "admit_anonymous_participant/2" do
    test "mints, spawns, binds, joins as anon, and can read by membership" do
      session = public_session()

      assert {:ok, %{anon_uri: anon, source: :minted}} =
               AnonAdmission.admit_anonymous_participant(session)

      assert AnonUser.anon_uri?(anon)
      assert %AnonBinding{} = AnonBinding.get(anon)
      assert member?(session, anon)
      assert {:ok, %{messages: _}} = ChatFeed.snapshot(session, anon)
    end

    test "join cap remains #154-clean with no system principal granter" do
      session = public_session()

      assert {:ok, %{anon_uri: anon}} = AnonAdmission.admit_anonymous_participant(session)
      %{caps: caps} = Ezagent.Users.get_by_uri(anon)

      cap =
        Enum.find(caps, fn cap ->
          cap.behavior == Ezagent.ActionSet.Session and cap.action == :join
        end)

      assert cap.action == :join
      assert cap.instance == Ezagent.URI.instance(session)
      assert match?(%URI{scheme: "entity"}, cap.granted_by)
      refute match?(%URI{scheme: "system"}, cap.granted_by)
    end

    test "participation cap mount is best-effort after a successful join" do
      session = public_session()

      assert {:ok, %{anon_uri: anon}} =
               AnonAdmission.admit_anonymous_participant(session,
                 mount_participation: fn _session, _anon -> raise "mount failed" end
               )

      assert member?(session, anon)
    end

    test "private sessions fail closed" do
      session = public_session(false)

      assert {:error, :not_public_view} =
               AnonAdmission.admit_anonymous_participant(session)
    end

    test "join failure fails closed and does not report admission" do
      session = public_session()

      assert {:error, :join_denied} =
               AnonAdmission.admit_anonymous_participant(session,
                 join: fn _session, _anon -> {:error, :join_denied} end
               )
    end
  end

  describe "refresh_anonymous_participant/3" do
    test "refreshes an existing anon binding and respawns the principal" do
      session = public_session()
      assert {:ok, %{anon_uri: anon}} = AnonAdmission.admit_anonymous_participant(session)

      assert {:ok, %{anon_uri: ^anon, source: :reused}} =
               AnonAdmission.refresh_anonymous_participant(session, anon)
    end
  end
end
