defmodule EzagentPluginGithub.GitHubCallbackPlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias EzagentPluginGithub.GitHubCallbackPlug

  defmodule CallbackIngressMock do
    def consume("github-oauth", "test-state-ok", %{code: "test-code"}) do
      {:ok, %{receipt: "mock-receipt"}}
    end

    def consume(_, _, _) do
      {:error, :callback_invalid}
    end
  end

  setup do
    Application.put_env(
      :ezagent_plugin_github,
      :callback_ingress_module,
      CallbackIngressMock
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :callback_ingress_module)
    end)

    :ok
  end

  describe "call/2" do
    test "returns 200 with success message when code and state are valid" do
      conn =
        :get
        |> Plug.Test.conn("/github/callback?code=test-code&state=test-state-ok")
        |> Plug.Conn.fetch_query_params()
        |> GitHubCallbackPlug.call([])

      assert conn.status == 200
      assert conn.resp_body == "GitHub authorization complete. You may close this page."
    end

    test "returns 400 when code is missing" do
      conn =
        :get
        |> Plug.Test.conn("/github/callback?state=test-state")
        |> Plug.Conn.fetch_query_params()
        |> GitHubCallbackPlug.call([])

      assert conn.status == 400
      assert conn.resp_body == "Missing code or state parameter"
    end

    test "returns 400 when state is missing" do
      conn =
        :get
        |> Plug.Test.conn("/github/callback?code=test-code")
        |> Plug.Conn.fetch_query_params()
        |> GitHubCallbackPlug.call([])

      assert conn.status == 400
      assert conn.resp_body == "Missing code or state parameter"
    end

    test "returns 400 when both code and state are missing" do
      conn =
        :get
        |> Plug.Test.conn("/github/callback")
        |> Plug.Conn.fetch_query_params()
        |> GitHubCallbackPlug.call([])

      assert conn.status == 400
      assert conn.resp_body == "Missing code or state parameter"
    end

    test "returns 400 with error reason when callback ingress fails" do
      conn =
        :get
        |> Plug.Test.conn("/github/callback?code=bad-code&state=bad-state")
        |> Plug.Conn.fetch_query_params()
        |> GitHubCallbackPlug.call([])

      assert conn.status == 400
      assert conn.resp_body =~ "Authorization failed:"
    end
  end
end
