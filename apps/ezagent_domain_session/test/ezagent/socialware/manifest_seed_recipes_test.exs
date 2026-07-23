defmodule Ezagent.Socialware.ManifestSeedRecipesTest do
  @moduledoc """
  Task 1 — sw 自带脑 recipe:一个 socialware 部署包同目录带 `recipes.yaml`,
  `ManifestSeed.scan_dir!/2` 在发布 manifest **之前** 先把这些 data-role recipe
  注册进 `RecipeRegistry`,故 manifest 里以 name-ref 引用它们的 role slot 能解析
  (conformance 通过)。这把"脑配方"从 plugin 代码搬进 sw seed 数据(plugin 只留
  board 工具)。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Socialware.{DefinitionRegistry, ManifestSeed}

  @workspace Ezagent.URI.workspace(:system)

  # 自带最小 fixture 插件/视图/行为,让 demo manifest 走 uses/views/flavor 的
  # known-good 路径(不依赖别的测试文件),只把"recipe 从哪来"换成同目录 recipes.yaml。
  defmodule RenderBehavior do
    @moduledoc false
    use Ezagent.Lifecycle

    @impl Ezagent.ActionSet
    def actions, do: [:seed_recipes_render]

    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:seed_recipes_render, "seed recipes render"}]

    @impl Ezagent.ActionSet
    def dispatchable?, do: false

    @impl Ezagent.ActionSet
    def interface, do: %{}

    @impl Ezagent.ActionSet
    def required_caps,
      do: %{
        seed_recipes_render: Ezagent.Capability.cap(:session, __MODULE__, :seed_recipes_render)
      }

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  defmodule PageView do
    @moduledoc false
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :seed_recipes_page

    @impl true
    def label, do: "Seed"

    @impl true
    def icon, do: "file-code"

    @impl true
    def applies_to?(_), do: true

    @impl true
    def render(assigns) do
      ~H"""
      <div>seed</div>
      """
    end

    @impl true
    def view_behavior, do: RenderBehavior
  end

  defmodule FixturePlugin do
    @moduledoc false

    def plugin_info do
      %{
        slug: "manifest-seed-recipes-fixture",
        name: "Manifest Seed Recipes Fixture",
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
        :seed_recipes_render,
        RenderBehavior
      )

    on_exit(fn -> Ezagent.PluginRegistry.unregister("manifest-seed-recipes-fixture") end)
    :ok
  end

  @tag :integration
  test "sw seed 目录的 recipes.yaml 在 manifest 发布前被注册,且 manifest 引用可解析" do
    root = tmp_root()
    brain = "demo-brain-#{uniq()}"
    name = "demo-team-#{uniq()}"

    # 该 recipe 尚未在 RecipeRegistry 里(证明是 recipes.yaml seed 注册的,不是别处)。
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), brain)
    assert :error = RecipeRegistry.lookup(brain)

    dir = Path.join(root, "demo-team")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "recipes.yaml"), """
    recipes:
      - name: #{brain}
        skills:
          - demo-skill
        prompt: |
          你是 demo-team 的脑。
          第二行确认多行 prompt。
    """)

    File.write!(Path.join(dir, "manifest.yaml"), """
    name: #{name}
    uses:
      - manifest-seed-recipes-fixture
    bases:
      - Ezagent.ActionSet.Session
    views:
      - seed_recipes_page
    roles:
      - role_name: brain
        fill: agent
        recipe: #{brain}
        flavor: py
    visibility_policy:
      scope: private
      publish_policy: auto
      web_anon_access: false
    """)

    assert [%{name: ^name, result: :published}] = ManifestSeed.scan_dir!(root)

    # ① recipes.yaml 的脑被注册,name-ref 可解析(prompt 多行完整搬进)。
    assert {:ok, %{name: ^brain, skills: ["demo-skill"], prompt: prompt}} =
             RecipeRegistry.lookup(@workspace, brain)

    assert prompt =~ "第二行确认多行 prompt。"

    # ② manifest 发布成功(role slot 引用的 recipe 已在发布前解析)。
    assert {:ok, %{}, _object} = DefinitionRegistry.lookup(@workspace, name)
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "manifest-seed-recipes-#{uniq()}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp uniq, do: System.unique_integer([:positive])
end
