defmodule EzagentWeb.HelloDelegationController do
  @moduledoc """
  Thin HTTP adapter for hello-to-Kanban delegation and login continuation.
  """

  use EzagentWeb, :controller

  alias EzagentWeb.HelloDelegationContinuation

  @token_key :hello_delegation_token
  @digest_key :hello_delegation_digest
  @consumed_key :hello_delegation_consumed_digest

  @doc false
  def create(conn, %{"session_uri" => session_str, "instruction" => instruction})
      when is_binary(session_str) and is_binary(instruction) do
    with {:ok, %URI{scheme: "session"} = session_uri} <- Ezagent.URI.parse(session_str),
         true <- hello_session?(session_uri) do
      case current_entity(conn) do
        {:ok, caller} -> start_and_return(conn, session_uri, instruction, caller)
        :error -> stage_for_login(conn, session_uri, instruction)
      end
    else
      _ ->
        conn
        |> put_flash(:error, "Invalid hello delegation request.")
        |> redirect(to: "/sessions")
    end
  end

  def create(conn, _params),
    do: conn |> put_flash(:error, "Instruction is required.") |> redirect(to: "/sessions")

  @doc false
  def resume(conn, _params) do
    token = get_session(conn, @token_key)
    expected_digest = get_session(conn, @digest_key)
    consumed_digest = get_session(conn, @consumed_key)

    with token when is_binary(token) <- token,
         digest when is_binary(digest) <- expected_digest,
         ^digest <- token_digest(token),
         false <- digest == consumed_digest,
         {:ok, payload} <- HelloDelegationContinuation.verify(token),
         {:ok, caller} <- current_entity(conn) do
      conn
      |> delete_session(@token_key)
      |> delete_session(@digest_key)
      |> put_session(@consumed_key, digest)
      |> start_and_return(payload.session_uri, payload.instruction, caller)
    else
      _ -> conn |> put_flash(:error, "No pending hello delegation.") |> redirect(to: "/sessions")
    end
  end

  defp stage_for_login(conn, session_uri, instruction) do
    token = HelloDelegationContinuation.sign(session_uri, instruction)

    conn
    |> put_session(@token_key, token)
    |> put_session(@digest_key, token_digest(token))
    |> redirect(to: "/login?return_to=%2Fhello%2Fdelegate%2Fresume")
  rescue
    ArgumentError ->
      conn |> put_flash(:error, "Invalid hello delegation request.") |> redirect(to: "/sessions")
  end

  defp start_and_return(conn, session_uri, instruction, caller) do
    case delegation_start().(session_uri, String.trim(instruction), caller) do
      {:ok, _pid} ->
        conn |> put_flash(:info, "Delegation started.") |> redirect(to: page_path(session_uri))

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Kanban delegation is unavailable.")
        |> redirect(to: page_path(session_uri))
    end
  end

  defp current_entity(conn) do
    case get_session(conn, :current_entity_uri) do
      value when is_binary(value) ->
        case Ezagent.URI.parse(value) do
          {:ok, %URI{scheme: "entity"} = uri} -> {:ok, uri}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp delegation_start do
    Application.get_env(:ezagent_web, :hello_kanban_delegation_start, fn session,
                                                                         instruction,
                                                                         caller ->
      EzagentPluginHello.KanbanDelegation.start(session, instruction, caller)
    end)
  end

  defp token_digest(token),
    do: token |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)

  defp hello_session?(session_uri), do: match?({:ok, "hello"}, Ezagent.URI.type(session_uri))

  defp page_path(%URI{} = session_uri) do
    case Ezagent.URI.name(session_uri) do
      {:ok, name} -> "/hello/" <> URI.encode_www_form(name)
      :error -> "/sessions"
    end
  end
end
