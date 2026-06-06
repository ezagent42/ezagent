defmodule EzagentPluginLiveview.BotCreatorLive do
  @moduledoc """
  Bot Creator — admin selects a Bot Type, forks to workspace, starts onboarding.

  Lists AgentTemplates from system workspace as available Bot Types.
  Fork → redirect to Soul Slot Editor for onboarding.
  """
  use Phoenix.LiveView
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    workspace_uri = socket.assigns[:current_workspace_uri]

    socket =
      socket
      |> assign(:section, :bots)
      |> assign(:loading, true)
      |> assign(:bot_types, [])
      |> assign(:selected_type, nil)
      |> assign(:new_bot_name, "")
      |> assign(:flash_msg, nil)
      |> assign(:workspace_uri, workspace_uri)

    {:ok, socket |> load_bot_types()}
  end

  defp load_bot_types(socket) do
    bot_types = list_system_templates()
    assign(socket, loading: false, bot_types: bot_types)
  end

  @impl true
  def handle_event("select_type", %{"uri" => uri_str}, socket) do
    {:noreply, assign(socket, selected_type: uri_str, flash_msg: nil)}
  end

  def handle_event("set_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, new_bot_name: String.trim(name))}
  end

  def handle_event("create", _params, socket) do
    type_uri = socket.assigns[:selected_type]
    name = socket.assigns[:new_bot_name]
    workspace = socket.assigns[:workspace_uri]

    cond do
      is_nil(type_uri) ->
        {:noreply, assign(socket, flash_msg: "Please select a Bot Type first.")}

      name == "" ->
        {:noreply, assign(socket, flash_msg: "Please enter a bot name.")}

      true ->
        case fork_bot(type_uri, name, workspace) do
          {:ok, new_uri} ->
            {:noreply,
             socket
             |> assign(:flash_msg, "Created! New bot: #{URI.to_string(new_uri)}")
             |> assign(:selected_type, nil)
             |> assign(:new_bot_name, "")}

          {:error, reason} ->
            Logger.warning("BotCreator fork failed: #{inspect(reason)}")
            {:noreply, assign(socket, flash_msg: "Create failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <header class="px-4 py-3 border-b bg-white shrink-0">
        <h1 class="text-sm font-semibold text-gray-800">Create New Bot</h1>
        <p class="text-xs text-gray-400 mt-0.5">
          Workspace: {workspace_label(@workspace_uri)}
        </p>
      </header>

      <div :if={@loading} class="p-4 text-sm text-gray-400">Loading...</div>

      <div :if={!@loading} class="flex-1 overflow-y-auto p-4 space-y-4">
        <!-- Bot Type Selection -->
        <fieldset class="border border-gray-200 rounded-lg p-4">
          <legend class="text-sm font-medium text-gray-700 px-1">1. Select Bot Type</legend>
          <div class="space-y-2 mt-2">
            <%= for bot <- @bot_types do %>
              <label
                phx-click="select_type"
                phx-value-uri={bot.uri_str}
                class={[
                  "block rounded-lg border p-3 cursor-pointer hover:bg-gray-50 transition",
                  @selected_type == bot.uri_str && "border-blue-500 bg-blue-50"
                ]}
              >
                <div class="text-sm font-medium text-gray-800">{bot.name}</div>
                <div class="text-xs text-gray-500 mt-0.5">{bot.description}</div>
              </label>
            <% end %>
            <p :if={@bot_types == []} class="text-xs text-gray-400">
              No Bot Types available. Run <code>mix ezagent.skill.bootstrap</code> to create one.
            </p>
          </div>
        </fieldset>

        <!-- Name Input -->
        <fieldset :if={@selected_type} class="border border-gray-200 rounded-lg p-4">
          <legend class="text-sm font-medium text-gray-700 px-1">2. Name Your Bot</legend>
          <div class="mt-2">
            <input
              type="text"
              name="name"
              value={@new_bot_name}
              phx-change="set_name"
              placeholder="e.g. my-ecommerce-bot"
              class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
            />
          </div>
        </fieldset>

        <!-- Create Button -->
        <button
          :if={@selected_type}
          phx-click="create"
          disabled={@new_bot_name == ""}
          class="w-full rounded-lg bg-blue-600 text-white px-4 py-2 text-sm font-medium hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          3. Create Bot
        </button>

        <p :if={@flash_msg} class="text-sm text-gray-600 bg-gray-50 rounded-lg p-3">
          {@flash_msg}
        </p>
      </div>
    </div>
    """
  end

  # --- helpers ---

  defp list_system_templates do
    # Walk KindRegistry for AgentTemplate Kinds in system workspace.
    # For MVP: return hardcoded bot types.
    [
      %{
        name: "Customer Service Bot",
        description: "客服机器人: identity + gate + escalation + conversation style",
        uri_str: "template://agent/system/skeleton",
        flavor: "cc"
      }
    ]
  end

  defp fork_bot(type_uri_str, name, %URI{scheme: "workspace", host: ws_name}) do
    parent_uri = Ezagent.URI.new!(type_uri_str)
    new_uri = Ezagent.URI.new!("template://agent/#{ws_name}/#{name}")
    ctx = %{caller: new_uri, caps: [], reply: {:caller_inbox, self()}}

    # 1. Read parent content
    target_read = Ezagent.URI.with_action(parent_uri, :template, :read)

    with {:ok, content} when is_map(content) <-
           Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target_read,
             mode: :call,
             args: %{},
             ctx: ctx
           }) do
      # 2. Spawn new AgentTemplate Kind
      case Ezagent.SpawnRegistry.spawn(new_uri) do
        {:ok, _pid} ->
          # 3. Write forked content
          fork_content =
            content
            |> Map.put(:name, name)
            |> Map.put(:parent_template_uri, parent_uri)
            |> Map.put(:created_at, DateTime.utc_now())

          target_write = Ezagent.URI.with_action(new_uri, :template, :write)

          case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                 target: target_write,
                 mode: :call,
                 args: %{content: fork_content},
                 ctx: ctx
               }) do
            {:ok, _} -> {:ok, new_uri}
            :ok -> {:ok, new_uri}
            other -> {:error, {:write_failed, other}}
          end

        {:error, {:already_started, _pid}} ->
          {:ok, new_uri}

        {:error, reason} ->
          {:error, {:spawn_failed, reason}}
      end
    else
      {:ok, content} when is_map(content) ->
        do_spawn_and_write(new_uri, content, name, parent_uri, ctx)

      other ->
        {:error, {:read_failed, other}}
    end
  end

  defp fork_bot(_, _, _), do: {:error, :invalid_workspace}

  defp do_spawn_and_write(new_uri, content, name, parent_uri, ctx) do
    fork_content =
      content
      |> Map.put(:name, name)
      |> Map.put(:parent_template_uri, parent_uri)
      |> Map.put(:created_at, DateTime.utc_now())

    case Ezagent.SpawnRegistry.spawn(new_uri) do
      {:ok, _pid} ->
        target_write = Ezagent.URI.with_action(new_uri, :template, :write)

        case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
               target: target_write,
               mode: :call,
               args: %{content: fork_content},
               ctx: ctx
             }) do
          {:ok, _} -> {:ok, new_uri}
          :ok -> {:ok, new_uri}
          other -> {:error, {:write_failed, other}}
        end

      {:error, {:already_started, _pid}} ->
        {:ok, new_uri}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  defp workspace_label(%URI{host: name}), do: "workspace://#{name}"
  defp workspace_label(_), do: ""
end
