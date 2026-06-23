defmodule Ezagent.Email.Inbox.CFWorkerTest do
  use ExUnit.Case, async: false
  alias Ezagent.Email.Inbox.CFWorker

  @cfg %{"backend" => "cf_worker", "pull_url" => "https://w.example.dev", "pull_token" => "tok"}

  defp stub(fun) do
    Application.put_env(:ezagent_plugin_email, :http_request_fun, fun)
    on_exit(fn -> Application.delete_env(:ezagent_plugin_email, :http_request_fun) end)
  end

  test "list builds GET /inbox?to= with bearer and decodes records" do
    stub(fn :get, {url, headers}, _http_opts, _opts ->
      assert url == ~c"https://w.example.dev/inbox?to=a%40ezagent.chat"
      assert {~c"authorization", ~c"Bearer tok"} in headers
      body = Jason.encode!(%{"count" => 1, "emails" => [%{"key" => "k1", "subject" => "S"}]})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], String.to_charlist(body)}}
    end)

    assert {:ok, [%{"key" => "k1", "subject" => "S"}]} = CFWorker.list(@cfg, to: "a@ezagent.chat")
  end

  test "delete issues DELETE /inbox/<key> and returns :ok on 204" do
    stub(fn :delete, {url, headers}, _http_opts, _opts ->
      assert url == ~c"https://w.example.dev/inbox/k1"
      assert {~c"authorization", ~c"Bearer tok"} in headers
      {:ok, {{~c"HTTP/1.1", 204, ~c"No Content"}, [], ~c""}}
    end)

    assert :ok = CFWorker.delete(@cfg, "k1")
  end

  test "non-2xx maps to {:error, {:http, status}}" do
    stub(fn :get, _req, _http_opts, _opts -> {:ok, {{~c"HTTP/1.1", 500, ~c"err"}, [], ~c"boom"}} end)
    assert {:error, {:http, 500}} = CFWorker.list(@cfg, [])
  end

  test "fetch 404 maps to :not_found" do
    stub(fn :get, _req, _http_opts, _opts -> {:ok, {{~c"HTTP/1.1", 404, ~c"nf"}, [], ~c"x"}} end)
    assert {:error, :not_found} = CFWorker.fetch(@cfg, "missing")
  end

  test "facade returns :backend_not_implemented for non-cf backend" do
    System.put_env("EZAGENT_EMAIL_PULL_URL", "https://w.example.dev")
    System.put_env("EZAGENT_EMAIL_PULL_TOKEN", "tok")
    System.put_env("EZAGENT_EMAIL_BACKEND", "imap")

    on_exit(fn ->
      System.delete_env("EZAGENT_EMAIL_PULL_URL")
      System.delete_env("EZAGENT_EMAIL_PULL_TOKEN")
      System.delete_env("EZAGENT_EMAIL_BACKEND")
    end)

    assert {:error, :backend_not_implemented} = Ezagent.Email.inbox([])
  end
end
