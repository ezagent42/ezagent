defmodule EzagentPluginLiveview.TemplateEditorLive do
  @moduledoc """
  Template Editor — chat panel for AI-assisted template creation/editing.

  Admin sends messages to the Authoring Agent (cc agent, system workspace).
  Agent reads/modifies soul template files and AgentTemplate content.
  """
  use Phoenix.LiveView
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  require Logger

  @agent_session_uri "session://cs/system/template-authoring"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:section, :templates)
     |> assign(:messages, [])
     |> assign(:compose_text, "")
     |> assign(:loading, false)
     |> assign(:flash_msg, nil)}
  end

  @impl true
  def handle_event("send", %{"text" => text}, socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      msg = %{
        role: "user",
        content: text,
        at: DateTime.utc_now()
      }

      socket =
        socket
        |> update(:messages, fn ms -> ms ++ [msg] end)
        |> assign(:compose_text, "")
        |> assign(:loading, true)

      # Dispatch to Authoring Agent session
      dispatch_to_agent(text, socket.assigns)

      {:noreply, socket}
    end
  end

  def handle_event("update_compose", %{"text" => text}, socket) do
    {:noreply, assign(socket, :compose_text, text)}
  end

  @impl true
  def handle_info({:agent_reply, reply_text}, socket) do
    msg = %{
      role: "assistant",
      content: reply_text,
      at: DateTime.utc_now()
    }

    {:noreply,
     socket
     |> update(:messages, fn ms -> ms ++ [msg] end)
     |> assign(:loading, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col">
      <header class="px-4 py-3 border-b bg-white shrink-0">
        <h1 class="text-sm font-semibold text-gray-800">Template Editor</h1>
        <p class="text-xs text-gray-400 mt-0.5">
          Chat with Authoring Agent to create/edit bot templates
        </p>
      </header>

      <!-- Messages -->
      <div class="flex-1 overflow-y-auto p-4 space-y-3 bg-gray-50">
        <p :if={@messages == []} class="text-sm text-gray-400 text-center mt-8">
          Describe the bot you want to create, or ask the agent to modify an existing template.
        </p>

        <%= for msg <- @messages do %>
          <div class={["flex", msg.role == "user" && "justify-end" || "justify-start"]}>
            <div class={[
              "max-w-[75%] rounded-2xl px-3 py-2 text-sm shadow-sm",
              msg.role == "user" && "bg-blue-600 text-white" || "bg-white border border-gray-200 text-gray-800"
            ]}>
              <div class="whitespace-pre-wrap break-words">{msg.content}</div>
            </div>
          </div>
        <% end %>

        <p :if={@loading} class="text-xs text-gray-400">Agent is thinking...</p>

        <p :if={@flash_msg} class="text-sm text-gray-600 bg-gray-50 rounded-lg p-3">{@flash_msg}</p>
      </div>

      <!-- Composer -->
      <form phx-submit="send" class="flex gap-2 p-3 border-t bg-white">
        <input
          type="text"
          name="text"
          value={@compose_text}
          phx-change="update_compose"
          placeholder="Describe the bot template you want..."
          autocomplete="off"
          class="flex-1 rounded-lg border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
        />
        <button
          type="submit"
          disabled={@compose_text == ""}
          class="rounded-lg bg-blue-600 text-white px-4 py-2 text-sm font-medium hover:bg-blue-700 disabled:opacity-50"
        >
          Send
        </button>
      </form>
    </div>
    """
  end

  # --- helpers ---

  defp dispatch_to_agent(text, assigns) do
    caller_uri = assigns[:current_entity_uri]
    caps = assigns[:caps] || []

    msg = Ezagent.Message.new(caller_uri, %{text: text, attachments: []})
    session_uri = Ezagent.URI.new!(@agent_session_uri)
    target = Ezagent.URI.with_action(session_uri, :chat, :send)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{caller: caller_uri, caps: caps, reply: :ignore}
    })
  end
end
