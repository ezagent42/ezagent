defmodule EzagentWeb.PatDelivery do
  @moduledoc "One-time browser delivery for PATs minted by interactive login."

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias EzagentWeb.{AuthBoundaryLayout, SessionPrincipal}

  @label "interactive-login"
  @token_key :pending_personal_access_token
  @return_key :pending_pat_return_to

  @doc "Rotate the interactive-login PAT and stage it for one-time delivery."
  @spec issue(Plug.Conn.t(), URI.t(), String.t()) :: {:ok, Plug.Conn.t()} | {:error, term()}
  def issue(conn, %URI{} = principal, return_to) do
    case Ezagent.Entity.Token.rotate_label(principal, @label) do
      {:error, reason} ->
        {:error, reason}

      {token, _row} ->
        {:ok,
         conn
         |> SessionPrincipal.put(URI.to_string(principal), workspace: nil)
         |> put_session(@token_key, token)
         |> put_session(@return_key, safe_return_to(return_to))}
    end
  end

  @doc "Render and erase the staged PAT; refreshes cannot reveal it again."
  @spec render_once(Plug.Conn.t()) :: Plug.Conn.t()
  def render_once(conn) do
    case get_session(conn, @token_key) do
      token when is_binary(token) ->
        return_to = get_session(conn, @return_key) || "/sessions"

        body =
          AuthBoundaryLayout.head_html("ezagent · personal access token") <>
            AuthBoundaryLayout.body_open() <>
            AuthBoundaryLayout.card_open() <>
            "<p class=\"brand\">ezagent</p>" <>
            "<h1>Your new personal access token</h1>" <>
            "<p>Copy it now. It will not be shown again.</p>" <>
            "<code id=\"one-time-personal-access-token\">#{escape(token)}</code>" <>
            "<p><a id=\"continue-after-token\" href=\"#{escape(return_to)}\">Continue</a></p>" <>
            AuthBoundaryLayout.card_close() <>
            AuthBoundaryLayout.body_close()

        conn
        |> delete_session(@token_key)
        |> delete_session(@return_key)
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_content_type("text/html")
        |> send_resp(200, body)

      _ ->
        redirect(conn, to: "/sessions")
    end
  end

  defp safe_return_to(path)
       when is_binary(path) and byte_size(path) > 0 and
              not is_nil(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
         not String.starts_with?(path, "/\\"),
       do: path,
       else: "/sessions"
  end

  defp safe_return_to(_), do: "/sessions"

  defp escape(value), do: value |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
end
