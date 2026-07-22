defmodule EzagentPluginGithub.GitHubWebhookPlugTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias EzagentPluginGithub.GitHubWebhookPlug

  @secret "plug-webhook-secret"
  @body ~s({"zen":"Keep it logically awesome."})

  setup do
    Application.put_env(:ezagent_plugin_github, :webhook_secret, @secret)
    on_exit(fn -> Application.delete_env(:ezagent_plugin_github, :webhook_secret) end)
    :ok
  end

  defp sign(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end

  test "acknowledges a correctly signed delivery with 202" do
    conn =
      :post
      |> Plug.Test.conn("/github/webhook", @body)
      |> Plug.Conn.put_req_header("x-hub-signature-256", sign(@body, @secret))
      |> GitHubWebhookPlug.call([])

    assert conn.status == 202
  end

  test "rejects a tampered delivery with 401 and halts" do
    conn =
      :post
      |> Plug.Test.conn("/github/webhook", @body)
      |> Plug.Conn.put_req_header("x-hub-signature-256", sign("other body", @secret))
      |> GitHubWebhookPlug.call([])

    assert conn.status == 401
    assert conn.halted
  end

  test "rejects an unsigned delivery with 401" do
    conn =
      :post
      |> Plug.Test.conn("/github/webhook", @body)
      |> GitHubWebhookPlug.call([])

    assert conn.status == 401
  end
end
