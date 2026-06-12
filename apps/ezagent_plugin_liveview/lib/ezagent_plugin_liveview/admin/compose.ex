defmodule EzagentPluginLiveview.Admin.Compose do
  @moduledoc false

  import Phoenix.Component

  use Gettext, backend: EzagentPluginLiveview.Gettext

  alias EzagentPluginLiveview.Admin.SessionContext

  def cancel_upload(socket, ref) do
    {:noreply, Phoenix.LiveView.cancel_upload(socket, :attachments, ref)}
  end

  def submit(socket, text) when is_binary(text) do
    {mentions, legend_triggers} =
      SessionContext.parse_mentions(
        text,
        socket.assigns[:member_options] || [],
        socket.assigns[:session_legends] || %{}
      )

    # P2b — uploads are ws-partitioned; `Ezagent.Uploads.store!/3` creates the
    # per-workspace destination dir on write, so no global `ensure_dir!/0` here.
    attachments =
      consume_attachments(socket, upload_workspace_name!(socket))

    if String.trim(text) == "" and attachments == [] do
      missing(socket)
    else
      send_chat_message(socket, text, attachments, mentions, legend_triggers)
    end
  end

  def missing(socket) do
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext("Message text or at least one attachment is required.")
     )}
  end

  # The upload's storage workspace is the workspace of the TARGET SESSION the
  # attachment is being sent to — NOT the entity's home workspace
  # (codex P2 round-3 HIGH). A system member context-switched into tenant W sends
  # the message to a session bound to W, so the attachment must live under W:
  # otherwise it would be stored as `resource://system/uploads/...` while the
  # download authority (which uses the selected `:current_workspace_uri` = W)
  # would reject or miss it. Deriving from the session keeps store-ws and
  # download-ws structurally identical by construction.
  defp upload_workspace_name!(socket) do
    session_uri = socket.assigns.current_session_uri

    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = workspace_uri ->
        Ezagent.URI.workspace_name!(workspace_uri)

      other ->
        raise ArgumentError,
              "current_session_uri does not yield a workspace URI with a binary host " <>
                "— got #{inspect(other)} for current_session_uri=" <>
                "#{inspect(session_uri)}. Per SPEC #324 rev 3 / PR #362 there is NO " <>
                "silent default workspace fallback; the target session must carry a " <>
                "workspace structurally."
    end
  end

  defp consume_attachments(socket, workspace_name) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :attachments, fn %{path: tmp_path}, entry ->
      uuid = Ecto.UUID.generate()
      safe_name = sanitize_filename(entry.client_name)
      stored_name = "#{uuid}-#{safe_name}"
      {:ok, Ezagent.Uploads.store!(workspace_name, stored_name, tmp_path)}
    end)
  end

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^\w\.\-]+/, "_")
    |> String.slice(0, 200)
    |> case do
      "" -> "file"
      s -> s
    end
  end

  defp sanitize_filename(_), do: "file"

  defp send_chat_message(socket, text, attachments, mentions, legend_triggers) do
    msg =
      Ezagent.Message.new(
        socket.assigns.caller_uri,
        %{text: text, attachments: attachments},
        mentions: mentions,
        legend_triggers: legend_triggers
      )

    # PR-1: session.send is the SINGLE public Session post verb
    # (chat.send demoted to session-internal). Mode preserved (:cast).
    target = Ezagent.URI.with_action(socket.assigns.current_session_uri, :session, :send)

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: ctx(socket)
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok ->
        clear(socket)

      {:ok, _} ->
        clear(socket)

      {:error, reason} ->
        {:noreply, assign(socket, :flash_error, friendly_error(gettext("Send"), reason))}
    end
  end

  defp clear(socket) do
    # Phoenix's DOM patcher leaves phx-hook-owned inputs alone, so push an event
    # the MentionAutocomplete hook listens for to clear the browser DOM.
    {:noreply,
     socket
     |> assign(:flash_error, nil)
     |> assign(:compose_form, to_form(%{"text" => ""}, as: "chat"))
     |> Phoenix.LiveView.push_event("clear_compose", %{})}
  end

  defp ctx(socket) do
    %{
      caller: socket.assigns.caller_uri,
      caps: socket.assigns.caller_caps,
      reply: :ignore
    }
  end

  defp friendly_error(_action, :unauthorized) do
    gettext("You don't have permission for this action. Contact admin for cap grant.")
  end

  defp friendly_error(_action, :cross_workspace_denied) do
    gettext(
      "Cross-workspace denied — your workspace differs from the target's workspace. Contact admin for a cross-workspace cap."
    )
  end

  defp friendly_error(action, reason),
    do: gettext("%{action} failed: %{reason}", action: action, reason: inspect(reason))
end
