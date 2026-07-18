defmodule Ezagent.Socialware.ManifestImportPackageTest do
  @moduledoc """
  D5 正路 RPC 导入的节点内入口 `ManifestSeed.import_package/2`:喂 YAML 字节,
  走与 boot-scan 完全相同的 parse → resolve → conformance → governed
  `publish_or_upgrade` 链 —— recipes 字节先行 seed,manifest 后发布,重复导入
  幂等(`:exists`)。这是 `mix ezagent.socialware.import_remote` erpc 的目标函数。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{DefinitionRegistry, ManifestSeed}

  @workspace Ezagent.URI.workspace(:system)

  defmodule RenderBehavior do
    @moduledoc false
    use Ezagent.Lifecycle

    @impl Ezagent.ActionSet
    def actions, do: [:import_package_render]

    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:import_package_render, "import package render"}]

    @impl Ezagent.ActionSet
    def dispatchable?, do: false

    @impl Ezagent.ActionSet
    def interface, do: %{}

    @impl Ezagent.ActionSet
    def required_caps,
      do: %{
        import_package_render:
          Ezagent.Capability.cap(:session, __MODULE__, :import_package_render)
      }

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  defmodule PageView do
    @moduledoc false
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :import_package_page

    @impl true
    def label, do: "ImportPkg"

    @impl true
    def icon, do: "file-code"

    @impl true
    def applies_to?(_), do: true

    @impl true
    def render(assigns) do
      ~H"""
      <div>import-package</div>
      """
    end

    @impl true
    def view_behavior, do: RenderBehavior
  end

  defmodule FixturePlugin do
    @moduledoc false

    def plugin_info do
      %{
        slug: "manifest-import-package-fixture",
        name: "Manifest ImportPackage Fixture",
        description: "Fixture plugin",
        version: "0.1.0"
      }
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_native)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

    Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(PageView)
    :ok = Ezagent.PluginRegistry.register(FixturePlugin)

    :ok =
      Ezagent.CapabilityRegistry.register(
        Ezagent.Entity.Session,
        :import_package_render,
        RenderBehavior
      )

    on_exit(fn -> Ezagent.PluginRegistry.unregister("manifest-import-package-fixture") end)
    :ok
  end

  @tag :integration
  test "字节导入:recipes 先 seed → manifest 治理链发布 → 重复导入幂等 :exists" do
    brain = "pkg-brain-#{uniq()}"
    name = "pkg-team-#{uniq()}"

    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), brain)
    assert :error = RecipeRegistry.lookup(brain)

    recipes_yaml = """
    recipes:
      - name: #{brain}
        skills:
          - pkg-skill
        prompt: |
          你是 pkg-team 的脑。
    """

    manifest_yaml = """
    name: #{name}
    uses:
      - manifest-import-package-fixture
    bases:
      - Ezagent.ActionSet.Session
    views:
      - import_package_page
    roles:
      - role_name: brain
        fill: agent
        recipe: #{brain}
        flavor: py
    visibility_policy:
      scope: private
      publish_policy: auto
      web_anon_access: false
    """

    # ① 首次导入:发布成功,recipes 已先行注册(否则 role name-ref 解析不了)。
    assert {:ok, %{name: ^name, result: :published}} =
             ManifestSeed.import_package(manifest_yaml, recipes_yaml)

    assert {:ok, %{name: ^brain, skills: ["pkg-skill"]}} =
             RecipeRegistry.lookup(@workspace, brain)

    assert {:ok, %{}, _object} = DefinitionRegistry.lookup(@workspace, name)

    # ② 同字节重复导入:publish_or_upgrade 幂等语义。
    assert {:ok, %{name: ^name, result: :exists}} =
             ManifestSeed.import_package(manifest_yaml, recipes_yaml)
  end

  test "manifest 缺 name → {:error, {nil, {:invalid_manifest_seed, _}}}" do
    assert {:error, {nil, {:invalid_manifest_seed, nil}}} =
             ManifestSeed.import_package("version: 1\n")
  end

  test "recipes 字节非 recipes: 列表 → fail-loud raise(boot 同策)" do
    assert_raise RuntimeError, ~r/top-level `recipes:` list/, fn ->
      ManifestSeed.import_package("name: x\n", "nope: []\n")
    end
  end

  defp uniq, do: System.unique_integer([:positive])
end
