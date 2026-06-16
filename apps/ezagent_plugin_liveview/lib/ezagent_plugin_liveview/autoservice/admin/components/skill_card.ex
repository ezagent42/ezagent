defmodule EzagentPluginLiveview.AutoService.Admin.Components.SkillCard do
  @moduledoc "Reusable skill card component for the 4-layer skill grid."
  use Phoenix.Component

  attr(:name, :string, required: true)
  attr(:layer, :atom, required: true)
  attr(:description, :string, default: "")
  attr(:safety_class, :string, default: "safe")
  attr(:shadowed, :boolean, default: false)
  attr(:editable, :boolean, default: false)

  def skill_card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border p-3 transition hover:shadow-md",
      @shadowed && "opacity-50 bg-gray-50",
      @editable && "border-blue-300 cursor-pointer",
      !@editable && "cursor-default"
    ]}>
      <div class="flex justify-between items-start">
        <span class="font-mono text-sm font-medium">{@name}</span>
        <span class={[
          "text-[10px] px-1.5 py-0.5 rounded",
          @safety_class == "critical" && "bg-red-100 text-red-700",
          @safety_class == "safe" && "bg-green-100 text-green-800"
        ]}>
          {@safety_class}
        </span>
      </div>
      <div class="flex items-center gap-2 mt-1">
        <span class="text-[10px] bg-gray-100 px-1.5 py-0.5 rounded text-gray-500">
          L{layer_num(@layer)}
        </span>
        <%= if @shadowed do %>
          <span class="text-[10px] text-amber-600">overridden</span>
        <% end %>
      </div>
      <%= if @description != "" do %>
        <p class="text-xs text-gray-500 mt-1 line-clamp-2">{@description}</p>
      <% end %>
    </div>
    """
  end

  defp layer_num(:l0), do: "0"
  defp layer_num(:l1), do: "1"
  defp layer_num(:l2), do: "2"
  defp layer_num(:l3), do: "3"
end
