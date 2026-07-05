defmodule Ezagent.Socialware.ManifestResolverTest do
  use ExUnit.Case, async: false

  alias Ezagent.Socialware.{Definition, ManifestResolver}

  defmodule RenderBehavior do
    @moduledoc false
    use Ezagent.Lifecycle

    @impl Ezagent.ActionSet
    def actions, do: [:resolver_render]

    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:resolver_render, "resolver render"}]

    @impl Ezagent.ActionSet
    def dispatchable?, do: false

    @impl Ezagent.ActionSet
    def interface, do: %{}

    @impl Ezagent.ActionSet
    def required_caps,
      do: %{resolver_render: Ezagent.Capability.cap(:session, __MODULE__, :resolver_render)}

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  defmodule PageView do
    @moduledoc false
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    @impl true
    def id, do: :resolver_page

    @impl true
    def label, do: "Resolver"

    @impl true
    def icon, do: "panel-top"

    @impl true
    def applies_to?(_), do: true

    @impl true
    def render(assigns) do
      assigns = assign_new(assigns, :text, fn -> "" end)

      ~H"""
      <div>{@text}</div>
      """
    end

    @impl true
    def view_behavior, do: RenderBehavior
  end

  defmodule FixturePlugin do
    @moduledoc false
    def plugin_info do
      %{
        slug: "resolver-fixture",
        name: "Resolver Fixture",
        description: "Fixture plugin",
        version: "0.1.0"
      }
    end
  end

  setup do
    Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(PageView)
    :ok = Ezagent.PluginRegistry.register(FixturePlugin)
    on_exit(fn -> Ezagent.PluginRegistry.unregister("resolver-fixture") end)
    :ok
  end

  test "resolves name-authored manifest view refs to Definition modules" do
    assert {:ok, %Definition{} = definition} =
             ManifestResolver.resolve(%{
               name: "manifest-resolver",
               uses: ["resolver-fixture"],
               views: ["resolver_page"],
               roles: [%{role_name: "guide", fill: :agent, recipe: "guide", flavor: "curl"}]
             })

    assert definition.views == [RenderBehavior]
    assert definition.uses == ["resolver-fixture"]
  end

  test "fails closed when a used plugin is not installed" do
    assert {:error, {:missing_socialware_plugins, ["missing-plugin"]}} =
             ManifestResolver.resolve(%{
               name: "manifest-resolver",
               uses: ["missing-plugin"],
               views: ["resolver_page"]
             })
  end

  test "code-authored and name-authored definitions converge" do
    assert {:ok, code_authored} =
             Definition.new(%{
               name: "manifest-resolver",
               uses: ["resolver-fixture"],
               views: [RenderBehavior]
             })

    assert {:ok, name_authored} =
             ManifestResolver.resolve(%{
               name: "manifest-resolver",
               uses: ["resolver-fixture"],
               views: ["resolver_render"]
             })

    assert name_authored == code_authored
  end
end
