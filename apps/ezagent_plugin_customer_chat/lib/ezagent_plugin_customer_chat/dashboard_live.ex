defmodule EzagentPluginCustomerChat.DashboardLive do
  @moduledoc """
  Phase 2.7 — Operator dashboard for live customer sessions.

  Lists every active customer session (per-conv URI shape
  `session://default/<ws>/<conv-id>`) for the operator's current
  workspace, with last-message preview + mode badge. Click a row to
  navigate to the per-session detail LV
  (`CustomerSessionViewLive`) which shows the live transcript +
  Take-over button.

  ## Operator model (constraint #2 in migration-design-constraints.md)

  Operator is NOT a new entity Kind. It's an authenticated
  `entity://user/<ws>/<name>` that holds *some* cap. The PoC gate
  here is "any cap on the workspace". Production-shape gate would
  be a dedicated `Behavior.Workspace :customer_session_observer`
  cap (and a separate `Behavior.Mode :set` cap for take-over).
  See FINDINGS for the production cap design recommendation.

  ## Session enumeration

  Strategy: filter `EzagentDomainChat.list_sessions(workspace_uri)`
  down to per-conv sessions (`session://default/<ws>/<conv-id>`)
  whose `conv-id` is NOT `"main"` — the canonical per-conv shape
  excludes the shared `main` chatroom that AdminLive already
  drives. A future production deploy may want to also filter on
  session-template class (`default` here) once customer sessions
  get their own template class — for the PoC we accept all
  non-main sessions as "customer-facing".

  ## Live updates

  Mount subscribes to `session_events_topic/1` for every enumerated
  session so the row preview + last-activity timestamp updates as
  new messages arrive. New sessions appearing mid-LV: the PoC
  re-enumerates on every received chat-message event (cheap — it's
  one KindRegistry scan), which catches new sessions on the first
  message they emit. A production deploy with hundreds of live
  sessions should swap this for a dedicated session-lifecycle
  PubSub topic; flagged as a follow-up in FINDINGS.
  """

  use Phoenix.LiveView
  import Phoenix.Component
  require Logger

  use EzagentDomainUi.Components

  @impl true
  def mount(_params, _session, socket) do
    caller_uri = socket.assigns[:current_entity_uri]
    workspace_uri = socket.assigns[:current_workspace_uri]

    case authorize_operator(caller_uri, workspace_uri) do
      :ok ->
        if connected?(socket) do
          subscribe_to_sessions(workspace_uri)
        end

        rows = enumerate_session_rows(workspace_uri)

        {:ok,
         socket
         |> assign(:page_title, "Customer Sessions")
         |> assign(:workspace_uri, workspace_uri)
         |> assign(:tenant, workspace_label(workspace_uri))
         |> assign(:rows, rows)
         |> assign(:flash_error, nil)
         |> assign_new(:current_entity_uri_str, fn ->
           URI.to_string(caller_uri || URI.parse("entity://user/system/admin"))
         end)}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, deny_message(reason))
         |> redirect(to: "/sessions")}
    end
  end

  @impl true
  def handle_info({:chat_message, _src_uri, _msg}, socket) do
    # Cheap re-enumeration — picks up new sessions and updated
    # last-activity / preview at once. For PoC scale (≤ tens of
    # sessions) this is fine.
    rows = enumerate_session_rows(socket.assigns.workspace_uri)
    # Re-subscribe to catch any new session URIs that appeared since
    # mount. PubSub.subscribe is idempotent per (pid, topic).
    if connected?(socket), do: subscribe_to_sessions(socket.assigns.workspace_uri)
    {:noreply, assign(socket, :rows, rows)}
  end

  def handle_info({:chat_message, _msg}, socket), do: {:noreply, socket}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-zinc-50">
      <header class="px-6 py-3 border-b border-zinc-200 bg-white flex items-center gap-3">
        <span class="font-semibold text-zinc-900">Customer Service</span>
        <span class="text-xs text-zinc-500 font-mono">{@tenant}</span>
      </header>
      <div class="flex-1 min-h-0 overflow-auto">
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title="Customer Sessions">
            <:subtitle>
              {"Live customer conversations in workspace #{workspace_label(@workspace_uri)}."}
            </:subtitle>
          </.page_header>

          <p :if={@flash_error} class="text-rose-600 dark:text-rose-400 text-xs mb-4">{@flash_error}</p>

          <p :if={@rows == []} id="empty" class="text-zinc-500 italic text-sm">
            {"No active customer sessions yet."}
            <br/>
            <span class="text-xs">
              Sessions matching <code class="font-mono">session://default/&lt;ws&gt;/&lt;conv-id&gt;</code>
              appear here when customers start chatting.
            </span>
          </p>

          <.card :if={@rows != []} class="p-0">
            <ul id="customer-sessions" class="divide-y divide-zinc-200 dark:divide-zinc-800">
              <li :for={row <- @rows} class="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                <.link
                  navigate={"/admin/customer_sessions/" <> URI.encode_www_form(row.session_uri_str)}
                  class="block px-4 py-3"
                >
                  <div class="flex items-center justify-between">
                    <div class="flex-1 min-w-0">
                      <div class="flex items-center gap-2">
                        <span class="font-medium">{row.conv_id}</span>
                        <.mode_badge mode={row.mode} />
                      </div>
                      <div class="text-sm text-zinc-600 dark:text-zinc-400 truncate mt-1">
                        <%= if row.last_message_preview do %>
                          <span class="text-zinc-500">{row.last_sender_short}:</span>
                          {row.last_message_preview}
                        <% else %>
                          <span class="italic text-zinc-400">{"No messages yet"}</span>
                        <% end %>
                      </div>
                    </div>
                    <div class="text-xs text-zinc-400 ml-4 whitespace-nowrap">
                      {format_at(row.last_activity_at)}
                    </div>
                  </div>
                </.link>
              </li>
            </ul>
          </.card>
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

  defp workspace_label(%URI{} = uri), do: URI.to_string(uri)
  defp workspace_label(_), do: "(unknown)"

  defp format_at(nil), do: "—"

  defp format_at(%DateTime{} = at) do
    diff = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(at, "%Y-%m-%d %H:%M")
    end
  end

  # ---- session enumeration -----------------------------------------------

  defp enumerate_session_rows(%URI{scheme: "workspace"} = ws_uri) do
    ws_uri
    |> EzagentDomainChat.list_sessions()
    |> Enum.filter(&customer_session?/1)
    |> Enum.map(&row_for_session/1)
    |> Enum.sort_by(& &1.last_activity_sort, {:desc, DateTime})
  end

  defp enumerate_session_rows(_), do: []

  # Per Phase 1+2 verdict §3: customer sessions are per-conv URIs
  # `session://default/<ws>/<conv-id>` where conv-id != "main".
  # AdminLive already owns the "main" room; this LV owns the rest.
  defp customer_session?(%URI{scheme: "session", path: "/" <> rest}) do
    case String.split(rest, "/", parts: 2) do
      [_ws, conv_id] when conv_id != "main" and conv_id != "" -> true
      _ -> false
    end
  end

  defp customer_session?(_), do: false

  defp row_for_session(%URI{} = session_uri) do
    last_msg =
      case Ezagent.MessageStore.recent_in_session(session_uri, 1) do
        [%Ezagent.Message{} = m] -> m
        _ -> nil
      end

    %{
      session_uri_str: URI.to_string(session_uri),
      conv_id: conv_id_of(session_uri),
      workspace: workspace_of(session_uri),
      mode: lookup_mode(session_uri),
      customer_id: nil,
      last_message_preview: preview(last_msg),
      last_sender_short: last_msg && short_sender(last_msg.sender),
      last_activity_at: last_msg && last_msg.inserted_at,
      last_activity_sort: (last_msg && last_msg.inserted_at) || ~U[1970-01-01 00:00:00.000000Z]
    }
  end

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

  defp preview(nil), do: nil

  defp preview(%Ezagent.Message{body: body}) do
    text =
      case body do
        %{text: t} when is_binary(t) -> t
        %{"text" => t} when is_binary(t) -> t
        _ -> ""
      end

    text
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 80)
  end

  defp short_sender(%URI{path: "/" <> rest}) do
    rest |> String.split("/") |> List.last() || "?"
  end

  defp short_sender(uri), do: inspect(uri)

  # PHASE_2.6_INTEGRATION — `:mode` slice/field on the session Kind is
  # added by Phase 2.6. Until that lands, every session reports
  # :auto. Once 2.6 merges, replace with something like:
  #
  #     Ezagent.Behavior.Mode.get(session_uri)  # → :auto | :takeover | :copilot
  #
  # or a slice read of whatever shape 2.6 picks. The dashboard's
  # row.mode field is already wired through to the badge render.
  defp lookup_mode(_session_uri), do: :auto

  # ---- subscribe ---------------------------------------------------------

  defp subscribe_to_sessions(%URI{} = ws_uri) do
    topics =
      ws_uri
      |> EzagentDomainChat.list_sessions()
      |> Enum.filter(&customer_session?/1)
      |> Enum.map(&Ezagent.Behavior.Chat.session_events_topic/1)

    Enum.each(topics, fn topic ->
      # Phoenix.PubSub.subscribe is idempotent per (pid, topic), so
      # the re-subscribe on every chat_message event is a no-op for
      # already-subscribed topics + catches newly-appeared ones.
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)
    end)
  end

  defp subscribe_to_sessions(_), do: :ok

  # ---- authz -------------------------------------------------------------

  # PoC operator gate (constraint #2): any cap on the workspace
  # counts. Production should require a dedicated
  # `Behavior.Workspace :customer_session_observer` cap. See
  # FINDINGS for the recommended cap shape.
  defp authorize_operator(nil, _), do: {:error, :no_entity}
  defp authorize_operator(_, nil), do: {:error, :no_workspace}

  defp authorize_operator(%URI{} = caller_uri, %URI{} = _workspace_uri) do
    if has_any_cap?(caller_uri) do
      :ok
    else
      {:error, :no_caps}
    end
  end

  # `Ezagent.Identity.list_caps_for/1` returns a `MapSet`. We don't
  # care which caps the operator holds for the PoC gate — only that
  # they hold *at least one*. Production should swap this for a
  # specific cap check (see moduledoc + FINDINGS).
  defp has_any_cap?(caller_uri) do
    caller_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?()
  end

  defp deny_message(:no_entity), do: "Sign in required."
  defp deny_message(:no_workspace), do: "No workspace context — pick a workspace first."

  defp deny_message(:no_caps),
    do: "Operator role required — you need at least one capability on this workspace."
end
