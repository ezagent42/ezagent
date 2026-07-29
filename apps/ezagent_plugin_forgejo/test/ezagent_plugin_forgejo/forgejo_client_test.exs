defmodule EzagentPluginForgejo.ForgejoClientTest do
  use ExUnit.Case, async: true

  alias EzagentPluginForgejo.ForgejoClient

  @stub_name :forgejo_client_test
  @base "https://code.hyprial.test/api/v1"

  defp stub(fun) do
    Req.Test.stub(@stub_name, fun)
    [plug: {Req.Test, @stub_name}]
  end

  describe "authentication" do
    # Forgejo's swagger is explicit: "API tokens must be prepended with `token`
    # followed by a space." Copying GitHub's `Bearer` here yields 401 against a
    # real instance.
    test "get sends the PAT with the `token` scheme, not `Bearer`" do
      opts =
        stub(fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["token test-pat"]
          Req.Test.json(conn, %{"ok" => true})
        end)

      assert {:ok, %{"ok" => true}} = ForgejoClient.get(@base, "/version", "test-pat", opts)
    end

    test "post sends the PAT with the `token` scheme" do
      opts =
        stub(fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["token test-pat"]
          Req.Test.json(conn, %{"ok" => true})
        end)

      assert {:ok, %{"ok" => true}} =
               ForgejoClient.post(@base, "/repos/o/r/branches", "test-pat", %{a: 1}, opts)
    end

    test "the request is addressed to the per-instance base URL" do
      opts =
        stub(fn conn ->
          assert conn.host == "code.hyprial.test"
          assert conn.request_path == "/api/v1/repos/o/r"
          Req.Test.json(conn, %{"ok" => true})
        end)

      assert {:ok, _} = ForgejoClient.get(@base, "/repos/o/r", "test-pat", opts)
    end
  end

  describe "status mapping" do
    for {status, expected} <- [
          {401, :authentication_rejected},
          {403, :provider_denied},
          {404, :not_found},
          {409, :conflict},
          {413, :quota_exceeded},
          {423, :repository_archived},
          {429, :provider_rate_limited},
          {500, :provider_unavailable},
          {502, :provider_unavailable}
        ] do
      test "maps #{status} to #{expected}" do
        opts = stub(fn conn -> Plug.Conn.resp(conn, unquote(status), ~s({"message":"x"})) end)

        assert {:error, unquote(expected)} =
                 ForgejoClient.get(@base, "/repos/o/r", "pat", opts)
      end
    end
  end

  # Forgejo overloads 422 across three situations the write path must tell
  # apart. The message strings below are VERBATIM from live probes against
  # code.hyprial.com (findings §3.3) -- not invented, not paraphrased.
  describe "422 sub-classification" do
    test "`branch already exists` classifies as branch_exists" do
      opts =
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            422,
            ~s({"message":"branch already exists [name: task/probe/run-dates01]"})
          )
        end)

      assert {:error, :branch_exists} =
               ForgejoClient.post(@base, "/repos/o/r/contents", "pat", %{}, opts)
    end

    test "`repository file already exists` classifies as file_exists" do
      opts =
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            422,
            ~s({"message":"repository file already exists [path: probe/a.txt]"})
          )
        end)

      assert {:error, :file_exists} =
               ForgejoClient.post(@base, "/repos/o/r/contents", "pat", %{}, opts)
    end

    test "`a SHA or commit ID must be provided` classifies as sha_required" do
      opts =
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            422,
            ~s({"message":"a SHA or commit ID must be provided when updating a file"})
          )
        end)

      assert {:error, :sha_required} =
               ForgejoClient.post(@base, "/repos/o/r/contents", "pat", %{}, opts)
    end

    test "an unrecognised 422 stays the neutral unprocessable_entity" do
      opts =
        stub(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(422, ~s({"message":"something else entirely"}))
        end)

      assert {:error, :unprocessable_entity} =
               ForgejoClient.post(@base, "/repos/o/r/contents", "pat", %{}, opts)
    end

    test "a 422 with an unparseable body stays the neutral unprocessable_entity" do
      opts = stub(fn conn -> Plug.Conn.resp(conn, 422, "<html>not json</html>") end)

      assert {:error, :unprocessable_entity} =
               ForgejoClient.post(@base, "/repos/o/r/contents", "pat", %{}, opts)
    end
  end

  # Design §8.3. A transport failure means the remote state is UNKNOWN -- the
  # request may or may not have taken effect server-side. A 5xx means the
  # request arrived and was refused. Collapsing both into one code (the known
  # defect the GitHub client still carries) hides exactly the distinction the
  # write path's crash-window recovery turns on.
  describe "transport failure vs provider 5xx" do
    test "a transport failure is provider_unreachable, distinct from 5xx" do
      opts = stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, :provider_unreachable} =
               ForgejoClient.get(@base, "/repos/o/r", "pat", opts)
    end

    test "a transport failure is surfaced after exactly one request, not retried" do
      test_pid = self()

      opts =
        stub(fn conn ->
          send(test_pid, :request_made)
          Req.Test.transport_error(conn, :timeout)
        end)

      assert {:error, :provider_unreachable} =
               ForgejoClient.get(@base, "/repos/o/r", "pat", opts)

      assert_received :request_made
      refute_received :request_made
    end
  end
end
