defmodule EzagentPluginProtocolApi.OpenaiChatPlugIntegrationTest do
  use EzagentCore.DataCase, async: true
  alias Ezagent.ProtocolApi.ApiKeyStore
  alias EzagentCore.Repo

  describe "POST /v1/chat/completions" do
    test "returns 401 when no Bearer token" do
      body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})
      conn = conn(body) |> EzagentPluginProtocolApi.OpenaiChatPlug.call([])

      assert conn.status == 401
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "missing_token"
    end

    test "returns 202 when conversation_id missing (stateless) (valid API key)" do
      key_id = "ik#{System.unique_integer([:positive, :monotonic])}"
      hash = Bcrypt.hash_pwd_salt("s1")

      Repo.insert!(%ApiKeyStore{
        key_id: key_id,
        secret_hash: hash,
        entity_uri: "entity://system/agent/echo_default",
        workspace_uri: "workspace://system",
        label: "test",
        allowed_models: [],
        cap_policy: %{}
      })

      body = Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "hi"}]})

      conn =
        conn(body, "pk_#{key_id}_s1")
        |> EzagentPluginProtocolApi.OpenaiChatPlug.call([])

      assert conn.status == 202
      resp = Jason.decode!(conn.resp_body)
      assert resp["status"] == "processing"
    end

    test "returns 400 when API key secret is wrong" do
      key_id = "iw#{System.unique_integer([:positive, :monotonic])}"
      hash = Bcrypt.hash_pwd_salt("right")

      Repo.insert!(%ApiKeyStore{
        key_id: key_id,
        secret_hash: hash,
        entity_uri: "entity://system/agent/echo_default",
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
        |> EzagentPluginProtocolApi.OpenaiChatPlug.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "invalid_token"
    end

    test "returns 400 for GET without request id" do
      conn =
        Plug.Test.conn(:get, "/v1/chat/completions")
        |> EzagentPluginProtocolApi.OpenaiChatPlug.call([])

      assert conn.status == 405
      resp = Jason.decode!(conn.resp_body)
      assert resp["error"]["message"] =~ "only POST"
    end
  end

  defp conn(body, bearer \\ nil) do
    c =
      Plug.Test.conn(:post, "/v1/chat/completions", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    if bearer, do: Plug.Conn.put_req_header(c, "authorization", "Bearer #{bearer}"), else: c
  end
end
