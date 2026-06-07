defmodule EzagentPluginLiveview.TemplateDiffLive do
  @moduledoc """
  Template Update Diff — shows upstream template changes and allows merge.

  Compares tenant slot_values against parent system template defaults.
  Shows added, removed, and changed slots. Admin can accept/merge individually.
  """
  use Phoenix.LiveView
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    template_uri = socket.assigns[:template_uri]

    if template_uri do
      {:ok,
       socket
       |> assign(:section, :diff)
       |> assign(:loading, true)
       |> assign(:diffs, [])
       |> assign(:template_uri, template_uri)
       |> assign(:flash_msg, nil)
       |> load_diff(template_uri)}
    else
      {:ok,
       socket
       |> assign(:loading, false)
       |> assign(:diffs, [])
       |> assign(:flash_msg, "No template URI in assigns")}
    end
  end

  defp load_diff(socket, template_uri) do
    # 1. Read tenant template content
    tenant_values = fetch_slot_values(template_uri)

    # 2. Read parent system template
    parent_uri = fetch_parent_uri(template_uri)
    system_values = fetch_slot_values(parent_uri)

    # 3. Compute diff
    diffs = compute_diff(tenant_values, system_values)

    assign(socket, loading: false, diffs: diffs)
  end

  @impl true
  def handle_event("accept", %{"key" => key, "value" => value}, socket) do
    template_uri = socket.assigns[:template_uri]
    current = fetch_slot_values(template_uri)
    updated = Map.put(current, key, value)

    case write_slot_values(template_uri, updated) do
      :ok ->
        {:noreply,
         socket
         |> assign(:flash_msg, "Accepted: #{key}")
         |> load_diff(template_uri)}

      {:error, reason} ->
        Logger.warning("TemplateDiff accept failed: #{inspect(reason)}")
        {:noreply, assign(socket, :flash_msg, "Accept failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <header class="px-4 py-3 border-b bg-white shrink-0">
        <h1 class="text-sm font-semibold text-gray-800">Template Update</h1>
        <p class="text-xs text-gray-400 mt-0.5">
          Upstream template has changed. Review and accept changes below.
        </p>
      </header>

      <div :if={@loading} class="p-4 text-sm text-gray-400">Loading...</div>

      <div :if={!@loading} class="flex-1 overflow-y-auto p-4 space-y-4">
        <p :if={@diffs == []} class="text-sm text-gray-400 text-center mt-8">
          No differences found. Your template is up to date.
        </p>

        <%= for diff <- @diffs do %>
          <div class={[
            "border rounded-lg p-4",
            diff_kind_class(diff.kind)
          ]}>
            <div class="flex items-center justify-between">
              <div>
                <span class="text-xs text-gray-400">{diff_kind_label(diff.kind)}</span>
                <span class="text-sm font-mono text-gray-700 ml-2">{diff.key}</span>
              </div>
              <button
                :if={diff.kind != :unchanged}
                phx-click="accept"
                phx-value-key={diff.key}
                phx-value-value={diff.system_value}
                class="rounded-md bg-blue-600 text-white px-2 py-1 text-xs font-medium hover:bg-blue-700"
              >
                Accept System Value
              </button>
            </div>
            <div class="mt-2 grid grid-cols-2 gap-4 text-xs">
              <div>
                <span class="text-gray-400">Your value:</span>
                <pre class="mt-0.5 text-gray-700 whitespace-pre-wrap">{diff.tenant_value || "(empty)"}</pre>
              </div>
              <div>
                <span class="text-gray-400">System value:</span>
                <pre class="mt-0.5 text-gray-700 whitespace-pre-wrap">{diff.system_value || "(empty)"}</pre>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <p :if={@flash_msg} class="px-4 py-2 text-xs text-gray-500 border-t bg-gray-50">
        {@flash_msg}
      </p>
    </div>
    """
  end

  # --- helpers ---

  defp compute_diff(tenant_values, system_values) do
    all_keys = MapSet.union(Map.keys(tenant_values), Map.keys(system_values))

    Enum.map(all_keys, fn key ->
      tenant = Map.get(tenant_values, key)
      system = Map.get(system_values, key)

      kind =
        cond do
          is_nil(tenant) and not is_nil(system) -> :added
          is_nil(system) and not is_nil(tenant) -> :removed
          tenant != system -> :changed
          true -> :unchanged
        end

      %{
        key: key,
        kind: kind,
        tenant_value: to_string(tenant),
        system_value: to_string(system)
      }
    end)
    |> Enum.reject(&(&1.kind == :unchanged))
  end

  defp fetch_slot_values(nil), do: %{}
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

  defp fetch_parent_uri(template_uri) do
    target = Ezagent.URI.with_action(template_uri, :template, :read)

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{caller: template_uri, caps: [], reply: {:caller_inbox, self()}}
         }) do
      {:ok, %{content: %{parent_template_uri: parent}}} when not is_nil(parent) ->
        parent

      {:ok, content} when is_map(content) ->
        Map.get(content, :parent_template_uri)

      _ ->
        nil
    end
  end

  defp write_slot_values(template_uri, slot_values) do
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
    end
  end

  defp diff_kind_class(:added), do: "bg-green-50 border-green-200"
  defp diff_kind_class(:removed), do: "bg-red-50 border-red-200"
  defp diff_kind_class(:changed), do: "bg-yellow-50 border-yellow-200"
  defp diff_kind_class(_), do: "bg-gray-50 border-gray-200"

  defp diff_kind_label(:added), do: "+ Added"
  defp diff_kind_label(:removed), do: "- Removed"
  defp diff_kind_label(:changed), do: "~ Changed"
  defp diff_kind_label(_), do: ""
end
