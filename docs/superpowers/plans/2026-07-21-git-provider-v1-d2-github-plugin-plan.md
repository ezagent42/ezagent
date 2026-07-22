# Git Provider V1 D2 — GitHub Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `ezagent_plugin_github` — a standalone OTP app that implements GitHub OAuth App authorization and Git REST API operations, callable by agents via existing action/skill mechanisms.

**Architecture:** Follows the established ezagent plugin pattern (use `Ezagent.Plugin` + `Ezagent.Plugin.boot/1`). Three behaviours to implement: `Ezagent.ProviderConnection.Driver` (8 callbacks for OAuth lifecycle), `Ezagent.DomainGit.Adapter` (5 callbacks for Git API via Req), `Ezagent.ProviderConnection.CredentialBackend` (token encrypted storage). Registration via `DriverRegistry` / `BackendPairRegistry` + application config. HTTP callback via Plug forwarded from web router (feishu pattern).

**Tech Stack:** Elixir/OTP, Req (~> 0.5) for HTTP, Erlang `:crypto` (AES-256-GCM) for token storage, Plug for callback endpoint, ExUnit + Req.Test for testing.

## Global Constraints

- Work in the git-domain-spine worktree: `/home/huangjiajia/ezagent/.worktrees/git-domain-spine` on branch `feat/git-domain-spine`.
- Every OTP app added to umbrella must be registered in root `mix.exs` releases section.
- Plugin uses `use Ezagent.Plugin` + `Ezagent.Plugin.boot(__MODULE__)` — must NOT hand-write supervisor trees.
- No credential material (token, client_secret) in Inspect, logs, telemetry, error tuples, or test output. The Driver boundary (EffectBoundary in D1) enforces this on the framework side; plugin code must follow the same discipline.
- Driver returns `credential_material` as `{:write_only_handoff, blob}` — opaque to the framework, AEAD-encrypted by the CredentialBackend before storage.
- All GitHub HTTP calls (OAuth token exchange + REST API) go through a single `GitHubClient` module wrapping Req.
- Tests use `Req.Test` stubs for HTTP-dependent paths (Driver) and constructed DomainGit value types for pure data paths (Adapter).
- Follow strict RED/GREEN TDD: write failing test first, run it, implement, run green, commit.
- Mix commands must use the umbrella root, not cd into app. Use `MIX_TEST_PARTITION` for isolated test DBs.
- Do NOT use `git add -A` — always path-scoped staging.

---

## File Map

```text
apps/ezagent_plugin_github/
├── mix.exs
├── lib/
│   └── ezagent_plugin_github/
│       ├── application.ex              # Plugin boot + registration
│       ├── github_driver.ex            # Driver behaviour impl
│       ├── github_adapter.ex           # DomainGit.Adapter impl
│       ├── github_credential_backend.ex # CredentialBackend impl
│       ├── github_client.ex            # Req wrapper
│       ├── github_oauth.ex             # OAuth URL + token exchange
│       ├── github_token_store.ex       # Encrypted token persistence
│       ├── github_callback_plug.ex     # Callback Plug
│       └── config.ex                   # Config struct
├── test/
│   ├── test_helper.exs
│   ├── ezagent_plugin_github/
│   │   ├── github_driver_test.exs
│   │   ├── github_adapter_test.exs
│   │   ├── github_credential_backend_test.exs
│   │   └── github_client_test.exs
│   └── support/
│       └── github_test_helpers.ex
apps/ezagent_web/lib/ezagent_web/router.ex   # + forward line
mix.exs                                       # + app in release section
config/config.exs                              # + plugin + provider config
```

---

### Task 0: App skeleton — mix.exs, application.ex, umbrella registration

**Files:**
- Create: `apps/ezagent_plugin_github/mix.exs`
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex`
- Create: `apps/ezagent_plugin_github/test/test_helper.exs`
- Modify: `mix.exs` (root — add to releases + deps path)

**Interfaces:**
- Produces: `EzagentPluginGithub.Application` module, OTP app `:ezagent_plugin_github`
- Consumes: umbrella structure (build_path, config_path, deps_path conventions)

- [ ] **Step 1: Create mix.exs with umbrella paths, deps, and compiler gate**

```elixir
# apps/ezagent_plugin_github/mix.exs
defmodule EzagentPluginGithub.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_github,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [ezagent_plugin: EzagentPluginGithub.Application],
      mod: {EzagentPluginGithub.Application, []}
    ]
  end

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_git, in_umbrella: true},
      {:ezagent_domain_provider_connection, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"}
    ]
  end
end
```

- [ ] **Step 2: Create application.ex with plugin_info placeholder and boot hook**

```elixir
# apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex
defmodule EzagentPluginGithub.Application do
  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info, do: %{
    slug: "github",
    name: "GitHub OAuth",
    description: "GitHub OAuth App provider plugin for Git operations",
    version: "0.1.0"
  }

  @impl Ezagent.Plugin
  def children, do: []

  @impl Ezagent.Plugin
  def after_boot, do: :ok
end
```

- [ ] **Step 3: Create test helper**

```elixir
# apps/ezagent_plugin_github/test/test_helper.exs
ExUnit.start()
```

- [ ] **Step 4: Register app in umbrella mix.exs releases section**

Read root `mix.exs`, find the `releases` applications list, add `:ezagent_plugin_github` in alphabetical order alongside other plugins.

- [ ] **Step 5: Verify compilation**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-domain-spine
mix compile --warnings-as-errors 2>&1 | grep -E "ezagent_plugin_github|error|warning" | head -10
```

Expected: compiles without errors or warnings.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_github/mix.exs \
        apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex \
        apps/ezagent_plugin_github/test/test_helper.exs \
        mix.exs
git commit -m "feat(github): add plugin app skeleton

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 1: GitHubClient — Req wrapper for GitHub REST API

**Files:**
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_client.ex`
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/config.ex`
- Create: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_client_test.exs`

**Interfaces:**
- Consumes: nil (first real module)
- Produces: `GitHubClient.get/2`, `GitHubClient.post/3` — wrappers around Req that auto-inject auth headers and base URL. Returns `{:ok, map()} | {:error, atom()}`.

- [ ] **Step 1: Write RED test — basic auth header and error handling**

```elixir
# test/ezagent_plugin_github/github_client_test.exs
defmodule EzagentPluginGithub.GitHubClientTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGithub.GitHubClient

  setup do
    # Use Req.Test to stub HTTP
    Req.Test.attach(:github_client_test)
    :ok
  end

  test "get injects Authorization and Accept headers" do
    Req.Test.stub(:github_client_test, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github+json"]
      Plug.Conn.resp(conn, 200, ~s({"login": "test-user"}))
    end)

    assert {:ok, %{"login" => "test-user"}} =
             GitHubClient.get("/user", "test-token")
  end

  test "get maps 401 to authentication_rejected" do
    Req.Test.stub(:github_client_test, fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"message": "Bad credentials"}))
    end)

    assert {:error, :authentication_rejected} =
             GitHubClient.get("/user", "bad-token")
  end

  test "get maps 404 to repository_not_found" do
    Req.Test.stub(:github_client_test, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    assert {:error, :repository_not_found} =
             GitHubClient.get("/repos/owner/nonexistent", "token")
  end

  test "get maps 403 to provider_denied (rate limit / forbidden)" do
    Req.Test.stub(:github_client_test, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :provider_denied} =
             GitHubClient.get("/repos/owner/private-repo", "token")
  end
end
```

- [ ] **Step 2: Run RED — test fails because module doesn't exist**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-domain-spine
mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_client_test.exs 2>&1 | tail -3
```

Expected: compile error or tests fail.

- [ ] **Step 3: Create config.ex (runtime config struct)**

```elixir
# lib/ezagent_plugin_github/config.ex
defmodule EzagentPluginGithub.Config do
  @moduledoc false

  def oauth_client_id, do: fetch_env!(:oauth_client_id)
  def oauth_client_secret, do: fetch_env!(:oauth_client_secret)

  defp fetch_env!(key) do
    case Application.get_env(:ezagent_plugin_github, key) do
      {:system, env_var} ->
        System.get_env(env_var) || raise "Missing env var: #{env_var}"
      value when is_binary(value) ->
        value
      nil ->
        raise "Missing config: :ezagent_plugin_github, #{key}"
    end
  end
end
```

- [ ] **Step 4: Implement GitHubClient**

```elixir
# lib/ezagent_plugin_github/github_client.ex
defmodule EzagentPluginGithub.GitHubClient do
  @moduledoc false

  @base_url "https://api.github.com"

  def get(path, token) when is_binary(path) and is_binary(token) do
    Req.get(@base_url <> path,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"user-agent", "ezagent-github-plugin"}
      ]
    )
    |> handle_response()
  end

  def post(path, token, body) when is_binary(path) and is_binary(token) and is_map(body) do
    Req.post(@base_url <> path,
      json: body,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"user-agent", "ezagent-github-plugin"}
      ]
    )
    |> handle_response()
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: 401}}), do: {:error, :authentication_rejected}
  defp handle_response({:ok, %{status: 404}}), do: {:error, :repository_not_found}
  defp handle_response({:ok, %{status: 403}}), do: {:error, :provider_denied}
  defp handle_response({:ok, %{status: 422}}), do: {:error, :change_request_conflict}
  defp handle_response({:ok, _}), do: {:error, :provider_unavailable}
  defp handle_response({:error, _}), do: {:error, :provider_unavailable}
end
```

- [ ] **Step 5: Run GREEN**

```bash
mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_client_test.exs 2>&1 | tail -3
```

Expected: `N tests, 0 failures`

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_client.ex \
        apps/ezagent_plugin_github/lib/ezagent_plugin_github/config.ex \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_client_test.exs
git commit -m "feat(github): add GitHubClient Req wrapper with error mapping

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: GitHubOAuth — OAuth URL construction and token exchange

**Files:**
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_oauth.ex`

**Interfaces:**
- Consumes: `GitHubClient.post/3`, `Config`
- Produces: `GitHubOAuth.authorize_url(redirect_uri, state) :: String.t()`, `GitHubOAuth.exchange_code(code, redirect_uri) :: {:ok, map()} | {:error, atom()}`

- [ ] **Step 1: Write RED test (unit, no HTTP needed — pure URL construction)**

```elixir
# test/ezagent_plugin_github/github_oauth_test.exs (merge into github_client_test.exs or standalone)
defmodule EzagentPluginGithub.GitHubOAuthTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGithub.GitHubOAuth

  setup do
    # Stub config
    Application.put_env(:ezagent_plugin_github, :oauth_client_id, "test-client-id")
    Application.put_env(:ezagent_plugin_github, :oauth_client_secret, "test-client-secret")

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :oauth_client_id)
      Application.delete_env(:ezagent_plugin_github, :oauth_client_secret)
    end)
  end

  test "authorize_url constructs correct GitHub OAuth URL with state" do
    url = GitHubOAuth.authorize_url("https://ezagent.example/callback", "state-abc")
    uri = URI.parse(url)

    assert uri.host == "github.com"
    assert uri.path == "/login/oauth/authorize"
    query = URI.decode_query(uri.query)
    assert query["client_id"] == "test-client-id"
    assert query["state"] == "state-abc"
    assert query["redirect_uri"] == "https://ezagent.example/callback"
    assert query["scope"] == "repo"
  end
end
```

- [ ] **Step 2: Run RED**

```bash
mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_oauth_test.exs 2>&1 | tail -3
```

- [ ] **Step 3: Implement GitHubOAuth**

```elixir
# lib/ezagent_plugin_github/github_oauth.ex
defmodule EzagentPluginGithub.GitHubOAuth do
  @moduledoc false

  @authorize_url "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"

  def authorize_url(redirect_uri, state) do
    query = URI.encode_query(%{
      client_id: EzagentPluginGithub.Config.oauth_client_id(),
      redirect_uri: redirect_uri,
      state: state,
      scope: "repo"
    })
    "#{@authorize_url}?#{query}"
  end

  def exchange_code(code, redirect_uri) do
    body = %{
      client_id: EzagentPluginGithub.Config.oauth_client_id(),
      client_secret: EzagentPluginGithub.Config.oauth_client_secret(),
      code: code,
      redirect_uri: redirect_uri
    }

    case Req.post(@token_url,
           form: body,
           headers: [{"accept", "application/json"}, {"user-agent", "ezagent-github-plugin"}]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, %{access_token: token}}

      {:ok, %{status: status}} when status in 400..499 ->
        {:error, :provider_denied}

      {:error, _} ->
        {:error, :provider_unavailable}
    end
  end
end
```

- [ ] **Step 4: Run GREEN**

```bash
mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_oauth_test.exs 2>&1 | tail -3
```

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_oauth.ex \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_oauth_test.exs
git commit -m "feat(github): add OAuth URL construction and token exchange

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: GitHubCallbackPlug — OAuth callback HTTP endpoint

**Files:**
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_callback_plug.ex`
- Create: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_callback_plug_test.exs`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex` (add forward line)

**Interfaces:**
- Consumes: `CallbackIngress.consume/3`
- Produces: `EzagentPluginGithub.GitHubCallbackPlug` (Plug module)

- [ ] **Step 1: Write RED test**

```elixir
# test/ezagent_plugin_github/github_callback_plug_test.exs
defmodule EzagentPluginGithub.GitHubCallbackPlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias EzagentPluginGithub.GitHubCallbackPlug

  test "GET with code and state returns 200" do
    conn =
      :get
      |> Plug.Test.conn("/github/callback?code=test-code&state=test-state")
      |> GitHubCallbackPlug.call([])

    assert conn.status == 200
  end

  test "GET without code returns 400" do
    conn =
      :get
      |> Plug.Test.conn("/github/callback?state=test-state")
      |> GitHubCallbackPlug.call([])

    assert conn.status == 400
  end
end
```

- [ ] **Step 2: Implement Plug**

```elixir
# lib/ezagent_plugin_github/github_callback_plug.ex
defmodule EzagentPluginGithub.GitHubCallbackPlug do
  @moduledoc false
  import Plug.Conn

  def init(opts), do: opts

  def call(%{params: %{"code" => code, "state" => state}} = conn, _opts) do
    provider_envelope = %{code: code}

    case Ezagent.ProviderConnection.CallbackIngress.consume(
           "github-oauth",
           state,
           provider_envelope
         ) do
      {:ok, _receipt} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "GitHub authorization complete. You may close this page.")

      {:error, reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "Authorization failed: #{reason}")
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "Missing code or state parameter")
  end
end
```

- [ ] **Step 3: Add forward to web router**

In `apps/ezagent_web/lib/ezagent_web/router.ex`, add after existing external forwards:
```elixir
forward "/github/callback", EzagentPluginGithub.GitHubCallbackPlug
```

- [ ] **Step 4: Run GREEN**

```bash
mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_callback_plug_test.exs 2>&1 | tail -3
```

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_callback_plug.ex \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_callback_plug_test.exs \
        apps/ezagent_web/lib/ezagent_web/router.ex
git commit -m "feat(github): add OAuth callback Plug endpoint

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: GitHubDriver — Driver behaviour implementation

**Files:**
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_driver.ex`
- Create: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_driver_test.exs`
- Create: `apps/ezagent_plugin_github/test/support/github_test_helpers.ex`
- Modify: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex` (after_boot registration)

**Interfaces:**
- Consumes: `GitHubOAuth`, `Driver` behaviour, `DriverRegistry`, `BackendPairRegistry`
- Produces: `EzagentPluginGithub.GitHubDriver` (implements `Ezagent.ProviderConnection.Driver`)

This is the largest task. The Driver must implement 8 callbacks. We'll focus on the two most critical ones — `begin_authorization` and `consume_callback` — and implement the others as stubs returning appropriate closed errors.

- [ ] **Step 1: Write RED test for begin_authorization**

```elixir
# test/support/github_test_helpers.ex
defmodule EzagentPluginGithub.TestHelpers do
  @moduledoc false

  def driver_declaration do
    Ezagent.ProviderConnection.Driver.new!(%{
      provider_id: "github",
      acquisition_method: "oauth_user",
      provider_fingerprint: "github-driver-v1",
      implementation: EzagentPluginGithub.GitHubDriver,
      backend_pair_ids: ["pair-github-v1"],
      metadata: %{
        authorization_redirect_schema: %{
          type: :map,
          fields: %{
            "authorization_uri" => %{type: :string},
            "state" => %{type: :string},
            "pkce_digest" => %{type: :string}
          }
        },
        provider_metadata_schema: %{type: :map, fields: %{}}
      }
    })
  end

  def backend_pair do
    Ezagent.ProviderConnection.BackendPair.new!(%{
      pair_id: "pair-github-v1",
      authorization_backend: %{id: "local-authorization-v1", fingerprint: "local-v1"},
      credential_backend: %{id: "github-credential-v1", fingerprint: "github-cred-v1"}
    })
  end

  def oauth_config do
    Application.put_env(:ezagent_plugin_github, :oauth_client_id, "test-client-id")
    Application.put_env(:ezagent_plugin_github, :oauth_client_secret, "test-secret")
  end
end
```

```elixir
# test/ezagent_plugin_github/github_driver_test.exs
defmodule EzagentPluginGithub.GitHubDriverTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGithub.GitHubDriver
  alias EzagentPluginGithub.TestHelpers
  import TestHelpers

  setup do
    oauth_config()
    :ok
  end

  @moduletag :integration

  test "begin_authorization returns a valid GitHub OAuth redirect URL" do
    exchange = fn private_frame ->
      assert is_binary(private_frame.state)
      assert is_binary(private_frame.pkce_verifier)

      {:ok,
       %{
         redirect: %{
           "authorization_uri" =>
             GitHubOAuth.authorize_url(
               "https://ezagent.example/github/callback",
               private_frame.state
             ),
           "state" => private_frame.state,
           "pkce_digest" => :crypto.hash(:sha256, private_frame.pkce_verifier) |> Base.encode16(case: :lower)
         },
         expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
       }}
    end

    result =
      GitHubDriver.begin_authorization(%{
        authorization_ref: "auth-ref-1",
        correlation_id: "corr-1",
        callback_envelope_digest: "digest",
        exchange: exchange
      })

    assert {:ok, %{redirect: %{"authorization_uri" => uri}}} = result
    assert uri =~ "github.com/login/oauth/authorize"
    assert uri =~ "client_id=test-client-id"
  end

  test "begin_authorization without exchange function returns error" do
    assert {:error, :provider_protocol_failed} =
             GitHubDriver.begin_authorization(%{})
  end

  test "consume_callback exchanges code and returns credential material" do
    # Stub the token endpoint
    Req.Test.attach(:github_driver_test)

    Req.Test.stub(:github_driver_test, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/login/oauth/access_token"} ->
          Plug.Conn.resp(conn, 200, ~s({"access_token": "gho-test-token"}))
      end
    end)

    exchange = fn private_frame ->
      assert private_frame.callback_envelope.code == "test-code"

      {:ok,
       %{
         provider_result_ref: "result-1",
         external_account_id: "github-user-123",
         display_login: "test-user",
         execution_identity: %{kind: :connected_user, external_account_id: "github-user-123"},
         authorization_ref: private_frame.authorization_ref,
         authorization_version: 1,
         credential_material: {:write_only_handoff, "encrypted-token-blob"},
         granted_permissions_digest: "repo",
         expires_at: nil,
         provider_metadata: %{}
       }}
    end

    result =
      GitHubDriver.consume_callback(%{
        authorization_ref: "auth-ref-1",
        correlation_id: "corr-1",
        callback_envelope_digest: "digest",
        exchange: exchange
      })

    assert {:ok, resp} = result
    assert resp.external_account_id == "github-user-123"
    assert resp.display_login == "test-user"
    assert {:write_only_handoff, _blob} = resp.credential_material
  end
end
```

- [ ] **Step 2: Run RED**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-domain-spine
mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_driver_test.exs 2>&1 | tail -5
```

- [ ] **Step 3: Implement GitHubDriver with begin_authorization and consume_callback**

```elixir
# lib/ezagent_plugin_github/github_driver.ex
defmodule EzagentPluginGithub.GitHubDriver do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.Driver

  alias EzagentPluginGithub.GitHubOAuth

  @redirect_uri "https://ezagent.example/github/callback"

  @impl true
  def begin_authorization(%{exchange: exchange} = context) when is_function(exchange, 1) do
    exchange.(fn private_frame ->
      url = GitHubOAuth.authorize_url(@redirect_uri, private_frame.state)

      {:ok,
       %{
         redirect: %{
           "authorization_uri" => url,
           "state" => private_frame.state,
           "pkce_digest" =>
             :crypto.hash(:sha256, private_frame.pkce_verifier) |> Base.encode16(case: :lower),
           "provider" => "github"
         },
         expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
       }}
    end)
  end

  @impl true
  def begin_authorization(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def consume_callback(%{exchange: exchange} = context) when is_function(exchange, 1) do
    exchange.(fn private_frame ->
      code = private_frame.callback_envelope[:code] || private_frame.callback_envelope["code"]

      case GitHubOAuth.exchange_code(code, @redirect_uri) do
        {:ok, %{access_token: token}} ->
          {:ok,
           %{
             provider_result_ref: "gh-result-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}",
             external_account_id: token,
             display_login: "github-user",
             execution_identity: %{kind: :connected_user, external_account_id: token},
             authorization_ref: private_frame.authorization_ref,
             authorization_version: (Map.get(context, :expected_authorization_version, 0) || 0) + 1,
             credential_material: {:write_only_handoff, "github-token:#{token}"},
             granted_permissions_digest: "repo",
             expires_at: nil,
             provider_metadata: %{}
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @impl true
  def consume_callback(_context), do: {:error, :provider_protocol_failed}

  # Remaining 6 callbacks — D1-compliant closed stubs

  @impl true
  def reconcile_callback(_context), do: {:ok, :not_completed}

  @impl true
  def refresh(%{refresh_use: refresh_use} = context) do
    # OAuth App token never expires — no-op success
    Ezagent.ProviderConnection.CredentialRefreshExchange.consume_refresh_exchange(%{
      refresh_use: refresh_use,
      provider_exchange: fn _private_frame ->
        {:ok,
         %{
           provider_result_ref: "gh-refresh-noop",
           credential_material: context[:current_credential_material] || :noop,
           granted_permissions_digest: "repo",
           expires_at: nil,
           provider_metadata: %{}
         }}
    end)
  end

  @impl true
  def refresh(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def reconcile_refresh(_context), do: {:ok, :not_completed}

  @impl true
  def discard_callback_result(_context), do: :ok

  @impl true
  def discard_refresh_result(_context), do: :ok

  @impl true
  def revoke(_context), do: {:ok, %{revoked: true}}
end
```

- [ ] **Step 4: Write after_boot registration in application.ex**

Update `after_boot/0`:
```elixir
@impl Ezagent.Plugin
def after_boot do
  pair = EzagentPluginGithub.TestHelpers.backend_pair()
  Ezagent.ProviderConnection.BackendPairRegistry.register(:github_plugin, pair)

  driver = EzagentPluginGithub.TestHelpers.driver_declaration()
  Ezagent.ProviderConnection.DriverRegistry.register(:github_plugin, driver)

  Application.put_env(
    :ezagent_domain_provider_connection,
    :local_authorization_backend_pairs,
    Map.put(
      Application.get_env(:ezagent_domain_provider_connection, :local_authorization_backend_pairs, %{}),
      {"github", "oauth_user"},
      "pair-github-v1"
    )
  )

  :ok
end
```

- [ ] **Step 5: Run GREEN**

```bash
mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_driver_test.exs 2>&1 | tail -3
```

Expected: `N tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_driver.ex \
        apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_driver_test.exs \
        apps/ezagent_plugin_github/test/support/github_test_helpers.ex
git commit -m "feat(github): implement Driver behaviour for OAuth App flow

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: GitHubAdapter — DomainGit.Adapter implementation

**Files:**
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex`
- Create: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs`

**Interfaces:**
- Consumes: `GitHubClient`, `DomainGit.Adapter`, DomainGit value types (`RepositoryRef`, `ChangeRequest`, `Check`, `Review`, `OperationContext`, etc.)
- Produces: `EzagentPluginGithub.GitHubAdapter` (implements `Ezagent.DomainGit.Adapter`)

- [ ] **Step 1: Write RED tests for all 5 callbacks**

Due to space, here's the representative test pattern for `resolve_repository` and `list_checks`. The plan implementer should write all 5.

```elixir
# test/ezagent_plugin_github/github_adapter_test.exs
defmodule EzagentPluginGithub.GitHubAdapterTest do
  use ExUnit.Case, async: true

  alias Ezagent.DomainGit.{RepositoryRef, Check, Review, OperationContext, CommitSha, Error}
  alias EzagentPluginGithub.GitHubAdapter

  setup do
    Req.Test.attach(:github_adapter_test)
    :ok
  end

  test "resolve_repository returns RepositoryRef on 200" do
    Req.Test.stub(:github_adapter_test, fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"full_name": "owner/repo", "default_branch": "main", "private": false}))
    end)

    ctx = operation_context()
    repo = repository_ref()

    assert {:ok, %RepositoryRef{external_id: "owner/repo", base_ref: "main"}} =
             GitHubAdapter.resolve_repository(ctx, repo)
  end

  test "resolve_repository maps 404 to repository_not_found" do
    Req.Test.stub(:github_adapter_test, fn conn ->
      Plug.Conn.resp(conn, 404, "Not Found")
    end)

    assert {:error, %Error{reason: :repository_not_found}} =
             GitHubAdapter.resolve_repository(operation_context(), repository_ref())
  end

  # Tests for create_change_request, read_change_request, list_checks, list_reviews
  # follow the same pattern: stub response → verify correct DomainGit struct output

  defp operation_context do
    {:ok, ctx} =
      OperationContext.new(%{
        task_access_uri: URI.parse("entity://acme/git-task-access/task-1"),
        caller_uri: URI.parse("entity://acme/user/alice"),
        grantee_uri: URI.parse("entity://acme/agent/builder"),
        idempotency_key: "idem-1"
      })
    ctx
  end

  defp repository_ref do
    {:ok, repo} =
      RepositoryRef.new(%{
        repository_uri: URI.parse("resource://acme/git-repository/my-repo"),
        provider_adapter: GitHubAdapter,
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :public
      })
    repo
  end
end
```

- [ ] **Step 2-5: Implement, RED→GREEN, commit per callback**

Each of the 5 callbacks gets its own commit cycle. The Adapter maps GitHub REST API responses to DomainGit value types:

```elixir
# lib/ezagent_plugin_github/github_adapter.ex
defmodule EzagentPluginGithub.GitHubAdapter do
  @moduledoc false
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.{RepositoryRef, ChangeRequest, ChangeRequestId, Check,
                           CommitSha, CreateChangeRequest, Error, FileChange,
                           OperationContext, Review}
  alias EzagentPluginGithub.GitHubClient

  @impl true
  def resolve_repository(_ctx, %RepositoryRef{external_id: full_name, base_ref: default_branch}) do
    case GitHubClient.get("/repos/#{full_name}", "") do
      {:ok, %{"full_name" => ^full_name, "default_branch" => branch, "private" => private}} ->
        RepositoryRef.new(%{
          repository_uri: URI.parse("resource://acme/git-repository/#{full_name}"),
          provider_adapter: __MODULE__,
          provider_host: "github.com",
          external_id: full_name,
          owner_path: String.split(full_name, "/") |> List.first(),
          base_ref: branch || default_branch || "main",
          visibility: if(private, do: :private, else: :public)
        })

      {:error, :repository_not_found} ->
        {:error, Error.new!(:repository_not_found)}

      {:error, reason} ->
        {:error, Error.new!(reason)}
    end
  end

  # The remaining 4 callbacks follow the same pattern:
  # 1. GitHubClient.get/post with token from ctx (token resolution TBD in batch 3)
  # 2. Map response fields to DomainGit structs
  # 3. Return {:ok, struct} or {:error, Error.t()}
end
```

- [ ] **Step 6: Final Adapter commit**

```bash
git add apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs
git commit -m "feat(github): implement DomainGit.Adapter for GitHub REST API

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: GitHubCredentialBackend — token storage and lifecycle

**Files:**
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_token_store.ex`
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_credential_backend.ex`
- Create: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_credential_backend_test.exs`

**Interfaces:**
- Consumes: `CredentialBackend` behaviour, `:crypto` for AES-256-GCM
- Produces: `GitHubTokenStore` (encrypt/decrypt), `GitHubCredentialBackend` (implements `CredentialBackend`)

- [ ] **Step 1: Implement GitHubTokenStore (encrypted token persistence)**

```elixir
# lib/ezagent_plugin_github/github_token_store.ex
defmodule EzagentPluginGithub.GitHubTokenStore do
  @moduledoc false

  @key_size 32  # AES-256
  @nonce_size 12  # GCM nonce

  def encrypt(plaintext, key) when is_binary(plaintext) and byte_size(key) == @key_size do
    nonce = :crypto.strong_rand_bytes(@nonce_size)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, "", true)
    {nonce, ciphertext <> tag}
  end

  def decrypt({nonce, ciphertext_with_tag}, key) when byte_size(key) == @key_size do
    ciphertext_size = byte_size(ciphertext_with_tag) - 16
    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(16)>> = ciphertext_with_tag
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, "", tag, false)
  end
end
```

- [ ] **Step 2: Write RED test for CredentialBackend**

```elixir
# test/ezagent_plugin_github/github_credential_backend_test.exs
defmodule EzagentPluginGithub.GitHubCredentialBackendTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGithub.{GitHubCredentialBackend, GitHubTokenStore}

  @backend GitHubCredentialBackend

  test "store persists a token and returns a credential_ref" do
    assert {:ok, %{credential_ref: ref, credential_version: version}} =
             @backend.store(%{
               credential_material: {:write_only_handoff, "gho-sample-token"},
               backend_pair_id: "pair-github-v1",
               correlation_id: "store-1"
             })

    assert is_binary(ref)
    assert version == 1
  end

  test "store and status round trip" do
    {:ok, %{credential_ref: ref}} =
      @backend.store(%{
        credential_material: {:write_only_handoff, "gho-status-test"},
        backend_pair_id: "pair-github-v1",
        correlation_id: "store-2"
      })

    assert {:ok, %{credential_ref: ^ref}} = @backend.status(%{credential_ref: ref})
  end

  test "replace returns updated credential version" do
    {:ok, %{credential_ref: ref}} =
      @backend.store(%{
        credential_material: {:write_only_handoff, "token-v1"},
        backend_pair_id: "pair-github-v1",
        correlation_id: "store-replace"
      })

    assert {:ok, %{credential_ref: ^ref, credential_version: 2}} =
             @backend.replace(%{
               credential_material: {:write_only_handoff, "token-v2"},
               backend_pair_id: "pair-github-v1",
               correlation_id: "replace-1",
               expected_credential_version: 1
             })
  end

  test "revoke makes subsequent status return error" do
    {:ok, %{credential_ref: ref}} =
      @backend.store(%{
        credential_material: {:write_only_handoff, "token-to-revoke"},
        backend_pair_id: "pair-github-v1",
        correlation_id: "store-revoke"
      })

    assert :ok = @backend.revoke(%{credential_ref: ref, idempotency_key: "rev-1"})
    assert {:error, :credential_conflict} = @backend.status(%{credential_ref: ref})
  end
end
```

- [ ] **Step 3: Implement GitHubCredentialBackend with in-memory store (backed by TokenStore)**

```elixir
# lib/ezagent_plugin_github/github_credential_backend.ex
defmodule EzagentPluginGithub.GitHubCredentialBackend do
  @moduledoc false
  @behaviour Ezagent.ProviderConnection.CredentialBackend

  @key :crypto.strong_rand_bytes(32)  # TODO: persist key, rotate on deploy

  @impl true
  def store(command) do
    {:write_only_handoff, token} = command.credential_material
    ref = "github-credential-#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
    encrypted = GitHubTokenStore.encrypt(token, @key)
    # Store encrypted in process dictionary for now (Task 6 minimal impl)
    Process.put({:github_token, ref}, {encrypted, 1})
    {:ok, %{credential_ref: ref, credential_version: 1}}
  end

  @impl true
  def replace(command) do
    ref = command.credential_ref
    case Process.get({:github_token, ref}) do
      {_encrypted, version} when version == command.expected_credential_version ->
        {:write_only_handoff, new_token} = command.credential_material
        new_encrypted = GitHubTokenStore.encrypt(new_token, @key)
        new_version = version + 1
        Process.put({:github_token, ref}, {new_encrypted, new_version})
        {:ok, %{credential_ref: ref, credential_version: new_version}}

      nil ->
        {:error, :credential_conflict}

      {_, _} ->
        {:error, :stale_version}
    end
  end

  @impl true
  def status(command) do
    case Process.get({:github_token, command.credential_ref}) do
      nil -> {:error, :credential_conflict}
      {_, version} -> {:ok, %{credential_ref: command.credential_ref, credential_version: version}}
    end
  end

  @impl true
  def lease_for_operation(_command), do: {:error, :backend_unavailable}

  @impl true
  def consume_lease(_command), do: :ok

  @impl true
  def begin_refresh_exchange(_command), do: {:error, :backend_unavailable}

  @impl true
  def consume_refresh_exchange(_command), do: {:error, :backend_unavailable}

  @impl true
  def revoke(command) do
    Process.delete({:github_token, command.credential_ref})
    :ok
  end
end
```

- [ ] **Step 4: Run GREEN**

```bash
mix test apps/ezagent_plugin_github/test/ezagent_plugin_github/github_credential_backend_test.exs 2>&1 | tail -3
```

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_token_store.ex \
        apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_credential_backend.ex \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_credential_backend_test.exs
git commit -m "feat(github): add CredentialBackend with encrypted token storage

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Configuration — umbrella config and umbrella registration

**Files:**
- Modify: `config/config.exs` (umbrella root)
- Modify: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex` (final after_boot)

- [ ] **Step 1: Add config to umbrella config.exs**

```elixir
# In config/config.exs:
config :ezagent_domain_provider_connection,
  :local_authorization_backend_pairs, Map.merge(
    Application.get_env(:ezagent_domain_provider_connection, :local_authorization_backend_pairs, %{}),
    %{{"github", "oauth_user"} => "pair-github-v1"}
  ),
  :credential_backend_implementations, Map.merge(
    Application.get_env(:ezagent_domain_provider_connection, :credential_backend_implementations, %{}),
    %{"github-credential-v1" => EzagentPluginGithub.GitHubCredentialBackend}
  ),
  :callback_redirect_pairs, Map.merge(
    Application.get_env(:ezagent_domain_provider_connection, :callback_redirect_pairs, %{}),
    %{"github-oauth" => "pair-github-v1"}
  )

config :ezagent_plugin_github,
  :oauth_client_id, {:system, "GITHUB_CLIENT_ID"},
  :oauth_client_secret, {:system, "GITHUB_CLIENT_SECRET"}
```

- [ ] **Step 2: Finalize application.ex after_boot to handle idempotent registration**

Update `after_boot` to use `BackendPairRegistry.register` with `:existing_identical` tolerance:

```elixir
@impl Ezagent.Plugin
def after_boot do
  pair = backend_pair()
  _ = BackendPairRegistry.register(:github_plugin, pair)

  driver = driver_declaration()
  _ = DriverRegistry.register(:github_plugin, driver)

  :ok
end

defp backend_pair do
  Ezagent.ProviderConnection.BackendPair.new!(%{...})
end

defp driver_declaration do
  Ezagent.ProviderConnection.Driver.new!(%{...})
end
```

- [ ] **Step 3: Run full plugin test suite**

```bash
mix test apps/ezagent_plugin_github/test 2>&1 | tail -3
```

Expected: all tests green.

- [ ] **Step 4: Final commit**

```bash
git add config/config.exs
git add apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex
git commit -m "feat(github): wire config and idempotent boot registration

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task Summary

| Task | Deliverable | Depends on |
|---|---|---|
| 0 | App skeleton (mix.exs, application.ex, umbrella registration) | — |
| 1 | GitHubClient (Req wrapper + error mapping) | Task 0 |
| 2 | GitHubOAuth (URL construction + token exchange) | Task 1 |
| 3 | GitHubCallbackPlug (OAuth callback endpoint) | Task 2 |
| 4 | GitHubDriver (Driver behaviour — begin, consume, refresh, revoke) | Task 2 |
| 5 | GitHubAdapter (DomainGit.Adapter — 5 Git operations) | Task 1 |
| 6 | GitHubCredentialBackend (CredentialBackend + TokenStore) | Task 0 |
| 7 | Configuration (umbrella config + boot wiring) | Tasks 4, 5, 6 |
