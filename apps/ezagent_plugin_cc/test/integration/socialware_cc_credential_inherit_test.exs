defmodule Ezagent.PluginCc.Integration.SocialwareCcCredentialInheritTest do
  @moduledoc """
  Credential-bearing session roles always enter per-session admission, even
  when the installer already has a user-default pointer or host CLI login.

  The fixtures deliberately provide reusable credentials and prove that the
  session-local admission path does not consume them. The real `CcAgent`
  Template Class runs with its test PTY, so admission can create an isolated,
  secret-free provisional home without launching a real Claude CLI.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Credential.{GrantCap, GrantRow, UserDefaultSource}
  alias Ezagent.Entity.Session
  alias Ezagent.Entity.User
  alias Ezagent.KindRegistry
  alias Ezagent.PluginCc.Template.CcAgent
  alias EzagentCore.Repo
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentLifecycle
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @workspace_uri URI.new!("workspace://system")

  defp uniq, do: System.unique_integer([:positive])

  defp terminate(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      :error -> :ok
    end
  end

  defp tmp(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp live_session(n, owner_uri) do
    session_uri = Ezagent.URI.session("system", "generic", "cred-inherit-#{n}")

    params =
      %{uri: session_uri, behaviors: Session.behaviors()}
      |> then(fn params ->
        if owner_uri, do: Map.put(params, :owner_uri, owner_uri), else: params
      end)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, params)

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> terminate(session_uri) end)
    session_uri
  end

  defp seed_recipe(n, project_cwd) do
    name = "cred-inherit-worker-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        requested_caps: [
          %{behavior: Ezagent.ActionSet.Identity, action: :list_caps}
        ],
        config: %{project_cwd: project_cwd}
      })

    name
  end

  defp declare_admission_role(session_uri, declaration, revision) do
    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "cc-admission@revision-#{revision}")
      )
      |> Map.put(:member_declarations, [declaration])

    SessionBehavior.system_set_working_copy(session_uri, working_copy)
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    n = uniq()

    # --- the INSTALLER's credential source (self-minted fake, never real) ---
    fake_token = "FAKE-INSTALLER-TOKEN-#{n}"
    source_dir = tmp("cc-installer-src")
    File.write!(Path.join(source_dir, ".credentials.json"), fake_token)
    # a config file at the source MUST NOT be pulled (§D6 secret-only copy)
    File.write!(Path.join(source_dir, "settings.json"), "INSTALLER-SETTINGS")

    source_uri = URI.new!("entity://system/agent/cc_installer-base-#{n}")

    {:ok, _} =
      Ezagent.SnapshotStore.write(
        URI.to_string(source_uri),
        %{
          sandbox: %{
            state: %{
              config_dir_path: source_dir,
              flavor: "cc",
              template_class: nil,
              respawn_template_data: nil,
              pty_phase: nil,
              passive: false,
              recipe: nil
            }
          }
        },
        kind_type: :agent,
        version: 0
      )

    # --- the INSTALLER: live User Kind holding sandbox.read on the source ---
    installer_uri = URI.new!("entity://system/user/installer-#{n}")

    {:ok, source_read_artifact} =
      Ezagent.Cap.issue(
        {:admin, User.admin_uri()},
        installer_uri,
        GrantCap.read_cap_for(source_uri)
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{
        uri: installer_uri,
        initial_caps: MapSet.new([source_read_artifact])
      })

    on_exit(fn -> terminate(installer_uri) end)

    # --- the installer's #17 user-default pointer for (installer, ws, cc) ---
    {:ok, _row} =
      %{
        owner_uri: URI.to_string(installer_uri),
        workspace_uri: "system",
        flavor: "cc",
        source_uri: URI.to_string(source_uri)
      }
      |> UserDefaultSource.changeset()
      |> Repo.insert()

    project_cwd = tmp("cc-cred-inherit-cwd")

    {:ok,
     n: n,
     installer_uri: installer_uri,
     source_uri: source_uri,
     fake_token: fake_token,
     project_cwd: project_cwd}
  end

  test "an adopted credential pointer cannot bypass per-session admission",
       %{
         n: n,
         installer_uri: installer_uri,
         project_cwd: project_cwd
       } do
    session_uri = live_session(n, installer_uri)
    recipe_name = seed_recipe(n, project_cwd)
    role_name = "cred-inherit-role-#{n}"

    declaration = %{
      recipe: recipe_name,
      role_name: role_name,
      flavor: "cc",
      credential_admission: :before_session_join
    }

    assert {:ok, _} = declare_admission_role(session_uri, declaration, n)

    assert {:ok, %{satisfied: [], skipped: [], deferred: [^role_name]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               installer_uri,
               [declaration]
             )

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil
    assert [%{role_name: ^role_name, status: :pending_auth}] = AgentAdmission.list(session_uri)
  end

  test "Claude admission starts a session-local secret-free PTY before joining", %{
    n: n,
    installer_uri: installer_uri,
    project_cwd: project_cwd
  } do
    session_uri = live_session("admission-#{n}", installer_uri)
    recipe_name = seed_recipe("admission-#{n}", project_cwd)
    role_name = "cc-admission-role-#{n}"

    declaration = %{
      recipe: recipe_name,
      role_name: role_name,
      flavor: "cc",
      credential_admission: :before_session_join
    }

    assert {:ok, _} = declare_admission_role(session_uri, declaration, "pty-#{n}")

    assert {:ok, %{deferred: [^role_name]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               installer_uri,
               [declaration]
             )

    caps = Ezagent.Identity.list_caps_for(installer_uri)

    assert {:ok,
            %{
              status: :authenticating,
              connection: {:pty, %{label: "Connect Claude"}}
            } = admission} =
             AgentAdmission.begin(session_uri, role_name, installer_uri, caps)

    agent_uri = Ezagent.URI.new!(admission.provisional_agent_uri)
    config_dir = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(config_dir) end)

    assert Ezagent.Kind.alive?(agent_uri)
    assert Ezagent.Domain.Pty.alive?(agent_uri)

    assert SessionBehavior.role_name_to_uri(
             DefinitionAgentLifecycle.read_members(session_uri),
             role_name
           ) == nil

    assert GrantRow.get_for_agent(admission.provisional_agent_uri) == nil
    assert File.exists?(Path.join(config_dir, ".ezagent-config-complete"))
    refute File.exists?(Path.join(config_dir, ".credentials.json"))

    assert {:error, :authentication_failed, %{status: :failed}} =
             AgentAdmission.complete(
               session_uri,
               role_name,
               admission.attempt_id,
               {installer_uri, caps}
             )

    assert SessionBehavior.role_name_to_uri(
             DefinitionAgentLifecycle.read_members(session_uri),
             role_name
           ) == nil

    refute Ezagent.Kind.alive?(agent_uri)
  end

  describe "host login cannot bypass session-local admission" do
    setup %{n: n} do
      host_token = "FAKE-HOST-LOGIN-TOKEN-#{n}"
      host_dir = tmp("cc-host-login")
      File.write!(Path.join(host_dir, ".credentials.json"), host_token)
      File.write!(Path.join(host_dir, "settings.json"), "HOST-SETTINGS")

      previous = System.get_env("CLAUDE_CONFIG_DIR")
      System.put_env("CLAUDE_CONFIG_DIR", host_dir)

      on_exit(fn ->
        case previous do
          nil -> System.delete_env("CLAUDE_CONFIG_DIR")
          v -> System.put_env("CLAUDE_CONFIG_DIR", v)
        end
      end)

      # The host operator = the genesis admin, live with its bootstrap caps
      # (in production the admin User Kind is live whenever anyone installs).
      admin_uri = User.admin_uri()
      host_source = Ezagent.Agent.HostLoginAdopt.host_login_source_uri("system", "cc")
      on_exit(fn -> terminate(host_source) end)

      case Ezagent.Kind.spawn(User, %{
             uri: admin_uri,
             initial_caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
           }) do
        # The genesis admin is application-global test state, not fixture-owned
        # state. Leave it live when this setup has to repair a missing process;
        # terminating it here makes every later authenticated web test fail.
        {:ok, _pid} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, {:already_registered, _}} -> :ok
      end

      {:ok, host_token: host_token, host_dir: host_dir, admin_uri: admin_uri}
    end

    test "the host operator login cannot bypass per-session admission",
         %{n: n, project_cwd: project_cwd, admin_uri: admin_uri} do
      ws_name = Ezagent.URI.workspace_name!(@workspace_uri)
      default_source_id = UserDefaultSource.id(URI.to_string(admin_uri), ws_name, "cc")

      case Repo.get(UserDefaultSource, default_source_id) do
        nil -> :ok
        row -> Repo.delete!(row)
      end

      assert UserDefaultSource.resolve(URI.to_string(admin_uri), ws_name, "cc") == nil

      session_uri = live_session("host-#{n}", admin_uri)
      recipe_name = seed_recipe("host-#{n}", project_cwd)
      role_name = "host-inherit-role-#{n}"

      declaration = %{
        recipe: recipe_name,
        role_name: role_name,
        flavor: "cc",
        credential_admission: :before_session_join
      }

      assert {:ok, _} = declare_admission_role(session_uri, declaration, "host-#{n}")

      assert {:ok, %{satisfied: [], skipped: [], deferred: [^role_name]}} =
               DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 @workspace_uri,
                 admin_uri,
                 [declaration]
               )

      assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil
      assert UserDefaultSource.resolve(URI.to_string(admin_uri), ws_name, "cc") == nil

      assert [%{role_name: ^role_name, status: :pending_auth}] =
               AgentAdmission.list(session_uri)
    end

    test "a NON-operator installer without a pointer does NOT inherit the host login (security)",
         %{n: n, project_cwd: project_cwd} do
      ws_name = Ezagent.URI.workspace_name!(@workspace_uri)

      # A co-tenant member, live, no pointer, no cap on anything host-related.
      other_uri = URI.new!("entity://system/user/co-tenant-#{n}")
      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: other_uri, initial_caps: MapSet.new()})
      on_exit(fn -> terminate(other_uri) end)

      session_uri = live_session("other-#{n}", other_uri)
      recipe_name = seed_recipe("other-#{n}", project_cwd)
      role_name = "no-host-inherit-role-#{n}"

      declaration = %{
        recipe: recipe_name,
        role_name: role_name,
        flavor: "cc",
        credential_admission: :before_session_join
      }

      assert {:ok, _} = declare_admission_role(session_uri, declaration, "other-#{n}")

      assert {:ok, %{satisfied: [], skipped: [], deferred: [^role_name]}} =
               DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 @workspace_uri,
                 other_uri,
                 [declaration]
               )

      members = members_of(session_uri)
      assert SessionBehavior.role_name_to_uri(members, role_name) == nil

      # The HOST login must NOT flow to an agent a co-tenant caused to exist
      # (#161 / DoD 6): no credential file, no auto-created pointer, no grant.
      assert UserDefaultSource.resolve(URI.to_string(other_uri), ws_name, "cc") == nil

      assert [%{role_name: ^role_name, status: :pending_auth}] =
               AgentAdmission.list(session_uri)
    end
  end

  defp members_of(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    Map.get(slice, :members, %{})
  end
end
