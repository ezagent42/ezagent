defmodule Ezagent.Socialware.ManifestSeedFixturePageView do
  @moduledoc false

  def id, do: :manifest_seed_yaml_page

  def label, do: "YAML"

  def icon, do: "file-code"

  def applies_to?(_), do: true

  def render(_assigns), do: nil

  def view_behavior, do: Ezagent.Socialware.ManifestSeedFixtureBehavior
end
