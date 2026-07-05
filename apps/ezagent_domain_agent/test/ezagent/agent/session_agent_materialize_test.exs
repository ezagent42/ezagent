defmodule Ezagent.Agent.SessionAgentMaterializeTest do
  @moduledoc """
  Phase 3 ③ T7c — the per-session materialize + grant-landing MECHANISM
  (`Ezagent.Agent.SessionAgentMaterialize`). pm / dev-together go LIVE per-session
  (like the orchestrator), session/workspace-scoped, with their recipe caps landed
  on the live per-session URI.

  This pins the T7c MECHANISM — NOT the live `cc` `claude` brain (a real sidecar
  answering chat is the T7b agent-browser proof). A STUB flavor whose Template
  Class spawns a bare `Entity.Agent` Kind (base behaviors incl. `Behavior.Identity`,
  NO `claude` sidecar) stands in for `cc`, so we can prove:

    * **role-agnostic spawn (P2, Gate B)** — the agent goes live at a fresh uuid
      `entity://<workspace>/agent/<uuid>` (KindRegistry hit); NO role or session
      segment is baked into the identity.
    * **grant landing** — once live, the recipe's least-priv caps land on THAT
      per-agent URI, readable via `Identity.list_caps_for/1` (the T7b
      `:no_such_actor` deferral is closed by materializing first).
    * **role-agnostic identity** — a second materialize mints a DISTINCT fresh
      agent; dedupe is the caller's concern (the session membership edge).

  The credential cascade (owner → per-agent config_dir) is the cc-flavor concern
  proven by T7b; the STUB flavor implements NO `CredentialAdapter`, so the cascade
  is correctly skipped here. What IS pinned: the spawn is fed the SESSION OWNER as
  `spawned_by`/`caller` (the orchestrator credential-supply shape).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.SessionAgentMaterialize
  alias Ezagent.AgentFlavorRegistry

  defmodule StubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "t7c.stub"

    @impl Ezagent.Kind.Template
    def validate(%{"class" => "t7c.stub", "agent_uri" => agent_uri, "cwd" => cwd})
        when is_binary(agent_uri) and is_binary(cwd),
        do: :ok

    def validate(_), do: {:error, :invalid_stub_template}

    # Spawn a bare `Entity.Agent` Kind (base behaviors incl. `Behavior.Identity`)
    # at the requested URI — a LIVE agent the grant can land on, with NO `claude`
    # sidecar. `fresh?: true` on a first spawn (so the materialize outcome is
    # `:created`); `:already_started` → `fresh?: false` for the idempotent re-call.
    @impl Ezagent.Kind.Template
    def instantiate(_name, data, _workspace_uri) do
      uri = Ezagent.URI.new!(data["agent_uri"])

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: uri,
             behaviors: Ezagent.Entity.Agent.base_behaviors()
           }) do
        {:ok, _pid} -> {:ok, [uri], %{fresh?: true}}
        {:error, {:already_started, _pid}} -> {:ok, [uri], %{fresh?: false}}
        {:error, {:already_registered, _}} -> {:ok, [uri], %{fresh?: false}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")
  @session_uri Ezagent.URI.new!("session://default/team-alpha/board-flow")
  @owner_uri Ezagent.URI.new!("entity://team-alpha/user/alice")

  defp uniq, do: System.unique_integer([:positive])

  # A per-test unique kanban-flow session so the derived per-session agent URI
  # (`<role>-<session-disc>`) never collides with another test's live agent.
  defp uniq_session, do: Ezagent.URI.new!("session://default/team-alpha/board-flow-#{uniq()}")

  # Terminate a materialized per-session agent at suite teardown so the live
  # KindRegistry entry doesn't leak into a sibling test.
  defp cleanup(%URI{} = agent_uri), do: on_exit(fn -> _ = Ezagent.Kind.terminate(agent_uri) end)

  defp register_stub_flavor do
    flavor = "t7c_stub_#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: StubTemplate
      })

    flavor
  end

  defp stub_content(flavor, role) do
    %{flavor: flavor, project_cwd: "/tmp/t7c-#{role}", role: role}
  end

  # A recipe over a behavior module that IS loaded in domain_agent (a base
  # behavior on every Agent Kind), so the grant's loaded-check resolves it.
  defp stub_recipe do
    %{
      name: "t7c-role",
      requested_caps: [
        %{behavior: Ezagent.ActionSet.ApiKeys, action: :put_api_key},
        %{behavior: Ezagent.ActionSet.Identity, action: :list_caps}
      ]
    }
  end

  defp telemetry_prefix, do: [:ezagent, :test, :t7c, :materialize]

  defp wait_ready(uri, attempts \\ 200)
  defp wait_ready(_uri, 0), do: flunk("per-session agent never became ready")

  defp wait_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready -> :ok
      _ -> Process.sleep(10) && wait_ready(uri, attempts - 1)
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    :ok
  end

  describe "planned_agent_uri/3 — role-agnostic fresh uuid (P2, Gate B)" do
    test "builds entity://<workspace>/agent/<uuid> — NO role or session segment" do
      uri =
        SessionAgentMaterialize.planned_agent_uri("pm-coordinator", @session_uri, @workspace_uri)

      # role-agnostic: the URI carries neither the role name nor the session disc
      assert URI.to_string(uri) =~ ~r"^entity://team-alpha/agent/[0-9a-f-]{36}$"
      refute URI.to_string(uri) =~ "pm-coordinator"
      refute URI.to_string(uri) =~ "board-flow"
    end

    test "each call mints a distinct fresh uuid (identity is not keyed off role/session)" do
      other = Ezagent.URI.new!("session://default/team-alpha/board-flow-2")

      a = SessionAgentMaterialize.planned_agent_uri("dev-together", @session_uri, @workspace_uri)
      b = SessionAgentMaterialize.planned_agent_uri("dev-together", other, @workspace_uri)

      refute URI.to_string(a) == URI.to_string(b)
      refute URI.to_string(a) =~ "dev-together"
    end
  end

  describe "materialize/1 — per-session spawn goes live at the scoped URI" do
    test "spawns a live agent at the planned session-scoped URI (KindRegistry hit), outcome :created" do
      flavor = register_stub_flavor()
      role = "pm-coordinator"
      session_uri = uniq_session()

      assert {:ok, %URI{} = agent_uri, :created} =
               SessionAgentMaterialize.materialize(%{
                 role: role,
                 session_uri: session_uri,
                 workspace_uri: @workspace_uri,
                 owner_uri: @owner_uri,
                 template_content: stub_content(flavor, role),
                 recipe: stub_recipe(),
                 telemetry_prefix: telemetry_prefix()
               })

      cleanup(agent_uri)

      # the agent went live at a role-agnostic fresh uuid URI (P2, Gate B)
      assert URI.to_string(agent_uri) =~ ~r"^entity://team-alpha/agent/[0-9a-f-]{36}$"
      refute URI.to_string(agent_uri) =~ "pm-coordinator"
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)
    end
  end

  describe "grant landing — recipe caps land on the live per-session URI" do
    test "list_caps_for reads back the recipe caps after materialize" do
      flavor = register_stub_flavor()
      role = "dev-together"

      assert {:ok, agent_uri, :created} =
               SessionAgentMaterialize.materialize(%{
                 role: role,
                 session_uri: uniq_session(),
                 workspace_uri: @workspace_uri,
                 owner_uri: @owner_uri,
                 template_content: stub_content(flavor, role),
                 recipe: stub_recipe(),
                 telemetry_prefix: telemetry_prefix()
               })

      cleanup(agent_uri)
      wait_ready(agent_uri)

      caps = Ezagent.Identity.list_caps_for(agent_uri)

      behaviors = MapSet.new(caps, & &1.behavior)
      assert Ezagent.ActionSet.ApiKeys in behaviors
      assert Ezagent.ActionSet.Identity in behaviors

      # least-priv: granted under the admin entity, scoped to THIS per-session URI.
      assert Enum.all?(caps, fn cap ->
               cap.granted_by == Ezagent.Entity.User.admin_uri()
             end)
    end

    test "no half-state: an unloaded recipe behavior fails LOUD (agent live, caps not granted)" do
      flavor = register_stub_flavor()
      role = "pm-coordinator"

      bogus_recipe = %{
        name: "t7c-role",
        requested_caps: [
          %{behavior: "Ezagent.ActionSet.DefinitelyNotARealBehavior999", action: :nope}
        ]
      }

      assert {:error, {:behavior_not_loaded, _}} =
               SessionAgentMaterialize.materialize(%{
                 role: role,
                 session_uri: uniq_session(),
                 workspace_uri: @workspace_uri,
                 owner_uri: @owner_uri,
                 template_content: stub_content(flavor, role),
                 recipe: bogus_recipe,
                 telemetry_prefix: telemetry_prefix()
               })
    end
  end

  describe "by_role_spec/4 — generic by-role composition (T7d, no plugin compile dep)" do
    alias Ezagent.Agent.{DefaultAgentSeed, RecipeRegistry}

    test "registered role → spec carries the registry recipe + generic cwd + role content" do
      role = "t7d-by-role-#{uniq()}"
      :ok = RecipeRegistry.flush_cache()

      {:ok, :seeded} =
        RecipeRegistry.seed_role_if_absent(%{
          name: role,
          behaviors: [],
          requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}],
          skills: []
        })

      {:ok, %Ezagent.Agent.Recipe{} = registered} = RecipeRegistry.lookup(role)

      assert {:ok, spec} =
               SessionAgentMaterialize.by_role_spec(
                 role,
                 @session_uri,
                 @workspace_uri,
                 @owner_uri
               )

      assert spec.role == role
      # recipe is the registry %Recipe{} — its requested_caps feed GrantRecipeCaps.
      assert spec.recipe == registered
      assert spec.recipe.requested_caps != []
      # generic cwd = the same default both per-plugin seeds derive.
      assert spec.template_content.project_cwd == DefaultAgentSeed.default_project_cwd(role)
      assert spec.template_content.role == role
      assert spec.template_content.flavor == "cc"
    end

    test "registered role + explicit flavor → spec carries that flavor, not the cc seed shortcut" do
      flavor = register_stub_flavor()
      role = "t7d-non-cc-by-role-#{uniq()}"
      :ok = RecipeRegistry.flush_cache()

      {:ok, :seeded} =
        RecipeRegistry.seed_role_if_absent(%{
          name: role,
          behaviors: [],
          requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}],
          skills: []
        })

      assert {:ok, spec} =
               SessionAgentMaterialize.by_role_spec(
                 role,
                 flavor,
                 @session_uri,
                 @workspace_uri,
                 @owner_uri
               )

      assert spec.role == role
      assert spec.template_content.role == role
      assert spec.template_content.flavor == flavor
      assert spec.template_content.project_cwd == DefaultAgentSeed.default_project_cwd(role)
    end

    test "recipe config[:project_cwd] OVERRIDES the generic cwd (T7e CLI-reachability seam)" do
      role = "t7e-cwd-#{uniq()}"
      custom_cwd = "/srv/umbrella-root-#{uniq()}"
      :ok = RecipeRegistry.flush_cache()

      {:ok, :seeded} =
        RecipeRegistry.seed_role_if_absent(%{
          name: role,
          behaviors: [],
          requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}],
          skills: [],
          # the recipe DECLARES its agent's cwd — e.g. the umbrella root so the
          # agent's `mix ezagent` resolves. Round-trips through ConfigStore JSON
          # (atom key → string key), so this also pins the string-key read path.
          config: %{project_cwd: custom_cwd}
        })

      assert {:ok, spec} =
               SessionAgentMaterialize.by_role_spec(
                 role,
                 @session_uri,
                 @workspace_uri,
                 @owner_uri
               )

      # the declared cwd wins over default_project_cwd/1 — and is NOT the default.
      assert spec.template_content.project_cwd == custom_cwd
      refute spec.template_content.project_cwd == DefaultAgentSeed.default_project_cwd(role)
    end

    test "recipe without config[:project_cwd] falls back to the UNCHANGED sandbox default" do
      role = "t7e-default-#{uniq()}"
      :ok = RecipeRegistry.flush_cache()

      {:ok, :seeded} =
        RecipeRegistry.seed_role_if_absent(%{
          name: role,
          behaviors: [],
          requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}],
          skills: []
        })

      assert {:ok, spec} =
               SessionAgentMaterialize.by_role_spec(
                 role,
                 @session_uri,
                 @workspace_uri,
                 @owner_uri
               )

      # default cwd semantics unchanged when the recipe declares no project_cwd.
      assert spec.template_content.project_cwd == DefaultAgentSeed.default_project_cwd(role)
    end

    test "unregistered role → fail-closed {:error, {:role_not_registered, role}}" do
      role = "t7d-absent-#{uniq()}"
      :ok = RecipeRegistry.flush_cache()

      assert {:error, {:role_not_registered, ^role}} =
               SessionAgentMaterialize.by_role_spec(
                 role,
                 @session_uri,
                 @workspace_uri,
                 @owner_uri
               )

      # materialize_by_role/4 surfaces the same fail-closed error (no spawn).
      assert {:error, {:role_not_registered, ^role}} =
               SessionAgentMaterialize.materialize_by_role(
                 role,
                 @session_uri,
                 @workspace_uri,
                 @owner_uri
               )
    end
  end

  describe "role-agnostic identity (P2, Gate B)" do
    # With uuid identity, materialize/1 is no longer idempotent on (role, session):
    # a second call mints a DISTINCT fresh agent. Dedupe is the CALLER's concern,
    # keyed off the (entity × session) membership edge — mirroring the live
    # socialware path `DefinitionAgents.materialize_one/4`, which skips when
    # `existing_member_for_role/2` already holds the role. Identity is never keyed
    # off the role/session anymore.
    test "a second materialize of the same (role, session) mints a DISTINCT fresh agent" do
      flavor = register_stub_flavor()
      role = "pm-coordinator"
      session_uri = uniq_session()

      spec = %{
        role: role,
        session_uri: session_uri,
        workspace_uri: @workspace_uri,
        owner_uri: @owner_uri,
        template_content: stub_content(flavor, role),
        recipe: stub_recipe(),
        telemetry_prefix: telemetry_prefix()
      }

      assert {:ok, agent_uri_1, :created} = SessionAgentMaterialize.materialize(spec)
      cleanup(agent_uri_1)

      assert {:ok, agent_uri_2, :created} = SessionAgentMaterialize.materialize(spec)
      cleanup(agent_uri_2)

      # distinct fresh uuids — no role/session baked into either identity
      refute URI.to_string(agent_uri_1) == URI.to_string(agent_uri_2)
      refute URI.to_string(agent_uri_1) =~ "pm-coordinator"
    end
  end
end
