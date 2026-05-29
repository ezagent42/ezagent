defmodule EzagentPluginCustomerChat.SessionViewLive do
  @moduledoc """
  Phase 2.7 — detail view for one customer session.

  URL: `/admin/customer_sessions/:id` where `:id` is the
  URL-encoded canonical session URI string (matches the
  agent_detail_live convention).

  Shows:
  - Session metadata (URI, workspace, conv-id, mode)
  - Live transcript (subscribes to the session's events topic,
    stream-inserts each `{:chat_message, _, %Ezagent.Message{}}`)
  - "Take over" button that dispatches Phase 2.6's mode-set action

  ## Phase 2.6 integration point

  The take-over button calls `dispatch_takeover/1`. Until Phase 2.6
  merges, that helper dispatches a best-guess shape against
  `session://...?action=mode.set`. Expected behavior pre-2.6:
  dispatch returns `:no_such_actor` or `:unauthorized` — the
  failure is itself the integration test that the wire is hooked
  up. Post-2.6: replace the `action=mode.set` URI / args shape
  with whatever 2.6 documents in
  `poc/phase-2/6-mode-takeover.md`.
  """

  use Phoenix.LiveView
  import Phoenix.Component
  require Logger

  use EzagentDomainUi.Components

  @message_limit 50

  @impl true
  def mount(%{"id" => encoded_id}, _session, socket) do
    caller_uri = socket.assigns[:current_entity_uri]
    workspace_uri = socket.assigns[:current_workspace_uri]

    with {:ok, session_uri} <- parse_session_uri(encoded_id),
         :ok <- authorize(caller_uri, workspace_uri, session_uri) do
      if connected?(socket) do
        topic = Ezagent.Behavior.Chat.session_events_topic(session_uri)
        Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
      end

      caller_caps = Ezagent.Identity.list_caps_for(caller_uri)
      messages = load_messages(session_uri)

      {:ok,
       socket
       |> assign(:page_title, "Session " <> conv_id_of(session_uri))
       |> assign(:session_uri, session_uri)
       |> assign(:session_uri_str, URI.to_string(session_uri))
       |> assign(:conv_id, conv_id_of(session_uri))
       |> assign(:workspace_seg, workspace_of(session_uri))
       |> assign(:tenant, workspace_of(session_uri))
       |> assign(:mode, lookup_mode(session_uri))
       |> assign(:caller_caps, caller_caps)
       |> assign(:flash_error, nil)
       |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))
       |> assign_new(:current_entity_uri_str, fn ->
         URI.to_string(caller_uri || URI.parse("entity://user/system/admin"))
       end)
       |> stream(:messages, Enum.map(messages, &message_to_row/1))
       |> assign(:messages_empty?, messages == [])}
    else
      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, deny_message(reason))
         |> redirect(to: "/admin/customer_sessions")}
    end
  end

  @impl true
  def handle_info({:chat_message, source_session_uri, %Ezagent.Message{} = msg}, socket) do
    if URI.to_string(source_session_uri) == socket.assigns.session_uri_str do
      {:noreply,
       socket
       |> assign(:messages_empty?, false)
       |> stream_insert(:messages, message_to_row(msg), at: -1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_message, _msg}, socket), do: {:noreply, socket}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("take_over", _params, socket) do
    case dispatch_takeover(socket) do
      :ok ->
        {:noreply,
         socket
         |> assign(:mode, :takeover)
         |> put_flash(:info, "Take-over engaged.")}

      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:mode, :takeover)
         |> put_flash(:info, "Take-over engaged.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(
           :flash_error,
           "Take-over failed: #{inspect(reason)} (expected pre-Phase-2.6 — wire is connected)"
         )}
    end
  end

  def handle_event("send_chat", %{"chat" => %{"text" => text}}, socket)
      when is_binary(text) and text != "" do
    case send_operator_message(socket, String.trim(text)) do
      :ok ->
        {:noreply,
         socket
         |> assign(:flash_error, nil)
         |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))}

      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:flash_error, nil)
         |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))}

      {:error, reason} ->
        {:noreply,
         assign(socket, :flash_error, "Send failed: #{inspect(reason)}")}
    end
  end

  def handle_event("send_chat", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-zinc-50">
      <header class="px-6 py-3 border-b border-zinc-200 bg-white flex items-center gap-3">
        <span class="font-semibold text-zinc-900">Customer Service</span>
        <span class="text-xs text-zinc-500 font-mono">{@tenant}</span>
      </header>
      <div class="flex-1 min-h-0 overflow-auto">
        <div class="flex-1 flex flex-col min-h-0">
          <header class="px-6 py-4 border-b border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 flex items-start justify-between gap-4">
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <.link
                  navigate="/admin/customer_sessions"
                  class="text-xs text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100"
                >← {"Back"}</.link>
              </div>
              <h1 class="text-lg font-semibold mt-1 truncate">{@conv_id}</h1>
              <p class="font-mono text-xs text-zinc-500 truncate">{@session_uri_str}</p>
            </div>
            <div class="flex items-center gap-3 shrink-0">
              <.mode_badge mode={@mode} />
              <button
                type="button"
                phx-click="take_over"
                disabled={@mode == :takeover}
                class={[
                  "px-3 py-1.5 text-sm rounded-md font-medium",
                  @mode == :takeover && "bg-zinc-200 text-zinc-500 cursor-not-allowed",
                  @mode != :takeover &&
                    "bg-amber-500 text-white hover:bg-amber-600"
                ]}
                id="take-over-button"
              >
                <%= if @mode == :takeover, do: "Taken over", else: "Take over" %>
              </button>
            </div>
          </header>

          <p :if={@flash_error} class="px-6 py-2 text-rose-600 dark:text-rose-400 text-xs bg-rose-50 dark:bg-rose-950 border-b border-rose-200 dark:border-rose-800">
            {@flash_error}
          </p>

          <div class="flex-1 overflow-auto px-6 py-4 space-y-2" id="transcript">
            <p :if={@messages_empty?} class="text-zinc-500 italic text-sm">
              {"No messages yet."}
            </p>
            <div
              id="messages"
              phx-update="stream"
              class="space-y-2"
            >
              <div
                :for={{dom_id, row} <- @streams.messages}
                id={dom_id}
                class={[
                  "px-3 py-2 rounded text-sm max-w-2xl",
                  row.sender_kind == :user && "bg-blue-50 dark:bg-blue-950 self-start",
                  row.sender_kind == :agent && "bg-zinc-100 dark:bg-zinc-800 ml-auto",
                  row.sender_kind == :other && "bg-yellow-50 dark:bg-yellow-950"
                ]}
              >
                <div class="text-xs text-zinc-500 mb-0.5 font-mono">{row.sender_display}</div>
                <div class="whitespace-pre-wrap break-words">{row.text}</div>
              </div>
            </div>
          </div>

          <%= if @mode == :takeover do %>
            <footer class="border-t border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950 px-6 py-3">
              <.form
                for={@compose_form}
                phx-submit="send_chat"
                class="flex gap-2 items-center"
              >
                <input
                  type="text"
                  name="chat[text]"
                  id="chat_text"
                  placeholder="Reply as operator…"
                  class="flex-1 px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-500"
                />
                <.button type="submit" variant="primary" size="sm">{"Send"}</.button>
              </.form>
              <p class="text-[10px] text-zinc-500 mt-1">
                {"Sending as operator (PUBLIC). Customer sees these messages."}
              </p>
            </footer>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp mode_badge(assigns) do
    ~H"""
    <span class={
      "inline-block text-xs px-2 py-0.5 rounded font-medium " <>
        case @mode do
          :takeover -> "bg-amber-100 text-amber-800"
          :copilot -> "bg-blue-100 text-blue-800"
          _ -> "bg-green-100 text-green-800"
        end
    }>
      {mode_label(@mode)}
    </span>
    """
  end

  defp mode_label(:takeover), do: "Takeover"
  defp mode_label(:copilot), do: "Copilot"
  defp mode_label(_), do: "Auto"

  # ---- send operator message --------------------------------------------

  defp send_operator_message(socket, text) do
    msg =
      Ezagent.Message.new(
        socket.assigns.current_entity_uri,
        %{text: text, attachments: []}
      )

    target =
      URI.new!("#{socket.assigns.session_uri_str}?action=chat.send")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{
        caller: socket.assigns.current_entity_uri,
        caps: socket.assigns.caller_caps,
        reply: :ignore
      }
    }

    Ezagent.Invocation.dispatch(inv)
  end

  # ---- take-over dispatch (Phase 2.6 integration point) -----------------

  # PHASE_2.6_INTEGRATION — replace with the actual dispatch shape
  # Phase 2.6 documents in `poc/phase-2/6-mode-takeover.md`. The
  # action verb (`mode.set` vs `behavior.mode.set` vs a new
  # `Behavior.Mode` dispatch entirely) and the args map (`%{mode:
  # ...}` vs `%{value: ...}`) are both TBD. Pre-2.6 this dispatch
  # is expected to return `{:error, :no_such_actor}` or similar —
  # that failure is the proof that the LV wire is hooked up.
  defp dispatch_takeover(socket) do
    target =
      URI.new!("#{socket.assigns.session_uri_str}?action=mode.set")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{mode: :takeover, set_by: socket.assigns.current_entity_uri},
      ctx: %{
        caller: socket.assigns.current_entity_uri,
        caps: socket.assigns.caller_caps,
        reply: {:caller_inbox, self()}
      }
    }

    Ezagent.Invocation.dispatch(inv)
  end

  # ---- helpers ----------------------------------------------------------

  defp load_messages(%URI{} = session_uri) do
    session_uri
    |> Ezagent.MessageStore.recent_in_session(@message_limit)
    |> Enum.reverse()
  end

  defp message_to_row(%Ezagent.Message{} = msg) do
    sender_str = URI.to_string(msg.sender)

    %{
      id: msg.id,
      sender: sender_str,
      sender_display: short_sender(msg.sender),
      sender_kind: sender_kind(sender_str),
      text: body_text(msg.body),
      at: msg.inserted_at
    }
  end

  defp sender_kind(uri_str) do
    cond do
      String.starts_with?(uri_str, "entity://user/") -> :user
      String.starts_with?(uri_str, "entity://agent/") -> :agent
      true -> :other
    end
  end

  defp body_text(%{text: t}) when is_binary(t), do: t
  defp body_text(%{"text" => t}) when is_binary(t), do: t
  defp body_text(_), do: ""

  defp short_sender(%URI{path: "/" <> rest}) do
    rest
  end

  defp short_sender(uri), do: URI.to_string(uri)

  defp conv_id_of(%URI{path: "/" <> rest}) do
    case String.split(rest, "/", parts: 2) do
      [_ws, conv_id] -> conv_id
      _ -> "(unknown)"
    end
  end

  defp conv_id_of(_), do: "(unknown)"

  defp workspace_of(%URI{path: "/" <> rest}) do
    case String.split(rest, "/", parts: 2) do
      [ws, _] -> ws
      _ -> "(unknown)"
    end
  end

  defp workspace_of(_), do: "(unknown)"

  # PHASE_2.6_INTEGRATION — mirror the dashboard's placeholder. The
  # mode is sourced however Phase 2.6 decides (slice read, Behavior
  # query, etc). Pre-2.6 every session is reported :auto.
  defp lookup_mode(_session_uri), do: :auto

  defp parse_session_uri(encoded_id) when is_binary(encoded_id) do
    decoded = URI.decode_www_form(encoded_id)

    case URI.new(decoded) do
      {:ok, %URI{scheme: "session", path: "/" <> _} = uri} -> {:ok, uri}
      _ -> {:error, :bad_uri}
    end
  end

  defp parse_session_uri(_), do: {:error, :bad_uri}

  defp authorize(nil, _, _), do: {:error, :no_entity}
  defp authorize(_, nil, _), do: {:error, :no_workspace}

  defp authorize(%URI{} = caller, %URI{host: ws_name}, %URI{} = session_uri)
       when is_binary(ws_name) do
    cond do
      workspace_of(session_uri) != ws_name ->
        # Belt-and-suspenders cross-workspace block. Operator can
        # only view sessions in their current workspace.
        {:error, :cross_workspace}

      not has_any_cap?(caller) ->
        {:error, :no_caps}

      true ->
        :ok
    end
  end

  defp authorize(_, _, _), do: {:error, :bad_state}

  # `Ezagent.Identity.list_caps_for/1` returns a `MapSet`; we only
  # need "at least one" for the PoC gate (see moduledoc + FINDINGS).
  defp has_any_cap?(caller_uri) do
    caller_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?()
  end

  defp deny_message(:no_entity), do: "Sign in required."
  defp deny_message(:no_workspace), do: "No workspace context — pick a workspace first."
  defp deny_message(:no_caps), do: "Operator role required (any cap)."
  defp deny_message(:cross_workspace), do: "That session belongs to a different workspace."
  defp deny_message(:bad_uri), do: "Malformed session URI."
  defp deny_message(_), do: "Access denied."
end
