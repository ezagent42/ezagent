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
      @shadowed && "opacity-50 bg-gray-50 dark:bg-zinc-950",
      @editable && "border-blue-300 dark:border-blue-700 cursor-pointer",
      !@editable && "border-gray-200 dark:border-zinc-800 cursor-default",
      !@shadowed && !@editable && "bg-white dark:bg-zinc-900"
    ]}>
      <div class="flex justify-between items-start">
        <span class="font-mono text-sm font-medium text-gray-900 dark:text-zinc-100">{@name}</span>
        <span class={[
          "text-[10px] px-1.5 py-0.5 rounded",
          @safety_class == "critical" && "bg-red-100 dark:bg-red-950 text-red-700 dark:text-red-300",
          @safety_class == "safe" && "bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-200"
        ]}>
          {@safety_class}
        </span>
      </div>
      <div class="flex items-center gap-2 mt-1">
        <span class="text-[10px] bg-gray-100 dark:bg-zinc-800 px-1.5 py-0.5 rounded text-gray-500 dark:text-zinc-400">
          L{layer_num(@layer)}
        </span>
        <%= if @shadowed do %>
          <span class="text-[10px] text-amber-600 dark:text-amber-400">overridden</span>
        <% end %>
      </div>
      <%= if @description != "" do %>
        <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1 line-clamp-2">{@description}</p>
      <% end %>
    </div>
    """
  end

  @doc """
  Parse YAML frontmatter from skill content.
  Returns `{meta_map, body_string}` where meta is a string-keyed map of YAML fields.
  """
  def parse_skill_frontmatter(content) do
    case String.split(content, "---\n", parts: 3) do
      [_, fm, body] ->
        case YamlElixir.read_from_string(fm) do
          {:ok, meta} -> {meta, String.trim(body)}
          _ -> {%{}, content}
        end
      _ -> {%{}, content}
    end
  end

  defp layer_num(:l0), do: "0"
  defp layer_num(:l1), do: "1"
  defp layer_num(:l2), do: "2"
  defp layer_num(:l3), do: "3"
end
