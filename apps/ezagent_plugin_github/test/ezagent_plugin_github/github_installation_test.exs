defmodule EzagentPluginGithub.GitHubInstallationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ezagent.DomainGit.RepositoryRef
  alias EzagentPluginGithub.{GitHubInstallation, InstallationPermissions, TestHelpers}

  @stub_name :github_installation_test

  setup do
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
    Application.put_env(:ezagent_plugin_github, :private_key, TestHelpers.test_private_key_pem())

    Application.put_env(:ezagent_plugin_github, :installation_req_opts,
      plug: {Req.Test, @stub_name}
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_plugin_github, :client_id)
      Application.delete_env(:ezagent_plugin_github, :client_secret)
      Application.delete_env(:ezagent_plugin_github, :installation_req_opts)
    end)

    :ok
  end

  defp repo(external_id \\ "owner/repo") do
    {:ok, r} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "owner-repo"),
        provider_adapter: EzagentPluginGithub.GitHubAdapter,
        provider_host: "github.com",
        external_id: external_id,
        owner_path: "owner",
        base_ref: "main",
        visibility: :public
      })

    r
  end

  defp future_iso(seconds \\ 3600) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp past_iso(seconds \\ 3600) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()
  end

  defp read_json_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  defp baseline_response(profile) do
    %{
      "token" => "ghs_should_not_be_asserted_on_directly",
      "expires_at" => future_iso(),
      "repository_selection" => "selected",
      "repositories" => [%{"full_name" => "owner/repo"}],
      "permissions" => InstallationPermissions.for!(profile)
    }
  end

  defp stub_mint(response) do
    Req.Test.stub(@stub_name, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/owner/repo/installation"} ->
          Req.Test.json(conn, %{"id" => 123})

        {"POST", "/app/installations/123/access_tokens"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(response)
      end
    end)
  end

  defp assert_scope_mismatch(profile, override_fn) do
    stub_mint(override_fn.(baseline_response(profile)))

    assert {:error, :installation_scope_mismatch} =
             GitHubInstallation.token_for_operation(repo(), profile)
  end

  defp assert_unrecognized(profile, override_fn) do
    stub_mint(override_fn.(baseline_response(profile)))

    assert {:error, :provider_response_unrecognized} =
             GitHubInstallation.token_for_operation(repo(), profile)
  end

  # ── InstallationPermissions.for!/1 — closed set ─────────────────────────

  describe "InstallationPermissions.for!/1" do
    test "returns the exact closed permission map for each profile" do
      assert InstallationPermissions.for!(:metadata_read) == %{"metadata" => "read"}

      assert InstallationPermissions.for!(:change_request_write) == %{
               "metadata" => "read",
               "contents" => "write",
               "pull_requests" => "write"
             }

      assert InstallationPermissions.for!(:change_request_read) == %{
               "metadata" => "read",
               "pull_requests" => "read"
             }

      assert InstallationPermissions.for!(:checks_read) == %{
               "metadata" => "read",
               "checks" => "read"
             }
    end

    test "raises for any profile outside the closed set" do
      # Routed through String.to_atom/1 (fixed literal, not untrusted input) so
      # the compiler's set-theoretic type checker can't narrow this to a literal
      # atom and flag the intentionally-invalid call at compile time.
      invalid_profile = String.to_atom("admin")
      assert_raise FunctionClauseError, fn -> InstallationPermissions.for!(invalid_profile) end
    end
  end

  # ── token_for_operation/3 — exact request shape ─────────────────────────

  describe "token_for_operation/3 — exact request shape" do
    test "mint request carries exactly the repository short name and exact profile permissions" do
      test_pid = self()

      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

      Req.Test.expect(@stub_name, fn conn ->
        {body, conn} = read_json_body(conn)
        send(test_pid, {:mint_request_body, body})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(Map.put(baseline_response(:change_request_write), "token", "ghs_minted"))
      end)

      assert {:ok, "ghs_minted"} =
               GitHubInstallation.token_for_operation(repo(), :change_request_write)

      assert_received {:mint_request_body, body}
      assert body["repositories"] == ["repo"]

      assert body["permissions"] == %{
               "metadata" => "read",
               "contents" => "write",
               "pull_requests" => "write"
             }
    end

    test "a different repository produces a different exact repositories body" do
      test_pid = self()

      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 999}) end)

      Req.Test.expect(@stub_name, fn conn ->
        {body, conn} = read_json_body(conn)
        send(test_pid, {:mint_request_body, body})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "token" => "ghs_other",
          "expires_at" => future_iso(),
          "repository_selection" => "selected",
          "repositories" => [%{"full_name" => "owner/other-repo"}],
          "permissions" => InstallationPermissions.for!(:metadata_read)
        })
      end)

      assert {:ok, "ghs_other"} =
               GitHubInstallation.token_for_operation(repo("owner/other-repo"), :metadata_read)

      assert_received {:mint_request_body, body}
      assert body["repositories"] == ["other-repo"]
    end
  end

  # ── token_for_operation/3 — strict response validation, fail closed ────

  describe "token_for_operation/3 — strict response validation fails closed" do
    # The installation LOOKUP answering 2xx without an `id` is a response this
    # code cannot read — distinct from `:installation_scope_mismatch`, which
    # means the mint succeeded and we read a scope that was not the one asked
    # for. Both are terminal, but only this one says "GitHub's response shape
    # changed", which is the thing an operator would go and look at.
    #
    # A malformed MINT body takes the same path — see the shape/scope cases
    # further down.
    test "a 2xx installation lookup with no id is unrecognized, not a scope mismatch" do
      Req.Test.stub(@stub_name, fn conn ->
        Req.Test.json(conn, %{"unexpected" => true})
      end)

      assert {:error, :provider_response_unrecognized} =
               GitHubInstallation.token_for_operation(repo(), :metadata_read)
    end

    test "repository_selection: all is rejected" do
      assert_scope_mismatch(:metadata_read, &Map.put(&1, "repository_selection", "all"))
    end

    test "empty repositories list is rejected" do
      assert_scope_mismatch(:metadata_read, &Map.put(&1, "repositories", []))
    end

    test "a different repository in the response is rejected" do
      assert_scope_mismatch(
        :metadata_read,
        &Map.put(&1, "repositories", [%{"full_name" => "owner/other-repo"}])
      )
    end

    test "an extra repository beyond the requested one is rejected" do
      assert_scope_mismatch(
        :metadata_read,
        &Map.put(&1, "repositories", [
          %{"full_name" => "owner/repo"},
          %{"full_name" => "owner/extra-repo"}
        ])
      )
    end

    test "wider permissions than requested are rejected" do
      assert_scope_mismatch(
        :metadata_read,
        &Map.update!(&1, "permissions", fn perms -> Map.put(perms, "contents", "write") end)
      )
    end

    test "narrower or different-value permissions than requested are rejected" do
      assert_scope_mismatch(
        :change_request_write,
        &Map.put(&1, "permissions", %{"metadata" => "read"})
      )
    end

    test "malformed expires_at is rejected" do
      assert_scope_mismatch(:metadata_read, &Map.put(&1, "expires_at", "not-a-date"))
    end

    test "an expires_at already in the past is rejected" do
      assert_scope_mismatch(:metadata_read, &Map.put(&1, "expires_at", past_iso()))
    end

    test "an empty-string token is rejected" do
      assert_scope_mismatch(:metadata_read, &Map.put(&1, "token", ""))
    end

    # ── the line between "scoped wrong" and "could not be read" ──────────
    #
    # Everything above keeps `:installation_scope_mismatch`: the five scope
    # fields were all there and readable, and one of their VALUES was not what
    # we asked for. Everything below is a field that is absent or of the wrong
    # type, so there is no scope to disagree with — the response shape changed.
    #
    # Both codes are terminal, so no run behaves differently either way. What
    # differs is the cause an operator is handed, which is the entire reason
    # `:provider_response_unrecognized` exists.
    #
    # `"expires_at" => "not-a-date"` deliberately stays on the scope side: it is
    # a present, correctly-typed string whose value is unusable, same as an
    # already-past expiry.

    test "a missing expires_at is unreadable, not a scope mismatch" do
      assert_unrecognized(:metadata_read, &Map.delete(&1, "expires_at"))
    end

    test "a missing token is unreadable, not a scope mismatch" do
      assert_unrecognized(:metadata_read, &Map.delete(&1, "token"))
    end

    test "a nil token is unreadable, not a scope mismatch" do
      assert_unrecognized(:metadata_read, &Map.put(&1, "token", nil))
    end

    test "a non-binary token is unreadable, not a scope mismatch" do
      assert_unrecognized(:metadata_read, &Map.put(&1, "token", 12_345))
    end

    # `is_list/1` in the guard only vouches for the container. An entry that is
    # not a map with a binary `full_name` is a repository we could not READ —
    # distinct from `[]` or a different repository, which are readable answers
    # that disagree with what we asked for and stay a scope mismatch.
    test "an unreadable repositories entry is unrecognized, not a scope mismatch" do
      for repositories <- [[123], [%{}], [%{"full_name" => nil}], [%{"name" => "repo"}]] do
        stub_mint(Map.put(baseline_response(:metadata_read), "repositories", repositories))

        assert {:error, :provider_response_unrecognized} =
                 GitHubInstallation.token_for_operation(repo(), :metadata_read),
               "expected refusal for #{inspect(repositories)}"
      end
    end
  end

  # ── token_for_operation/3 — existing GitHubClient error mapping ────────

  describe "token_for_operation/3 — existing GitHubClient error mapping stays stable" do
    test "404 on installation resolution maps to repository_not_found" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
      end)

      assert {:error, :repository_not_found} =
               GitHubInstallation.token_for_operation(repo(), :metadata_read)
    end

    test "401 on token minting maps to authentication_rejected" do
      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/repos/owner/repo/installation" ->
            Req.Test.json(conn, %{"id" => 123})

          "/app/installations/123/access_tokens" ->
            Plug.Conn.resp(conn, 401, ~s({"message": "Bad credentials"}))
        end
      end)

      assert {:error, :authentication_rejected} =
               GitHubInstallation.token_for_operation(repo(), :metadata_read)
    end
  end

  # ── token_for_operation/3 — no cache, fresh mint every call ────────────

  describe "token_for_operation/3 — no cache, fresh mint every call" do
    test "two sequential calls for the same repo and profile each mint independently" do
      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(Map.put(baseline_response(:metadata_read), "token", "ghs_first"))
      end)

      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(Map.put(baseline_response(:metadata_read), "token", "ghs_second"))
      end)

      assert {:ok, "ghs_first"} = GitHubInstallation.token_for_operation(repo(), :metadata_read)
      assert {:ok, "ghs_second"} = GitHubInstallation.token_for_operation(repo(), :metadata_read)
    end

    test "no public cache-seeding function exists" do
      refute function_exported?(GitHubInstallation, :put_cached_token, 3)
    end

    test "GitHubInstallation is a plain module — no child_spec/start_link" do
      refute function_exported?(GitHubInstallation, :child_spec, 1)
      refute function_exported?(GitHubInstallation, :start_link, 1)
    end
  end

  # ── token_for_operation/3 — token sentinel does not leak ───────────────

  describe "token_for_operation/3 — token sentinel does not leak" do
    test "minted token value never appears in captured logs" do
      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(Map.put(baseline_response(:metadata_read), "token", "ghs_sentinel_zzz"))
      end)

      log =
        capture_log(fn ->
          assert {:ok, "ghs_sentinel_zzz"} =
                   GitHubInstallation.token_for_operation(repo(), :metadata_read)
        end)

      refute log =~ "ghs_sentinel_zzz"
    end

    test "a well-formed but already-expired token's value never leaks on rejection" do
      sentinel = "ghs_expired_sentinel_value"

      log =
        capture_log(fn ->
          assert_scope_mismatch(
            :metadata_read,
            &(&1 |> Map.put("token", sentinel) |> Map.put("expires_at", past_iso()))
          )
        end)

      refute log =~ sentinel
    end
  end

  # ── token_for_operation/3 — config and OAuth boundary ──────────────────

  describe "token_for_operation/3 — config fail-loud and OAuth is never a fallback" do
    test "missing private key raises instead of silently degrading" do
      Application.delete_env(:ezagent_plugin_github, :private_key)

      assert_raise RuntimeError, ~r/private_key/, fn ->
        GitHubInstallation.token_for_operation(repo(), :metadata_read)
      end
    end

    test "OAuth client credentials are never read by installation minting" do
      Application.delete_env(:ezagent_plugin_github, :client_id)
      Application.delete_env(:ezagent_plugin_github, :client_secret)

      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(baseline_response(:metadata_read))
      end)

      assert {:ok, _token} = GitHubInstallation.token_for_operation(repo(), :metadata_read)
    end
  end
end
