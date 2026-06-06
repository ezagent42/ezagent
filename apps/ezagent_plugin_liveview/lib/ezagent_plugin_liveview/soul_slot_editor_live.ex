defmodule EzagentPluginLiveview.SoulSlotEditorLive do
  @moduledoc """
  Soul slot editor — tenant admin fills slot values for their bot.

  Reads the AgentTemplate content via dispatch, parses the soul template
  file for {{key}} placeholders, and renders a form grouped by section.
  """
  use Phoenix.LiveView
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  alias EzagentPluginAutoservice.CinnoxAssets

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    template_uri = socket.assigns[:template_uri]

    if template_uri do
      {:ok,
       socket
       |> assign(:section, :soul)
       |> assign(:loading, true)
       |> assign(:slots, [])
       |> assign(:slot_values, %{})
       |> assign(:flash_msg, nil)
       |> load_slot_data(template_uri)}
    else
      {:ok,
       socket
       |> assign(:loading, false)
       |> assign(:slots, [])
       |> assign(:slot_values, %{})
       |> assign(:flash_msg, "No template URI in assigns")}
    end
  end

  defp load_slot_data(socket, template_uri) do
    # 1. Read current slot_values from AgentTemplate slice
    slot_values = fetch_slot_values(template_uri)

    # 2. Parse {{key}} placeholders from soul template
    slots = parse_template_slots(template_uri)

    socket
    |> assign(:loading, false)
    |> assign(:slots, slots)
    |> assign(:slot_values, slot_values)
  end

  @impl true
  def handle_event("save", %{"slots" => slot_params}, socket) do
    template_uri = socket.assigns[:template_uri]
    new_values = build_slot_values(slot_params, socket.assigns.slot_values)

    case write_slot_values(template_uri, new_values) do
      :ok ->
        {:noreply,
         socket
         |> assign(:slot_values, new_values)
         |> assign(:flash_msg, "Saved. Agent must be re-spawned to apply changes.")}

      {:error, reason} ->
        Logger.warning("SoulSlotEditor save failed: #{inspect(reason)}")
        {:noreply, assign(socket, :flash_msg, "Save failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <header class="px-4 py-3 border-b bg-white flex items-center justify-between shrink-0">
        <h1 class="text-sm font-semibold text-gray-800">Soul Slot Editor</h1>
        <div class="flex items-center gap-3">
          <p :if={@flash_msg} class="text-xs text-gray-500">{@flash_msg}</p>
          <button
            phx-click="save"
            phx-value-slots={Jason.encode!(@slot_values)}
            class="rounded-lg bg-blue-600 text-white px-3 py-1.5 text-xs font-medium hover:bg-blue-700"
          >
            Save
          </button>
        </div>
      </header>

      <div :if={@loading} class="p-4 text-sm text-gray-400">Loading...</div>

      <form :if={!@loading} phx-change="update_slot" class="flex-1 overflow-y-auto p-4 space-y-6">
        <%= for {section, section_slots} <- Enum.group_by(@slots, & &1.section, & &1) do %>
          <fieldset class="border border-gray-200 rounded-lg p-4">
            <legend class="text-sm font-medium text-gray-700 px-1">
              {String.capitalize(section)}
            </legend>
            <div class="space-y-3 mt-2">
              <%= for slot <- section_slots do %>
                <div>
                  <label class="block text-xs text-gray-500 mb-1">
                    {slot.display_key}
                  </label>
                  <input
                    type="text"
                    name={"slots[#{slot.key}]"}
                    value={Map.get(@slot_values, slot.key, "")}
                    class="w-full rounded-md border border-gray-300 px-3 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                </div>
              <% end %>
            </div>
          </fieldset>
        <% end %>
      </form>
    </div>
    """
  end

  # --- helpers ---

  defp fetch_slot_values(template_uri) do
    target = Ezagent.URI.with_action(template_uri, :template, :read)

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{caller: template_uri, caps: [], reply: {:caller_inbox, self()}}
         }) do
      {:ok, %{content: %{soul_slot_values: values}}} when is_map(values) ->
        values

      {:ok, content} when is_map(content) ->
        Map.get(content, :soul_slot_values, %{}) || %{}

      _ ->
        %{}
    end
  end

  defp parse_template_slots(_template_uri) do
    # Parse {{key}} from soul template file
    soul_path = CinnoxAssets.soul_path()
    template = File.read!(soul_path)

    Regex.scan(~r/\{\{([a-z][a-z0-9_.-]*)\}\}/, template)
    |> Enum.map(fn [full, key] ->
      section = key |> String.split(".") |> List.first() || "other"

      %{
        key: key,
        display_key: String.replace(key, "#{section}.", ""),
        section: section,
        raw: full
      }
    end)
  end

  defp build_slot_values(params, current) do
    Map.new(params, fn {key, value} -> {key, value} end)
    |> then(fn new ->
      Map.merge(current || %{}, new)
    end)
  end

  defp write_slot_values(template_uri, slot_values) do
    # Read full content first to preserve other fields
    target_read = Ezagent.URI.with_action(template_uri, :template, :read)
    ctx = %{caller: template_uri, caps: [], reply: {:caller_inbox, self()}}

    with {:ok, %{content: content}} when is_map(content) <-
           Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target_read,
             mode: :call,
             args: %{},
             ctx: ctx
           }) do
      new_content = Map.put(content, :soul_slot_values, slot_values)

      target_write = Ezagent.URI.with_action(template_uri, :template, :write)

      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target_write,
             mode: :call,
             args: %{content: new_content},
             ctx: ctx
           }) do
        {:ok, _} -> :ok
        :ok -> :ok
        other -> {:error, other}
      end
    else
      {:ok, content} when is_map(content) ->
        new_content = Map.put(content, :soul_slot_values, slot_values)

        target_write = Ezagent.URI.with_action(template_uri, :template, :write)

        case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
               target: target_write,
               mode: :call,
               args: %{content: new_content},
               ctx: ctx
             }) do
          {:ok, _} -> :ok
          :ok -> :ok
          other -> {:error, other}
        end

      other ->
        {:error, {:read_failed, other}}
    end
  end
end
