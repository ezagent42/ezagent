defmodule Ezagent.PluginCc.Integration.SocialwareCcCredentialInheritTest do
  @moduledoc """
  jjkysy #1201 finding A② — INVARIANT: materializing a cc-flavor role from a
  socialware Definition (`DefinitionAgents.materialize_definition_agents/4`,
  the `SessionCreator.materialize_template_team/4` framework path) must
  provision the materialized agent's config_dir with the INSTALLER's cc
  credentials through the EXISTING #17 credential cascade — the same
  resolution the world create-agent path uses (installer as `owner_uri` →
  `UserDefaultSource` pointer → secret-only copy from the source config_dir).

  The installer ctx here is fully self-contained test data: a minted fake
  `.credentials.json` (never a real credential), a source agent snapshot
  carrying its config_dir, a `UserDefaultSource` pointer row for
  (installer, workspace, "cc"), and the installer's live Identity slice
  holding the `sandbox.read` cap on the source (the authority the #17 grant
  mint checks). cc's PTY runs in `test_mode` under MIX_ENV=test (SpawnPlan
  `build_pty_params_for_env(:test)`), so the REAL `CcAgent` Template Class —
  including `create_agent_config_dir/2`'s layer-merge + §D6 secret-only
  copy — executes without a real `claude` sidecar.
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

  defp live_session(n) do
    session_uri = Ezagent.URI.session("system", "generic", "cred-inherit-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: Session.behaviors()})

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

  test "adopted-pointer installer: socialware cc role inherits the installer's credentials via the #17 cascade",
       %{
         n: n,
         installer_uri: installer_uri,
         source_uri: source_uri,
         fake_token: fake_token,
         project_cwd: project_cwd
       } do
    session_uri = live_session(n)
    recipe_name = seed_recipe(n, project_cwd)
    role_name = "cred-inherit-role-#{n}"

    assert {:ok, %{satisfied: [^role_name], skipped: []}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               installer_uri,
               [%{recipe: recipe_name, role_name: role_name, flavor: "cc"}]
             )

    members = members_of(session_uri)
    agent_uri = SessionBehavior.role_name_to_uri(members, role_name)
    assert %URI{} = agent_uri
    on_exit(fn -> terminate(agent_uri) end)

    config_dir = CcAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(config_dir) end)

    # THE invariant: the materialized agent's config_dir carries the
    # INSTALLER-sourced credential (the fake token minted in setup) — i.e. the
    # cc TUI would be logged in, not "Not logged in".
    creds_path = Path.join(config_dir, ".credentials.json")

    assert File.exists?(creds_path),
           "materialized cc agent has NO credentials in its config_dir " <>
             "(#{config_dir}) — the socialware materialization path did not " <>
             "flow through the #17 credential cascade with the installer as owner"

    assert File.read!(creds_path) == fake_token

    # §D6: the source's CONFIG files must NOT be pulled (secret-only copy).
    refute File.read(Path.join(config_dir, "settings.json")) == {:ok, "INSTALLER-SETTINGS"}

    # The cascade minted a durable grant: installer → THIS agent, for THE
    # installer's source (audit trail; no ad-hoc copy).
    assert %GrantRow{} = row = GrantRow.get_for_agent(URI.to_string(agent_uri))
    assert row.credential_source_uri == URI.to_string(source_uri)
    assert row.approved_by == URI.to_string(installer_uri)
  end

  # ── #1201 A② — the INVARIANT this branch exists for ──────────────────────
  #
  # A HOST-OPERATOR installer with NO adopted #17 pointer (the fresh-node
  # production state) installs a socialware with a cc role. On unfixed main the
  # agent materializes with an isolated but EMPTY config home ("Not logged in");
  # with the fix, the framework auto-adopts the installer's HOST login (here a
  # self-minted fake behind CLAUDE_CONFIG_DIR) and the agent's config_dir
  # carries the installer-sourced credential via the unchanged cascade.
  describe "host-operator installer without an adopted pointer (fresh-node state)" do
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

    test "cc role materialized by the host operator inherits the HOST login (fails on unfixed main)",
         %{n: n, project_cwd: project_cwd, host_token: host_token, admin_uri: admin_uri} do
      ws_name = Ezagent.URI.workspace_name!(@workspace_uri)
      default_source_id = UserDefaultSource.id(URI.to_string(admin_uri), ws_name, "cc")

      case Repo.get(UserDefaultSource, default_source_id) do
        nil -> :ok
        row -> Repo.delete!(row)
      end

      assert UserDefaultSource.resolve(URI.to_string(admin_uri), ws_name, "cc") == nil

      session_uri = live_session("host-#{n}")
      recipe_name = seed_recipe("host-#{n}", project_cwd)
      role_name = "host-inherit-role-#{n}"

      assert {:ok, %{satisfied: [^role_name], skipped: []}} =
               DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 @workspace_uri,
                 admin_uri,
                 [%{recipe: recipe_name, role_name: role_name, flavor: "cc"}]
               )

      members = members_of(session_uri)
      agent_uri = SessionBehavior.role_name_to_uri(members, role_name)
      assert %URI{} = agent_uri
      on_exit(fn -> terminate(agent_uri) end)

      config_dir = CcAgent.agent_config_dir(agent_uri)
      on_exit(fn -> File.rm_rf(config_dir) end)

      creds_path = Path.join(config_dir, ".credentials.json")

      assert File.exists?(creds_path),
             "materialized cc agent has NO credentials in its config_dir " <>
               "(#{config_dir}) — the installer's host login was not inherited " <>
               "(#1201 A②: TUI shows \"Not logged in\")"

      assert File.read!(creds_path) == host_token

      # §D6 secret-only copy still holds for the host-login source.
      refute File.read(Path.join(config_dir, "settings.json")) == {:ok, "HOST-SETTINGS"}

      # The inheritance ran through the EXISTING cascade: a durable pointer to
      # the registered host-login source + a per-agent grant approved by the
      # installer — never an ad-hoc copy.
      expected_source =
        Ezagent.Agent.HostLoginAdopt.host_login_source_uri(ws_name, "cc")

      assert UserDefaultSource.resolve(URI.to_string(admin_uri), ws_name, "cc") ==
               URI.to_string(expected_source)

      assert %GrantRow{} = row = GrantRow.get_for_agent(URI.to_string(agent_uri))
      assert row.credential_source_uri == URI.to_string(expected_source)
      assert row.approved_by == URI.to_string(admin_uri)
    end

    test "a NON-operator installer without a pointer does NOT inherit the host login (security)",
         %{n: n, project_cwd: project_cwd} do
      ws_name = Ezagent.URI.workspace_name!(@workspace_uri)

      # A co-tenant member, live, no pointer, no cap on anything host-related.
      other_uri = URI.new!("entity://system/user/co-tenant-#{n}")
      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: other_uri, initial_caps: MapSet.new()})
      on_exit(fn -> terminate(other_uri) end)

      session_uri = live_session("other-#{n}")
      recipe_name = seed_recipe("other-#{n}", project_cwd)
      role_name = "no-host-inherit-role-#{n}"

      # Chain C: non-operator installers get no credential source, so the cc role
      # is SKIPPED rather than materialized as a credential-less zombie (#161/DoD 6).
      # Before chain C the agent was created (successfully) but with NO credentials.
      assert {:ok,
              %{
                satisfied: [],
                skipped: [%{role_name: ^role_name, reason: {:no_credential_source, "cc"}}]
              }} =
               DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 @workspace_uri,
                 other_uri,
                 [%{recipe: recipe_name, role_name: role_name, flavor: "cc"}]
               )

      members = members_of(session_uri)
      assert SessionBehavior.role_name_to_uri(members, role_name) == nil

      # The HOST login must NOT flow to an agent a co-tenant caused to exist
      # (#161 / DoD 6): no credential file, no auto-created pointer, no grant.
      assert UserDefaultSource.resolve(URI.to_string(other_uri), ws_name, "cc") == nil
    end
  end

  defp members_of(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    Map.get(slice, :members, %{})
  end
end
