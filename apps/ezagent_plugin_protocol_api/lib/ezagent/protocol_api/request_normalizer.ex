defmodule Ezagent.ProtocolApi.RequestNormalizer do
  @moduledoc """
  Shared inbound-request normalization for the LLM Protocol API (#96 Phase 1).

  These helpers are protocol-agnostic: they pull the bearer credential, the
  durable `conversation_id`, and the parsed JSON body off a `Plug.Conn` so each
  per-endpoint plug (OpenAI chat-completions today; OpenAI responses / Anthropic
  messages in Phase 2) reuses one normalization layer instead of duplicating it.

  Provider-specific shaping (e.g. reading the OpenAI `messages` array) stays in
  the endpoint plug; only the transport-level normalization lives here.
  """

  alias Plug.Conn

  @typedoc "Tagged error compatible with the plug's `{:error, status, code, detail}` shape."
  @type tagged_error :: {:error, pos_integer(), String.t(), String.t()}

  @doc """
  Pull the parsed JSON body off the conn.

  Phoenix's `Plug.Parsers` already decodes a JSON body into `conn.body_params`
  when Content-Type is `application/json`, so `read_body/1` returns `""`. We read
  `body_params` and treat an unfetched/empty map as a bad request.
  """
  @spec parse_body(Conn.t()) :: {:ok, map()} | tagged_error()
  def parse_body(conn) do
    body_params = conn.body_params

    if body_params != %Plug.Conn.Unfetched{} and map_size(body_params) > 0 do
      {:ok, body_params}
    else
      {:error, 400, "bad_json", "invalid or empty JSON body"}
    end
  end

  @doc "Extract the `Authorization: Bearer <token>` credential."
  @spec extract_bearer(Conn.t()) :: {:ok, String.t()} | tagged_error()
  def extract_bearer(conn) do
    case Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, 401, "missing_token", "Authorization: Bearer <token> required"}
    end
  end

  @doc """
  Resolve the durable `conversation_id`.

  Precedence: body `conversation_id` → `x-conversation-id` header → `nil`
  (stateless fallback, handoff §2.2, which yields an ephemeral session).
  """
  @spec extract_conversation_id(map(), Conn.t()) :: {:ok, String.t() | nil}
  def extract_conversation_id(body, conn) do
    case Map.get(body, "conversation_id") do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        case Conn.get_req_header(conn, "x-conversation-id") do
          [id | _] when id != "" -> {:ok, id}
          _ -> {:ok, nil}
        end
    end
  end
end
