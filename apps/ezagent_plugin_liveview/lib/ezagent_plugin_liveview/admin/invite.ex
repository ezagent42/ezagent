defmodule EzagentPluginLiveview.Admin.Invite do
  @moduledoc false

  import Phoenix.Component

  use Gettext, backend: EzagentPluginLiveview.Gettext

  alias EzagentPluginLiveview.Admin.SessionContext

  def open(socket), do: {:noreply, assign(socket, :invite_open, true)}
  def close(socket), do: {:noreply, assign(socket, :invite_open, false)}

  def submit(socket, uri_str) when is_binary(uri_str) and uri_str != "" do
    trimmed = String.trim(uri_str)
    caller_uri = socket.assigns.current_entity_uri
    session_uri = socket.assigns.current_session_uri
    workspace_uri = SessionContext.invite_workspace_uri(socket)

    cond do
      not match?(%URI{}, caller_uri) ->
        {:noreply, assign(socket, :flash_error, gettext("Not signed in."))}

      not Ezagent.UI.UriOptions.valid_for?(caller_uri, workspace_uri, trimmed, [:entity]) ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Rejected %{uri} — must be an entity URI in this session's workspace (%{workspace}). Pick from the list.",
             uri: inspect(trimmed),
             workspace: URI.to_string(workspace_uri)
           )
         )}

      true ->
        dispatch_invite(socket, session_uri, workspace_uri, trimmed)
    end
  end

  def missing(socket) do
    {:noreply, assign(socket, :flash_error, gettext("Pick an entity to invite."))}
  end

  defp dispatch_invite(socket, session_uri, workspace_uri, trimmed) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    member_uri = Ezagent.URI.new!(trimmed)

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: %{
          caller: socket.assigns.caller_uri,
          caps: socket.assigns.caller_caps,
          reply: :ignore
        }
      })

    # #154 PR-甲-2 §A — mount the per-class participation tier on the INVITED
    # member after a successful owner-authorized join (caller-side, best-effort,
    # no-op for agents). The inviter's OWN `:join` authority comes from their
    # self-join on this LV (`SessionContext.maybe_self_join`, owner-rooted §B),
    # which runs on `/sessions` mount before any invite click — so this invite
    # dispatch authorizes via the live slice read; no provisioning needed here.
    case result do
      :ok -> mount_invited_member(session_uri, member_uri)
      {:ok, _} -> mount_invited_member(session_uri, member_uri)
      _ -> :ok
    end

    invite_result(socket, session_uri, workspace_uri, result)
  end

  defp mount_invited_member(%URI{} = session_uri, %URI{} = member_uri) do
    _ =
      Ezagent.Behavior.Session.Membership.mount_participation_caps(
        session_uri,
        member_uri
      )

    :ok
  end

  defp invite_result(socket, session_uri, _workspace_uri, :ok),
    do: SessionContext.invite_ok(socket, session_uri)

  defp invite_result(socket, session_uri, _workspace_uri, {:ok, _members}),
    do: SessionContext.invite_ok(socket, session_uri)

  defp invite_result(socket, _session_uri, _workspace_uri, {:error, :unauthorized}) do
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext("Unauthorized — you may not add members to this session.")
     )}
  end

  defp invite_result(socket, _session_uri, workspace_uri, {:error, :cross_workspace_denied}) do
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext(
         "Cross-workspace denied — this session lives in workspace %{workspace}, different from yours. Ask admin for a cross-workspace cap.",
         workspace: URI.to_string(workspace_uri)
       )
     )}
  end

  defp invite_result(socket, _session_uri, _workspace_uri, {:error, reason}) do
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext("Invite failed: %{reason}", reason: inspect(reason))
     )}
  end
end
