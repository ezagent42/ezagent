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

    File.mkdir_p!(Ezagent.Home.path("uploads"))

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

  defp upload_workspace_name!(socket) do
    case Ezagent.Capability.workspace_of(socket.assigns.current_entity_uri) do
      %URI{} = workspace_uri ->
        Ezagent.URI.workspace_name!(workspace_uri)

      other ->
        raise ArgumentError,
              "current_entity_uri does not yield a workspace URI with a binary host " <>
                "— got #{inspect(other)} for current_entity_uri=" <>
                "#{inspect(socket.assigns.current_entity_uri)}. Per SPEC #324 rev 3 / " <>
                "PR #362, there is NO silent default workspace fallback; the " <>
                "authenticated caller must carry a workspace structurally."
    end
  end

  defp consume_attachments(socket, workspace_name) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :attachments, fn %{path: tmp_path}, entry ->
      uuid = Ecto.UUID.generate()
      safe_name = sanitize_filename(entry.client_name)
      stored_name = "#{uuid}-#{safe_name}"
      dest = Path.join(Ezagent.Home.path("uploads"), stored_name)
      File.cp!(tmp_path, dest)
      {:ok, Ezagent.URI.resource(workspace_name, :uploads, stored_name)}
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

    target = Ezagent.URI.with_action(socket.assigns.current_session_uri, :chat, :send)

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
