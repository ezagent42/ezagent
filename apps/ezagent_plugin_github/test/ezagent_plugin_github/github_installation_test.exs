defmodule EzagentPluginGithub.GitHubInstallationTest do
  # async: false — shares the named ETS cache table and global config.
  use ExUnit.Case, async: false

  alias EzagentPluginGithub.GitHubInstallation
  alias EzagentPluginGithub.TestHelpers

  @stub_name :github_installation_test
  @table :github_installation_tokens

  setup do
    ensure_table()
    :ets.delete_all_objects(@table)

    # A valid private key + app_id so App-JWT minting can run.
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
    Application.put_env(:ezagent_plugin_github, :private_key, TestHelpers.test_private_key_pem())

    Application.put_env(:ezagent_plugin_github, :installation_req_opts,
      plug: {Req.Test, @stub_name}
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_plugin_github, :installation_req_opts)
    end)

    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table])
      _tid -> :ok
    end
  end

  defp future_iso(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  describe "token_for_repo/2 — cache hit" do
    test "returns a seeded, non-expired token without any HTTP call" do
      # No Req stub installed → any HTTP attempt would raise, proving cache-only.
      GitHubInstallation.put_cached_token(
        "owner",
        "ghs_cached",
        System.system_time(:second) + 3600
      )

      assert {:ok, "ghs_cached"} = GitHubInstallation.token_for_repo("owner/repo")
    end
  end

  describe "token_for_repo/2 — mint" do
    test "resolves the installation then mints and caches a token" do
      expires = future_iso(3600)

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/owner/repo/installation"} ->
            Req.Test.json(conn, %{"id" => 123})

          {"POST", "/app/installations/123/access_tokens"} ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"token" => "ghs_minted", "expires_at" => expires})
        end
      end)

      assert {:ok, "ghs_minted"} = GitHubInstallation.token_for_repo("owner/repo")

      # Second call is served from cache (stub would still answer, but the value
      # must be the cached one keyed by account "owner").
      assert [{"owner", {"ghs_minted", _unix}}] = :ets.lookup(@table, "owner")
    end

    test "maps a 404 on installation resolution to repository_not_found" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
      end)

      assert {:error, :repository_not_found} = GitHubInstallation.token_for_repo("owner/repo")
    end

    test "maps a 401 on token minting to authentication_rejected" do
      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/repos/owner/repo/installation" ->
            Req.Test.json(conn, %{"id" => 123})

          "/app/installations/123/access_tokens" ->
            Plug.Conn.resp(conn, 401, ~s({"message": "Bad credentials"}))
        end
      end)

      assert {:error, :authentication_rejected} = GitHubInstallation.token_for_repo("owner/repo")
    end
  end

  describe "token_for_repo/2 — refresh near expiry" do
    test "re-mints when the cached token is within the refresh margin" do
      # Seed a token expiring in 30s (< 60s margin) → treated as a miss.
      GitHubInstallation.put_cached_token("owner", "ghs_stale", System.system_time(:second) + 30)

      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/owner/repo/installation"} ->
            Req.Test.json(conn, %{"id" => 123})

          {"POST", "/app/installations/123/access_tokens"} ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"token" => "ghs_fresh", "expires_at" => future_iso(3600)})
        end
      end)

      assert {:ok, "ghs_fresh"} = GitHubInstallation.token_for_repo("owner/repo")
    end
  end
end
