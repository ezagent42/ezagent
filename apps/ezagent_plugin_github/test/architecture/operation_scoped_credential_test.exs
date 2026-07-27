defmodule EzagentPluginGithub.Architecture.OperationScopedCredentialTest do
  @moduledoc """
  Structural gate for the Plan E E1 operation-scoped installation credential
  design: `EzagentPluginGithub.GitHubInstallation` must stay a plain,
  cache-free, unsupervised minting function — this is what stops a future PR
  from silently reintroducing the account-wide ETS cache/Agent this slice
  deleted.
  """

  use ExUnit.Case, async: true

  alias EzagentPluginGithub.{GitHubInstallation, GitHubAdapter}

  @installation_source File.read!(
                         Path.join([
                           __DIR__,
                           "..",
                           "..",
                           "lib",
                           "ezagent_plugin_github",
                           "github_installation.ex"
                         ])
                       )

  @adapter_source File.read!(
                    Path.join([
                      __DIR__,
                      "..",
                      "..",
                      "lib",
                      "ezagent_plugin_github",
                      "github_adapter.ex"
                    ])
                  )

  # ── No cache / no process ────────────────────────────────────────────────

  test "GitHubInstallation source has no ETS usage" do
    refute @installation_source =~ ~r/:ets\./,
           "GitHubInstallation must not reintroduce an ETS-backed cache"
  end

  test "GitHubInstallation source has no Agent/GenServer process" do
    refute @installation_source =~ ~r/\bAgent\./,
           "GitHubInstallation must not reintroduce an Agent-owned cache process"

    refute @installation_source =~ ~r/\buse GenServer\b/,
           "GitHubInstallation must not become a GenServer"
  end

  test "GitHubInstallation source has no process dictionary or persistent_term usage" do
    refute @installation_source =~ ~r/Process\.(put|get)\b/,
           "GitHubInstallation must not stash a token in the process dictionary"

    refute @installation_source =~ ~r/:persistent_term\./,
           "GitHubInstallation must not stash a token in persistent_term"
  end

  test "no public cache/token-seeding seam exists" do
    refute function_exported?(GitHubInstallation, :put_cached_token, 3),
           "put_cached_token/3 (public cache-seeding seam) must not exist"
  end

  test "GitHubInstallation is a plain module — not a supervised child" do
    refute function_exported?(GitHubInstallation, :child_spec, 1)
    refute function_exported?(GitHubInstallation, :start_link, 1)

    refute Enum.any?(EzagentPluginGithub.Application.children(), fn
             GitHubInstallation -> true
             {GitHubInstallation, _opts} -> true
             _other -> false
           end),
           "GitHubInstallation must not be listed in Application.children/0"
  end

  # ── Not an Agent-callable action / tool ──────────────────────────────────

  test "token_for_operation is not declared as an ActionSet action" do
    refute @installation_source =~ ~r/use Ezagent\.ActionSet/,
           "GitHubInstallation must stay a plain trusted seam, not a dispatchable Behavior"

    refute @installation_source =~ ~r/@behaviour Ezagent\.ActionSet/
    refute function_exported?(GitHubInstallation, :actions, 0)
  end

  # ── Static, closed profile selection — not caller/ctx/prompt/card supplied ─

  test "GitHubAdapter selects each callback's permission profile as a literal atom" do
    expected_call_sites = [
      ~r/installation_token\(repo,\s*:metadata_read\)/,
      ~r/installation_token\(repo,\s*:change_request_write\)/,
      ~r/installation_token\(repo,\s*:change_request_read\)/,
      ~r/installation_token\(repo,\s*:checks_read\)/
    ]

    for pattern <- expected_call_sites do
      assert @adapter_source =~ pattern,
             "expected a literal-atom profile call site matching #{inspect(pattern)}"
    end

    # read_change_request and list_reviews both use :change_request_read — the
    # literal must appear at least twice (once per call site).
    matches = Regex.scan(~r/installation_token\(repo,\s*:change_request_read\)/, @adapter_source)
    assert length(matches) == 2

    refute @adapter_source =~ ~r/installation_token\(repo,\s*ctx/,
           "profile must never be read from ctx"

    refute @adapter_source =~ ~r/installation_token\(repo,\s*args/,
           "profile must never be read from action args"
  end

  # ── OAuth credential is never an installation-credential fallback ──────────

  test "GitHubInstallation never references OAuth client credentials or modules" do
    refute @installation_source =~ "client_id"
    refute @installation_source =~ "client_secret"
    refute @installation_source =~ "GitHubOAuth"
    refute @installation_source =~ "GitHubDriver"
    refute @installation_source =~ "GitHubCredentialBackend"
  end

  # ── Sentinel: minted token never enters an adapter result ──────────────────

  test "a successful adapter call's result does not contain the minted token" do
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")

    Application.put_env(
      :ezagent_plugin_github,
      :private_key,
      EzagentPluginGithub.TestHelpers.test_private_key_pem()
    )

    Application.put_env(:ezagent_plugin_github, :adapter_req_opts,
      plug: {Req.Test, :operation_scoped_credential_sentinel_test}
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_plugin_github, :adapter_req_opts)
    end)

    sentinel = "ghs_architecture_sentinel_value"

    Req.Test.stub(:operation_scoped_credential_sentinel_test, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/owner/repo/installation"} ->
          Req.Test.json(conn, %{"id" => 123})

        {"POST", "/app/installations/123/access_tokens"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "token" => sentinel,
            "expires_at" =>
              DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
            "repository_selection" => "selected",
            "repositories" => [%{"full_name" => "owner/repo"}],
            "permissions" => EzagentPluginGithub.InstallationPermissions.for!(:metadata_read)
          })

        {"GET", "/repos/owner/repo"} ->
          Req.Test.json(conn, %{"full_name" => "owner/repo", "default_branch" => "main"})
      end
    end)

    {:ok, repo} =
      Ezagent.DomainGit.RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "owner-repo"),
        provider_adapter: GitHubAdapter,
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :public
      })

    workspace = "test-ws"
    hash = Base.encode16(:crypto.hash(:sha256, "arch-sentinel"), case: :lower)

    {:ok, ctx} =
      Ezagent.DomainGit.OperationContext.new(%{
        task_access_uri: Ezagent.URI.worker(workspace, "gta_#{hash}"),
        caller_uri: Ezagent.URI.entity(workspace, "agent", "caller"),
        grantee_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
        idempotency_key: "arch-sentinel-idem-1"
      })

    result = GitHubAdapter.resolve_repository(ctx, repo)

    refute inspect(result) =~ sentinel,
           "the minted token must never appear in an adapter callback's result"
  end

  test "create_change_request's result never contains the minted token, across its full reconciliation chain" do
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")

    Application.put_env(
      :ezagent_plugin_github,
      :private_key,
      EzagentPluginGithub.TestHelpers.test_private_key_pem()
    )

    Application.put_env(:ezagent_plugin_github, :adapter_req_opts,
      plug: {Req.Test, :ccr_operation_scoped_credential_sentinel_test}
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_plugin_github, :adapter_req_opts)
    end)

    sentinel = "ghs_ccr_architecture_sentinel_value"
    sha = String.duplicate("a", 40)

    Req.Test.stub(:ccr_operation_scoped_credential_sentinel_test, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/owner/repo/installation"} ->
          Req.Test.json(conn, %{"id" => 123})

        {"POST", "/app/installations/123/access_tokens"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "token" => sentinel,
            "expires_at" =>
              DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
            "repository_selection" => "selected",
            "repositories" => [%{"full_name" => "owner/repo"}],
            "permissions" =>
              EzagentPluginGithub.InstallationPermissions.for!(:change_request_write)
          })

        {"GET", "/repos/owner/repo/git/ref/heads/main"} ->
          Req.Test.json(conn, %{"object" => %{"sha" => sha}})

        {"GET", "/repos/owner/repo/git/ref/heads/feature-branch"} ->
          Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))

        {"GET", "/repos/owner/repo/git/commits/" <> _rest} ->
          Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "treesha"}, "parents" => []})

        {"POST", "/repos/owner/repo/git/blobs"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blobsha"})

        {"POST", "/repos/owner/repo/git/trees"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "treesha2"})

        {"POST", "/repos/owner/repo/git/commits"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commitsha"})

        {"POST", "/repos/owner/repo/git/refs"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})

        {"GET", "/repos/owner/repo/pulls"} ->
          Req.Test.json(conn, [])

        {"POST", "/repos/owner/repo/pulls"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => 42,
            "html_url" => "https://github.com/owner/repo/pull/42",
            "state" => "open",
            "head" => %{"ref" => "feature-branch", "sha" => sha},
            "base" => %{"ref" => "main"},
            "merged" => false
          })
      end
    end)

    {:ok, repo} =
      Ezagent.DomainGit.RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "owner-repo"),
        provider_adapter: GitHubAdapter,
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :public
      })

    workspace = "test-ws"
    hash = Base.encode16(:crypto.hash(:sha256, "ccr-arch-sentinel"), case: :lower)

    {:ok, ctx} =
      Ezagent.DomainGit.OperationContext.new(%{
        task_access_uri: Ezagent.URI.worker(workspace, "gta_#{hash}"),
        caller_uri: Ezagent.URI.entity(workspace, "agent", "caller"),
        grantee_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
        idempotency_key: "ccr-arch-sentinel-idem-1"
      })

    {:ok, base_sha_struct} = Ezagent.DomainGit.CommitSha.new(%{value: sha})

    {:ok, create_req} =
      Ezagent.DomainGit.CreateChangeRequest.new(%{
        title: "Sentinel PR",
        body: "body",
        head_ref: "feature-branch",
        expected_base_sha: base_sha_struct
      })

    {:ok, file_change} =
      Ezagent.DomainGit.FileChange.new(%{path: "README.md", operation: :upsert, content: "x"})

    result = GitHubAdapter.create_change_request(ctx, repo, [file_change], create_req)

    refute inspect(result) =~ sentinel,
           "the minted token must never appear in create_change_request's result"
  end
end
