defmodule Ezagent.World.TestSupport.LegacyHelloPageView do
  @moduledoc false
  @behaviour Ezagent.UI.SessionView

  use Phoenix.Component

  @impl true
  def id, do: :hello_page

  @impl true
  def label, do: "Legacy page id"

  @impl true
  def icon, do: "panel-top"

  @impl true
  def applies_to?(%URI{}), do: true
  def applies_to?(_), do: false

  @impl true
  def view_behavior, do: nil

  @impl true
  def render(assigns), do: ~H""
end
