defmodule EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlugIntegrationTest do
  @moduledoc """
  P1 test-supplement (security triage) — the inbound HTTP contract of the
  authenticated `/v1/chat/completions` endpoint: authn rejection (401),
  bad-credential rejection (400 invalid_token, fail-closed — no live
  session/agent needed since `ApiKeyStore.verify/1` short-circuits the
  `with` pipeline before any dispatch), and malformed-method/path
  rejection (400/405).

  Two of the three ORIGINAL tests in this file were `@tag :skip` with
  assertions that do not match the plug's real behavior (diagnosed and
  fixed in this PR — see the two lower `describe` blocks for the
  corrected/replacement versions):

    * "GET without request id" asserted 405 + "only POST", but
      `call/2`'s `{"GET", :error}` branch actually returns 400 +
      "missing request id in path". Fixed below to assert the real
      response; a genuine 405 needs a THIRD method (neither GET nor
      POST) — added as a new test.
    * "wrong secret -> 400 invalid_token" built a conn via bare
      `Plug.Test.conn/3` and called the Plug directly, bypassing
      `Plug.Parsers` (which normally runs at the Endpoint before the
      router `forward`s here). `RequestNormalizer.parse_body/1` reads
      `conn.body_params`, which stays `%Plug.Conn.Unfetched{}` without
      that step — see the KNOWN GAP test in `request_normalizer_test.exs`
      for why that does NOT error out on its own. Fixed below by running
      `Plug.Parsers` in the test's `conn/2` helper, mirroring what the
      real router pipeline does before forwarding to this Plug.

  The THIRD skipped test ("202 when conversation_id missing, valid API
  key") is left skipped — it requires the full agent-spawn + session-join
  runtime (`LocalRuntime.ensure_started/1` + `Process.sleep(3000)` +
  `wait_for_kind_registry/1`), which needs a live Kind supervision tree
  this suite does not stand up. Exercising that path is out of scope for
  an honest-number test-only PR (see PR body for the coverage rationale).
  """

  use EzagentCore.DataCase, async: true
  alias Ezagent.ProtocolApi.ApiKeyStore
  alias EzagentCore.Repo

  describe "POST /v1/chat/completions — authn rejection" do
    test "returns 401 when no Bearer token" do
      body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})
      conn = conn(body) |> EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug.call([])

      assert conn.status == 401
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "missing_token"
    end

    test "returns 400 invalid_token when the API key secret is wrong (fail-closed, no dispatch)" do
      key_id = "iw#{System.unique_integer([:positive, :monotonic])}"
      hash = Bcrypt.hash_pwd_salt("right")

      Repo.insert!(%ApiKeyStore{
        key_id: key_id,
        secret_hash: hash,
        entity_uri: "entity://system/agent/py_default",
        workspace_uri: "workspace://system",
        label: "test",
        allowed_models: [],
        cap_policy: %{}
      })

      body =
        Jason.encode!(%{
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "conversation_id" => "conv_test"
        })

      conn =
        conn(body, "pk_#{key_id}_wrong")
        |> EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "invalid_token"
    end

    test "returns 400 invalid_token for an entirely unknown key_id (same rejection shape as wrong-secret)" do
      body =
        Jason.encode!(%{
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "conversation_id" => "conv_test"
        })

      conn =
        conn(body, "pk_never_issued_anysecret")
        |> EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "invalid_token"
    end

    @tag :skip
    test "returns 202 when conversation_id missing (stateless) (valid API key)" do
      # Requires the live agent-spawn + session-join runtime — see
      # moduledoc. Left skipped (pre-existing skip, cause re-diagnosed in
      # this PR, not newly introduced).
      key_id = "ik#{System.unique_integer([:positive, :monotonic])}"
      hash = Bcrypt.hash_pwd_salt("s1")

      Repo.insert!(%ApiKeyStore{
        key_id: key_id,
        secret_hash: hash,
        entity_uri: "entity://system/agent/py_default",
        workspace_uri: "workspace://system",
        label: "test",
        allowed_models: [],
        cap_policy: %{}
      })

      body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

      conn =
        conn(body, "pk_#{key_id}_s1")
        |> EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug.call([])

      assert conn.status == 202
      resp = Jason.decode!(conn.resp_body)
      assert resp["status"] == "processing"
    end
  end

  describe "malformed method/path rejection" do
    test "GET without a request id in the path -> 400 missing request id (NOT 405 — fixed stale assertion)" do
      conn =
        Plug.Test.conn(:get, "/v1/chat/completions")
        |> EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "missing request id in path"
    end

    test "an unsupported method (PUT) -> 405 only POST/GET is supported" do
      conn =
        Plug.Test.conn(:put, "/v1/chat/completions")
        |> EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug.call([])

      assert conn.status == 405
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "only POST/GET is supported"
    end

    test "GET /v1/chat/completions/:id for an id never registered -> 404" do
      conn =
        Plug.Test.conn(:get, "/v1/chat/completions/never-existed-id")
        |> EzagentPluginProtocolApi.OpenAI.ChatCompletionsPlug.call([])

      assert conn.status == 404
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "not found"
    end
  end

  # Builds a conn the way the REAL router pipeline does: run Plug.Parsers
  # (JSON) before the Plug sees it, so `conn.body_params` is a real fetched
  # map rather than `%Plug.Conn.Unfetched{}` (bare `Plug.Test.conn/3` never
  # runs the Endpoint's parser stack on its own — see the moduledoc's
  # "KNOWN GAP" cross-reference for what happens if this step is skipped).
  defp conn(body, bearer \\ nil) do
    parsers_opts =
      Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason)

    c =
      Plug.Test.conn(:post, "/v1/chat/completions", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(parsers_opts)

    if bearer, do: Plug.Conn.put_req_header(c, "authorization", "Bearer #{bearer}"), else: c
  end
end
