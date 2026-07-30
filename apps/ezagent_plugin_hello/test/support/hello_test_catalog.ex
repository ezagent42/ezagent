defmodule EzagentPluginHello.TestCatalog do
  @moduledoc false

  alias Ezagent.Socialware.{DefinitionRegistry, Demo, ManifestSeed}

  @spec import!() :: :ok
  def import! do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    {:ok, %{name: "hello"}} =
      ManifestSeed.import_package(File.read!(Demo.Hello.manifest_path()))

    {:ok, _definition, _revision} =
      DefinitionRegistry.lookup(Ezagent.URI.workspace(:system), "hello")

    :ok
  end
end
