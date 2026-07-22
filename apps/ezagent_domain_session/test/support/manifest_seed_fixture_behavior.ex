defmodule Ezagent.Socialware.ManifestSeedFixtureBehavior do
  @moduledoc false
  use Ezagent.Lifecycle

  @impl Ezagent.ActionSet
  def actions, do: [:manifest_seed_yaml_render]

  @impl Ezagent.ActionSet
  def cap_subjects, do: [{:manifest_seed_yaml_render, "manifest seed yaml render"}]

  @impl Ezagent.ActionSet
  def dispatchable?, do: false

  @impl Ezagent.ActionSet
  def interface, do: %{}

  @impl Ezagent.ActionSet
  def required_caps,
    do: %{
      manifest_seed_yaml_render:
        Ezagent.Capability.cap(:session, __MODULE__, :manifest_seed_yaml_render)
    }

  @impl Ezagent.ActionSet
  def data_owner(_), do: :any
end
