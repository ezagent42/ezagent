defmodule EzagentWeb.Socialware.ChatFeedController do
  @moduledoc """
  P4 — authenticated entrypoint for the CHAT external SPA (codex finding 3).

  The chat analogue of `EzagentWeb.Socialware.CustomerController.show/2`, with
  one crucial difference in how the page authenticates: a customer feed is read
  by an anonymous-but-token-bound CUSTOMER, but a chat feed is read by the chat
  session's MEMBERS, so the viewer must be a SIGNED-IN principal.

  ## How the member principal is authenticated

  This route is mounted under the `EzagentWeb.Plugs.RequireEntity` pipeline (the
  SAME gate the operator LiveViews use), so by the time `show/2` runs,
  `conn.assigns.current_entity_uri` is the authenticated, signed-in principal's
  canonical `entity://<ws>/<user|agent>/<name>` `%URI{}` (recovered from the
  session cookie + validated by the plug). There is no separate auth path: the
  member proves identity via the normal web login, exactly like reaching
  `/sessions` or `/identities`.

  The controller then mints a `ChatFeedAuth.issue_token(principal_uri,
  session_uri)` — a server-signed token binding THAT principal to THAT session —
  and embeds it in the SPA shell. The token is NOT the authorization; the live
  `ChatMembership` predicate re-checks membership on every channel join/replay,
  so an authenticated NON-member is denied at the channel (the page renders, the
  feed shows "Unauthorized"). The page is parameterized to point the shared
  `customer_app.js` at the chat socket + chat topic prefix.
  """
  use EzagentWeb, :controller

  alias Ezagent.Socialware.ChatFeedAuth

  @doc """
  Render the chat external SPA shell for the authenticated principal viewing
  `session_uri`. Requires `?session_uri=<session://...>`; the principal comes
  from the RequireEntity-populated `conn.assigns.current_entity_uri`.
  """
  def show(conn, %{"session_uri" => session_str}) do
    with %URI{} = principal_uri <- conn.assigns[:current_entity_uri],
         {:ok, session_uri} <- parse_session(session_str) do
      token = ChatFeedAuth.issue_token(principal_uri, session_uri)

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, page(session_uri, token))
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "missing or invalid session_uri")
    end
  end

  def show(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "missing session_uri")
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

  # The SPA shell. Identical structure to CustomerController.page/2, but the
  # mount element carries `data-socket-path` + `data-topic-prefix` so the shared
  # customer_app.js connects to the chat socket + chat topic. The customer page
  # sets NEITHER attribute, so it stays byte-identical to before.
  defp page(session_uri, token) do
    session = session_uri |> uri_to_string() |> escape()
    token = escape(token)

    """
    <!doctype html>
    <html lang="en" data-theme="customer">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Socialware Chat</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap">
        <link rel="stylesheet" href="/assets/css/customer.css">
        <script defer type="module" src="/assets/js/customer_app.js"></script>
      </head>
      <body class="min-h-screen bg-base-200 text-base-content antialiased">
        <main id="socialware-customer-root" class="block min-h-screen w-full px-4 py-8 sm:py-12" data-session-uri="#{session}" data-token="#{token}" data-socket-path="/socialware_chat_socket" data-topic-prefix="socialware:chat_feed"></main>
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
