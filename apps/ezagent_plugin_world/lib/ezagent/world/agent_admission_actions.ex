defmodule Ezagent.World.AgentAdmissionActions do
  @moduledoc """
  Dispatch and projection plumbing for credential-gated agent admission.

  Admission is restricted to the conversation currently displayed by the
  socket. PTY-backed attempts additionally revalidate the provisional agent
  before handing control to the shared terminal-opening path.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ezagent.World.{AdmissionProjection, ConversationActions}
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission

  @doc "Starts credential admission for a role in the currently displayed session."
  @spec begin(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def begin(socket, sid, role_name) when is_binary(role_name) do
    with_current_session(socket, sid, fn session_uri ->
      caller = socket |> Map.fetch!(:assigns) |> Map.fetch!(:current_entity_uri)
      caps = Ezagent.World.PresenterCaps.load(socket)

      case AgentAdmission.begin(session_uri, role_name, caller, caps) do
        {:ok, admission} ->
          socket = push_admission_state(socket, session_uri)

          if pty_admission?(admission) do
            switch_to_admission_pty(socket, session_uri, admission)
          else
            {:noreply, socket}
          end

        {:error, reason} ->
          error(socket, reason)
      end
    end)
  end

  @doc "Completes the active credential-admission attempt and refreshes its projection."
  @spec complete(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def complete(socket, sid, role_name, attempt_id)
      when is_binary(role_name) and is_binary(attempt_id) do
    with_current_session(socket, sid, fn session_uri ->
      caller = socket |> Map.fetch!(:assigns) |> Map.fetch!(:current_entity_uri)
      caps = Ezagent.World.PresenterCaps.load(socket)

      case AgentAdmission.complete(session_uri, role_name, attempt_id, {caller, caps}) do
        {:ok, _admission} ->
          {:noreply, push_admission_state(socket, session_uri)}

        {:error, reason} ->
          error(socket, reason)

        {:error, reason, _admission} ->
          socket |> push_admission_state(session_uri) |> error(reason)
      end
    end)
  end

  @doc "Cancels the active credential-admission attempt for a session role."
  @spec cancel(Phoenix.LiveView.Socket.t(), String.t(), String.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def cancel(socket, sid, role_name, attempt_id)
      when is_binary(role_name) and is_binary(attempt_id) do
    with_current_session(socket, sid, fn session_uri ->
      caller = socket |> Map.fetch!(:assigns) |> Map.fetch!(:current_entity_uri)
      caps = Ezagent.World.PresenterCaps.load(socket)

      case AgentAdmission.cancel(session_uri, role_name, attempt_id, {caller, caps}) do
        {:ok, _admission} -> {:noreply, push_admission_state(socket, session_uri)}
        {:error, reason} -> error(socket, reason)
      end
    end)
  end

  @doc "Opens the shared terminal surface for a validated admission candidate."
  @spec open_pty(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def open_pty(socket, sid, agent) when is_binary(agent) do
    with_current_session(socket, sid, &ConversationActions.switch_to_pty(socket, &1, agent))
  end

  defp with_current_session(socket, sid, fun) do
    with {:ok, %URI{scheme: "session"} = session_uri} <- parse_uri(sid),
         %URI{} = current_uri <- socket |> Map.fetch!(:assigns) |> Map.get(:current_session_uri),
         true <- same_uri?(current_uri, session_uri) do
      fun.(session_uri)
    else
      {:ok, _uri} -> error(socket, :bad_session_uri)
      :error -> error(socket, :bad_session_uri)
      _ -> error(socket, :session_not_current)
    end
  end

  defp parse_uri(sid) do
    case Ezagent.URI.parse(sid) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      _ -> :error
    end
  end

  defp pty_admission?(%{connection: {:pty, _descriptor}}), do: true
  defp pty_admission?(_admission), do: false

  defp switch_to_admission_pty(socket, %URI{} = session_uri, admission) do
    with uri when is_binary(uri) <- Map.get(admission, :provisional_agent_uri),
         {:ok, candidate_uri} <- ConversationActions.parse_agent_uri(uri),
         true <- current_candidate?(session_uri, admission, candidate_uri) do
      ConversationActions.switch_to_pty(socket, session_uri, URI.to_string(candidate_uri))
    else
      _ -> error(socket, :stale_agent_admission_attempt)
    end
  end

  defp current_candidate?(session_uri, admission, %URI{} = candidate_uri) do
    candidate = URI.to_string(candidate_uri)
    role_name = Map.fetch!(admission, :role_name)
    attempt_id = Map.fetch!(admission, :attempt_id)

    Enum.any?(AgentAdmission.list(session_uri), fn current ->
      Map.fetch!(current, :role_name) == role_name and
        Map.fetch!(current, :attempt_id) == attempt_id and
        Map.get(current, :provisional_agent_uri) == candidate
    end)
  end

  defp push_admission_state(socket, %URI{} = session_uri) do
    socket
    |> ConversationActions.push_members()
    |> push_world_state(%{"agent_admissions" => AdmissionProjection.list(session_uri)})
  end

  defp push_world_state(socket, updates) do
    state = socket |> Map.fetch!(:assigns) |> Map.get(:world_state, %{}) |> Map.merge(updates)

    socket
    |> assign(:world_state, state)
    |> assign(:world_state_json, Jason.encode!(state))
    |> assign(:last_dispatch_status, "ok")
    |> push_event("world:state", updates)
  end

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: URI.to_string(left) == URI.to_string(right)

  defp error(socket, reason) do
    {:noreply, assign(socket, :last_dispatch_status, "error:#{format_reason(reason)}")}
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
