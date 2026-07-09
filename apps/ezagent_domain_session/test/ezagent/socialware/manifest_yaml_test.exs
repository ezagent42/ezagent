defmodule Ezagent.Socialware.ManifestYamlTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ConfigGovernance.Socialware, as: Governance
  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.Invocation
  alias Ezagent.Message

  alias Ezagent.Socialware.{
    Conformance,
    Definition,
    DefinitionRegistry,
    Installation,
    ManifestYaml
  }

  defmodule RenderBehavior do
    @moduledoc false
    use Ezagent.Lifecycle

    @impl Ezagent.ActionSet
    def actions, do: [:yaml_render]

    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:yaml_render, "yaml render"}]

    @impl Ezagent.ActionSet
    def dispatchable?, do: false

    @impl Ezagent.ActionSet
    def interface, do: %{}

    @impl Ezagent.ActionSet
    def required_caps,
      do: %{yaml_render: Ezagent.Capability.cap(:session, __MODULE__, :yaml_render)}

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  defmodule PageView do
    @moduledoc false
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :yaml_page

    @impl true
    def label, do: "YAML"

    @impl true
    def icon, do: "file-code"

    @impl true
    def applies_to?(_), do: true

    @impl true
    def render(assigns) do
      ~H"""
      <div>yaml</div>
      """
    end

    @impl true
    def view_behavior, do: RenderBehavior
  end

  defmodule FixturePlugin do
    @moduledoc false

    def plugin_info do
      %{
        slug: "manifest-yaml-fixture",
        name: "Manifest YAML Fixture",
        description: "Fixture plugin",
        version: "0.1.0"
      }
    end
  end

  @workspace Ezagent.URI.workspace(:system)
  @admin Ezagent.URI.user(:system, :admin)

  setup do
    Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(PageView)
    :ok = Ezagent.PluginRegistry.register(FixturePlugin)

    :ok =
      Ezagent.CapabilityRegistry.register(
        Ezagent.Entity.Session,
        :yaml_render,
        RenderBehavior
      )

    on_exit(fn -> Ezagent.PluginRegistry.unregister("manifest-yaml-fixture") end)
    :ok
  end

  test "parse maps bases and shape module strings without atom minting" do
    assert {:ok, attrs} = ManifestYaml.parse(valid_yaml("yaml-parse", seed_recipe("parse")))

    assert attrs["bases"] == [Ezagent.ActionSet.Session]
    assert attrs["shape"] == [Ezagent.ActionSet.Turn]
    assert attrs["views"] == ["yaml_page"]
  end

  test "parse fails closed for an unknown bases/shape module string" do
    yaml = """
    name: bad-module
    bases:
      - NoSuch.Module
    """

    assert {:error, {:unknown_module, "NoSuch.Module"}} = ManifestYaml.parse(yaml)
  end

  test "render emits view ids and round-trips through resolve" do
    recipe = seed_recipe("roundtrip")

    {:ok, original} =
      Definition.new(%{
        name: "yaml-roundtrip",
        uses: ["manifest-yaml-fixture"],
        bases: [Ezagent.ActionSet.Session],
        shape: [Ezagent.ActionSet.Turn],
        views: [RenderBehavior],
        roles: [%{role_name: "agent", fill: :agent, recipe: recipe, flavor: "py"}],
        visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
      })

    assert {:ok, yaml} = ManifestYaml.render(original)
    assert yaml =~ ~s("yaml_page")
    refute yaml =~ "ManifestYamlTest.RenderBehavior"

    assert {:ok, attrs} = ManifestYaml.parse(yaml)
    assert {:ok, resolved} = Ezagent.Socialware.ManifestResolver.resolve(attrs)
    assert resolved == original
  end

  test "check_candidate passes an unpublished valid definition while check still fails" do
    recipe = seed_recipe("candidate")

    {:ok, definition} =
      Definition.new(%{
        name: "yaml-candidate-#{uniq()}",
        uses: ["manifest-yaml-fixture"],
        views: [RenderBehavior],
        roles: [%{role_name: "agent", fill: :agent, recipe: recipe, flavor: "py"}]
      })

    assert :ok = Conformance.check_candidate(definition, @workspace)
    assert {:error, failures} = Conformance.check(definition, @workspace)
    assert Enum.any?(failures, &match?({:install_resolves, {:unknown_socialware_install, _}}, &1))
  end

  test "import rejects an unknown recipe at conformance and publishes nothing" do
    name = "yaml-reject-#{uniq()}"

    assert {:error, failures} =
             ManifestYaml.import(valid_yaml(name, "missing-recipe-#{uniq()}"), admin_ctx(name))

    assert Enum.any?(failures, &match?({:agent_recipes_resolve, {:unknown_agent_recipe, _}}, &1))
    assert :error = DefinitionRegistry.lookup(@workspace, name)
  end

  test "import publishes a conformance-clean manifest through governance" do
    name = "yaml-import-#{uniq()}"
    recipe = seed_recipe("import")

    assert {:ok, :published} = ManifestYaml.import(valid_yaml(name, recipe), admin_ctx(name))
    assert {:ok, %Definition{name: ^name}, _object} = DefinitionRegistry.lookup(@workspace, name)
  end

  test "requires manifest imports, publishes, and installs transitive dependencies" do
    dep_name = "yaml-requires-dep-#{uniq()}"
    app_name = "yaml-requires-app-#{uniq()}"
    session_uri = Ezagent.URI.session(:system, :socialware, "yaml-requires-#{uniq()}")

    assert {:ok, :published} = ManifestYaml.import(minimal_yaml(dep_name), admin_ctx(dep_name))

    assert {:ok, :published} =
             ManifestYaml.import(
               minimal_yaml(app_name, requires: [dep_name]),
               admin_ctx(app_name)
             )

    assert :ok =
             Installation.install_template_installs(
               session_uri,
               @workspace,
               %{installs: [app_name]},
               @admin
             )

    assert Installation.installed?(session_uri, dep_name)
    assert Installation.installed?(session_uri, app_name)
  end

  test "autoservice manifest imports, publishes, installs, materializes agents, and routes" do
    :ok = seed_autoservice_recipe()
    yaml = File.read!(autoservice_manifest_path())

    assert {:ok, attrs} = ManifestYaml.parse(yaml)
    assert {:ok, definition} = Ezagent.Socialware.ManifestResolver.resolve(attrs)
    assert :ok = Conformance.check_candidate(definition, @workspace)
    assert {:ok, result} = ManifestYaml.import(yaml, admin_ctx(definition.name))
    assert result in [:published, :exists]

    assert Enum.any?(DefinitionRegistry.list(@workspace), &(&1.name == definition.name))

    assert {:ok, %Definition{name: name}, _object} =
             DefinitionRegistry.lookup(@workspace, definition.name)

    template_name = "autoservice-yaml-#{uniq()}"
    content = %{name: template_name, installs: [name]}
    {:ok, _template_uri} = SessionTemplate.persist_version_as_system(content, "system")

    assert {:ok, session_uri, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "autoservice-yaml-session-#{uniq()}",
               @admin,
               template_name: template_name
             )

    assert %URI{} = role_member_uri(session_uri, "autoservice")
    assert :ok = dispatch_send(session_uri, "I need tier-1 help")
  end

  defp valid_yaml(name, recipe) do
    """
    name: #{name}
    version: "0.1.0"
    title: "Manifest #{name}"
    uses:
      - manifest-yaml-fixture
    bases:
      - Ezagent.ActionSet.Session
    shape:
      - Ezagent.ActionSet.Turn
    views:
      - yaml_page
    roles:
      - role_name: agent
        fill: agent
        recipe: #{recipe}
        flavor: py
    routing_rules:
      - matcher:
          type: always
        receivers:
          - agent
    visibility_policy:
      scope: private
      publish_policy: auto
      web_anon_access: false
    """
  end

  defp minimal_yaml(name, opts \\ []) do
    requires = Keyword.get(opts, :requires, [])

    requires_block =
      if requires == [] do
        ""
      else
        "requires:\n" <> Enum.map_join(requires, "", &"  - #{&1}\n")
      end

    """
    name: #{name}
    version: "0.1.0"
    title: "Minimal #{name}"
    bases:
      - Ezagent.ActionSet.Session
    visibility_policy:
      scope: private
      publish_policy: auto
      web_anon_access: false
    #{requires_block}
    """
  end

  defp seed_recipe(label) do
    name = "yaml-recipe-#{label}-#{uniq()}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        requested_caps: [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}]
      })

    name
  end

  defp seed_autoservice_recipe do
    case RecipeRegistry.seed_role_if_absent(%{name: "autoservice-agent"}) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("autoservice recipe seed failed: #{inspect(reason)}")
    end
  end

  defp autoservice_manifest_path do
    # Deploy-seed SPEC §6: autoservice now ships in the ezagent_web assembly
    # app's socialware_seed source, not domain_session priv.
    :ezagent_web
    |> :code.priv_dir()
    |> Path.join("socialware_seed/autoservice/manifest.yaml")
  end

  defp role_member_uri(session_uri, role_name) do
    {:ok, pid} = Ezagent.KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)

    slice
    |> Map.get(:members, %{})
    |> Ezagent.ActionSet.Session.role_name_to_uri(role_name)
  end

  defp dispatch_send(session_uri, text) do
    msg = Message.new(@admin, %{text: text, attachments: []})

    case Invocation.dispatch(%Invocation{
           target: URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
           mode: :cast,
           args: %{message: msg},
           ctx: %{
             caller: @admin,
             caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
             reply: :ignore
           }
         }) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp admin_ctx(name) do
    %{
      caller: @admin,
      workspace_uri: @workspace,
      caps:
        MapSet.new([
          Governance.manage_cap(name, @workspace, @admin),
          Ezagent.Capability.admin_genesis_cap()
        ])
    }
  end

  defp uniq, do: System.unique_integer([:positive])
end
