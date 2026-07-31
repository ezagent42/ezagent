defmodule EzagentPluginFeishu.WebhookPlug do
  @moduledoc """
  Feishu webhook receiver — HTTP transport (currently DISABLED, see #204).

  Two payload shapes Feishu sends:
  1. **URL verification challenge** (`{type: "url_verification", challenge: "X"}`)
     → respond `{challenge: "X"}` so Feishu validates the endpoint
  2. **Event callback** (`{schema: "2.0", header: {...}, event: {...}}`)
     → if event is a message in a bound chat, dispatch into the session

  ## Route registration — REMOVED for #204

  This plug used to be mounted publicly in ezagent_web's router.ex:
      forward "/api/feishu/webhook", EzagentPluginFeishu.WebhookPlug

  That route was **removed** for #204. The endpoint was unauthenticated at
  the network level (no `Encrypt-Key` / signature verification — see "Auth"
  below), and Feishu app access-control does not protect the raw HTTP
  endpoint. Once bindings exist, a forged POST carrying a victim's `open_id`
  → `SenderResolver` → impersonation. Production Feishu inbound flows over
  the authenticated WS long-connection (`EzagentPluginFeishu.WsClient`),
  which feeds the SAME `EzagentPluginFeishu.InboundDispatcher` and is
  unaffected by the route removal.

  The module is **retained but unmounted**: its parse → decode → dispatch
  logic (`EventDecoder` + `InboundDispatcher`) is shared with `WsClient` and
  stays under test. Re-exposing the HTTP transport requires implementing the
  #204 signature verification below FIRST, then re-adding the router forward.

  ## Auth — the #204 gap

  The webhook is unauthenticated at the network level (Feishu can't carry
  Ezagent session cookies). Before this plug may be re-mounted, validate the
  `Encrypt-Key` header signature (Feishu event-subscription encryption /
  `verification_token`) so forged POSTs are rejected.
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    # Plug.Parsers (JSON) runs before forwarded routes, so the body has
    # already been consumed. Use conn.body_params (already a map).
    # Fallback to re-reading raw bytes for clients that bypass parsers.
    payload =
      cond do
        is_map(conn.body_params) and conn.body_params != %{} and
            not match?(%Plug.Conn.Unfetched{}, conn.body_params) ->
          {:ok, conn.body_params}

        true ->
          case read_body(conn) do
            {:ok, body, _} when is_binary(body) and body != "" -> Jason.decode(body)
            _ -> {:error, :empty_body}
          end
      end

    case payload do
      {:ok, %{"type" => "url_verification", "challenge" => challenge}} ->
        Logger.info("EzagentPluginFeishu webhook: URL verification challenge")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{challenge: challenge}))

      {:ok, %{"schema" => "2.0", "header" => header, "event" => event}} ->
        handle_event(header, event)
        conn |> put_resp_content_type("application/json") |> send_resp(200, "{}")

      {:ok, other} ->
        Logger.warning(
          "EzagentPluginFeishu webhook: unrecognized payload keys: #{inspect(Map.keys(other))}"
        )

        send_resp(conn, 200, "{}")

      {:error, reason} ->
        Logger.warning("EzagentPluginFeishu webhook: bad payload: #{inspect(reason)}")
        send_resp(conn, 400, "bad payload")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 405, "method not allowed")

  defp handle_event(_header, %{"message" => msg, "sender" => sender}) do
    chat_id = Map.get(msg, "chat_id")
    message_id = Map.get(msg, "message_id")
    body = EzagentPluginFeishu.EventDecoder.build_body(msg)

    cond do
      is_nil(chat_id) ->
        Logger.warning("Feishu webhook: missing chat_id")

      body.text == "" and body.attachments == [] ->
        Logger.debug(
          "Feishu webhook: empty body for message_type=#{inspect(Map.get(msg, "message_type"))} — drop"
        )

      true ->
        EzagentPluginFeishu.InboundDispatcher.dispatch(
          chat_id: chat_id,
          message_id: message_id,
          sender: sender,
          body: body,
          origin: nil
        )
    end
  end

  defp handle_event(_header, other),
    do: Logger.debug("Feishu webhook: unhandled event shape: #{inspect(Map.keys(other))}")

  # Phase 6 PR 15: body construction + session lookup + sender resolution
  # all moved out:
  #   - EzagentPluginFeishu.EventDecoder.build_body/1  (shared with WsClient)
  #   - EzagentPluginFeishu.InboundDispatcher          (shared with WsClient)
  # WebhookPlug is now a thin HTTP transport: parse → decode → dispatch.
end
