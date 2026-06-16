defmodule EzagentPluginLiveview.AutoService.Admin.Components.SoulDiffView do
  use Phoenix.Component

  attr :diff, :map, required: true

  def soul_diff_view(assigns) do
    ~H"""
    <div class="space-y-2 text-xs font-mono p-4">
      <div :for={line <- @diff.removed} class="text-red-700 dark:text-red-300 bg-red-50 dark:bg-red-950 rounded px-2 py-0.5">
        - <%= line %>
      </div>
      <div :for={line <- @diff.added} class="text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950 rounded px-2 py-0.5">
        + <%= line %>
      </div>
    </div>
    """
  end
end
