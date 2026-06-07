defmodule EzagentWeb.Socialware.CustomerController do
  @moduledoc """
  Public entrypoint for the socialware customer SPA.

  The page authenticates the session-binding token before bootstrapping the
  browser app. Live updates then flow through `CustomerSocket`, which repeats
  the same scoped authorization.
  """
  use EzagentWeb, :controller

  alias Ezagent.Socialware.CustomerFeed

  def show(conn, %{"session_uri" => session_str, "token" => token}) do
    with {:ok, session_uri} <- parse_session(session_str),
         {:ok, _snapshot} <- CustomerFeed.snapshot(session_uri, token) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, page(session_uri, token))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "unauthorized")
    end
  end

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "missing session_uri or token")
  end

  defp parse_session(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_session(_value), do: :error

  defp page(session_uri, token) do
    session = session_uri |> uri_to_string() |> escape()
    token = escape(token)

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Socialware Customer</title>
        <script defer type="module" src="/assets/js/customer_app.js"></script>
      </head>
      <body>
        <main id="socialware-customer-root" data-session-uri="#{session}" data-token="#{token}"></main>
      </body>
    </html>
    """
  end

  defp escape(value) do
    value
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
end
