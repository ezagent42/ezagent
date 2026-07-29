defmodule EzagentPluginForgejo.ForgejoCallbackPlugTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias EzagentPluginForgejo.ForgejoCallbackPlug

  setup do
    test_pid = self()

    consume = fn redirect_id, state, params ->
      send(test_pid, {:consumed, redirect_id, state, params})

      case params do
        %{code: "bad"} -> {:error, :state_mismatch}
        _ -> {:ok, %{receipt: "r-1"}}
      end
    end

    Application.put_env(:ezagent_plugin_forgejo, :callback_consume_fun, consume)
    on_exit(fn -> Application.delete_env(:ezagent_plugin_forgejo, :callback_consume_fun) end)
    :ok
  end

  defp call(query) do
    conn(:get, "/forgejo/callback?" <> query)
    |> Plug.Conn.fetch_query_params()
    |> ForgejoCallbackPlug.call(ForgejoCallbackPlug.init([]))
  end

  test "hands the code and state to the callback ingress" do
    conn = call("code=the-code&state=st-1")

    assert conn.status == 200
    assert_received {:consumed, "forgejo-oauth", "st-1", %{code: "the-code"}}
  end

  test "a rejected callback answers 400" do
    conn = call("code=bad&state=st-1")

    assert conn.status == 400
  end

  test "a callback missing its parameters is refused without reaching the ingress" do
    conn = call("state=st-1")

    assert conn.status == 400
    refute_received {:consumed, _, _, _}
  end

  # The state and any provider error text are attacker-influenced values that
  # would land in a browser. Echoing them into the response body is how a
  # reflected-XSS or a phishing string gets in.
  test "does not echo the state or provider text back to the browser" do
    conn = call("code=bad&state=<script>alert(1)</script>")

    refute conn.resp_body =~ "<script>"
    refute conn.resp_body =~ "state_mismatch"
  end

  test "responds as plain text" do
    conn = call("code=the-code&state=st-1")

    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
  end
end
