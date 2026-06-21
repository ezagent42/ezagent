defmodule EzagentPluginWorld.Layouts do
  @moduledoc """
  Minimal layout wrapper for the `world` LiveView shell.

  This module intentionally stays inside the plugin so `ezagent_web` can depend
  on the plugin for routing without creating a compile cycle back to
  `EzagentWeb.Layouts`.
  """

  use Phoenix.Component

  attr(:flash, :map, required: true)
  slot(:inner_block, required: true)

  @doc false
  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#f8fafc] text-[#111827]">
      {render_slot(@inner_block)}
      <div id="world-flash" aria-live="polite" class="sr-only">
        <p :for={{kind, message} <- @flash} data-kind={kind}>{message}</p>
      </div>
    </div>
    """
  end
end
