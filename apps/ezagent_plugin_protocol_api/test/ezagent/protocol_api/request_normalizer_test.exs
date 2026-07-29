defmodule Ezagent.ProtocolApi.RequestNormalizerTest do
  @moduledoc """
  P1 test-supplement (security triage) — inbound normalization for the LLM
  Protocol API. Malformed-input rejection paths: missing/malformed bearer,
  empty/invalid JSON body, conversation_id precedence.
  """

  use ExUnit.Case, async: true

  alias Ezagent.ProtocolApi.RequestNormalizer

  describe "extract_bearer/1" do
    test "extracts the token from a well-formed Authorization header" do
      conn = conn_with_headers([{"authorization", "Bearer pk_abc_def"}])
      assert {:ok, "pk_abc_def"} = RequestNormalizer.extract_bearer(conn)
    end

    test "missing Authorization header → 401 missing_token" do
      conn = conn_with_headers([])
      assert {:error, 401, "missing_token", _} = RequestNormalizer.extract_bearer(conn)
    end

    test "wrong auth scheme (Basic, not Bearer) → 401 missing_token" do
      conn = conn_with_headers([{"authorization", "Basic dXNlcjpwYXNz"}])
      assert {:error, 401, "missing_token", _} = RequestNormalizer.extract_bearer(conn)
    end

    test "case-sensitive scheme: lowercase 'bearer' is rejected" do
      conn = conn_with_headers([{"authorization", "bearer pk_abc_def"}])
      assert {:error, 401, "missing_token", _} = RequestNormalizer.extract_bearer(conn)
    end

    test "'Bearer ' with an empty token is accepted HERE (empty-string token) — downstream ApiKeyStore.verify/1 rejects it" do
      # Pin the actual contract: extract_bearer/1 only strips the scheme
      # prefix, it does not itself reject an empty credential. Defense in
      # depth against a malformed/empty bearer lives in
      # Ezagent.ProtocolApi.ApiKeyStore.verify/1 (parse_token/1 rejects
      # any token not shaped pk_<key_id>_<secret>, including "").
      conn = conn_with_headers([{"authorization", "Bearer "}])
      assert {:ok, ""} = RequestNormalizer.extract_bearer(conn)
    end
  end

  describe "parse_body/1" do
    test "a real, non-empty parsed JSON body → {:ok, body}" do
      conn = %Plug.Conn{body_params: %{"messages" => []}}
      assert {:ok, %{"messages" => []}} = RequestNormalizer.parse_body(conn)
    end

    test "an empty parsed body (%{}) → 400 bad_json" do
      conn = %Plug.Conn{body_params: %{}}
      assert {:error, 400, "bad_json", _} = RequestNormalizer.parse_body(conn)
    end

    test "KNOWN GAP: an unfetched body_params (Plug.Parsers never ran) does NOT hit the 400 branch" do
      # Reported as a finding, not fixed here (test-only PR; no product-code
      # change without STOP + coordinator sign-off).
      #
      # The moduledoc/docstring says an "unfetched/empty map" is "treat[ed]
      # ... as a bad request", but the actual guard is:
      #
      #     body_params != %Plug.Conn.Unfetched{} and map_size(body_params) > 0
      #
      # `%Plug.Conn.Unfetched{}` defaults to `aspect: nil`, while the REAL
      # sentinel Plug.Conn leaves on an unfetched `body_params` field is
      # `%Plug.Conn.Unfetched{aspect: :body_params}` — so the `!=` comparison
      # is ALWAYS true (they're never equal) and this guard never actually
      # detects "unfetched". Compounding it, `map_size/1` on ANY struct
      # counts `__struct__` + its fields, so
      # `map_size(%Plug.Conn.Unfetched{aspect: :body_params})` == 2, which
      # also satisfies `> 0`. Net effect: parse_body/1 returns
      # `{:ok, %Plug.Conn.Unfetched{aspect: :body_params}}` instead of the
      # documented 400 rejection.
      #
      # Reachability in production: `EzagentWeb.Endpoint`'s `Plug.Parsers`
      # is configured `pass: ["*/*"]` — a request whose Content-Type isn't
      # urlencoded/multipart/json (or that carries no Content-Type at all)
      # is passed through UNPARSED rather than raising, so `body_params`
      # stays unfetched at the `/v1/chat/completions` forward for exactly
      # that request shape. A caller with a VALID Bearer token but the
      # "wrong" (or absent) Content-Type therefore skips the "invalid or
      # empty JSON body" 400 and falls through to
      # `extract_conversation_id/2` and `build_message/3`, both of which
      # `Map.get/3` the Unfetched struct and silently default to
      # `""` / `[]` — an authenticated request with a malformed body is
      # processed as an EMPTY chat message instead of being rejected.
      #
      # Severity: LOW, not a privilege/auth issue — the caller must
      # already hold a VALID API key (this path is unreachable pre-auth,
      # `extract_bearer/1` still runs and still rejects a missing/bad
      # token normally). The only observable effect is a benign
      # correctness deviation: a malformed/wrong-Content-Type body from
      # an ALREADY-authenticated caller is silently treated as an empty
      # chat message instead of cleanly 400ing. Reported as a secondary
      # finding, not the headline.
      conn = %Plug.Conn{body_params: %Plug.Conn.Unfetched{aspect: :body_params}}

      assert {:ok, %Plug.Conn.Unfetched{aspect: :body_params}} =
               RequestNormalizer.parse_body(conn)
    end
  end

  describe "extract_conversation_id/2" do
    test "body conversation_id takes precedence over the header" do
      conn = conn_with_headers([{"x-conversation-id", "from-header"}])
      body = %{"conversation_id" => "from-body"}
      assert {:ok, "from-body"} = RequestNormalizer.extract_conversation_id(body, conn)
    end

    test "empty-string body conversation_id falls through to the header" do
      conn = conn_with_headers([{"x-conversation-id", "from-header"}])
      body = %{"conversation_id" => ""}
      assert {:ok, "from-header"} = RequestNormalizer.extract_conversation_id(body, conn)
    end

    test "non-string body conversation_id falls through to the header" do
      conn = conn_with_headers([{"x-conversation-id", "from-header"}])
      body = %{"conversation_id" => 12345}
      assert {:ok, "from-header"} = RequestNormalizer.extract_conversation_id(body, conn)
    end

    test "neither body nor header present → {:ok, nil} (stateless/ephemeral fallback)" do
      conn = conn_with_headers([])
      assert {:ok, nil} = RequestNormalizer.extract_conversation_id(%{}, conn)
    end
  end

  # ----- helpers -------------------------------------------------------

  defp conn_with_headers(headers) do
    %Plug.Conn{req_headers: headers}
  end
end
