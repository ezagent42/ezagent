# Git Provider V1 D2 — GitHub Plugin Design

**Status:** draft  
**Date:** 2026-07-21  
**Amends:** `2026-07-17-git-provider-v1-downstream-roadmap-amendment.md` §4.4  

## 1. Scope and non-goals

D2 是 git team 的交付终点：一个能独立运行的 `ezagent_plugin_github` OTP app，OAuth 授权后可通过已有的 agent action/skill 机制被 agent 调用执行 Git 操作。

**包含：**
- GitHub OAuth App driver（`begin_authorization` → `consume_callback` → `refresh` → `revoke`）
- Git API adapter（5 个 `DomainGit.Adapter` 回调 via Req）
- CredentialBackend（token 加密存储 + 轮换）

**不包含：**
- GitHub App（installation model）——留到后续升级，Driver 接口同构
- Kanban 集成、socialware manifest 注册、agent skill 编排——Allen 层

## 2. OAuth flow（OAuth App）

```
User                ezagent_plugin_github        GitHub
 |                         |                        |
 |-- begin_authorization ->|                        |
 |                         |-- GET /authorize ------>|
 |<-- redirect to GitHub --|                        |
 |------------------------------------------------->|
 |                         |<-- GET /callback?code= -|
 |                         |-- POST /access_token -->|
 |                         |<-- access_token --------|
 |                         |-- store encrypted ------|
 |<-- connection active ---|                        |
```

**Driver 实现要点：**
- `begin_authorization`：构造 `https://github.com/login/oauth/authorize?client_id=...&state=...&redirect_uri=...&scope=repo`，通过 `exchange` 闭包把 `{state, pkce_verifier}` 传给框架
- `consume_callback`：调用 `POST https://github.com/login/oauth/access_token`（`code + client_secret`），返回 `credential_material: {:write_only_handoff, encrypted_token_blob}`
- `refresh`：GitHub OAuth App 的 access token 永不过期且无 refresh token。实现为 no-op——直接返回成功（通过 `CredentialRefreshExchange` 正常流转）。待后续升级 GitHub App 时实现真实 refresh token 轮换。

## 3. App structure

```
apps/ezagent_plugin_github/
  mix.exs
  lib/
    ezagent_plugin_github/
      application.ex              # use Ezagent.Plugin + boot
      github_driver.ex            # Driver behaviour (8 callbacks)
      github_adapter.ex           # DomainGit.Adapter behaviour (5 callbacks)
      github_credential_backend.ex # CredentialBackend behaviour
      github_client.ex            # Req wrapper for GitHub REST API
      github_oauth.ex             # OAuth URL construction + token exchange
      github_token_store.ex       # PostgreSQL encrypted token storage
      github_callback_plug.ex     # Plug for GET /github/callback
      config.ex                   # Configuration
  test/
    ezagent_plugin_github/
      github_driver_test.exs
      github_adapter_test.exs
      github_credential_backend_test.exs
      github_client_test.exs
    support/
      github_test_helpers.ex
```

**依赖：**
```elixir
{:ezagent_core, in_umbrella: true},
{:ezagent_domain_git, in_umbrella: true},
{:ezagent_domain_provider_connection, in_umbrella: true},
{:req, "~> 0.5"},
{:jason, "~> 1.4"}
```

## 4. Registration and configuration

**`application.ex` — `use Ezagent.Plugin`：**
```elixir
def plugin_info, do: %{slug: "github", name: "GitHub OAuth", ...}

def children, do: [
  {EzagentPluginGithub.GitHubClient, []}
]

def after_boot, do: register_driver_and_pair()
```

**`register_driver_and_pair/0`：**
```elixir
pair = BackendPair.new!(%{pair_id: "pair-github-v1", ...})
BackendPairRegistry.register(:github_plugin, pair)
DriverRegistry.register(:github_plugin, %Driver{
  provider_id: "github", acquisition_method: "oauth_user",
  implementation: GitHubDriver, backend_pair_ids: ["pair-github-v1"],
  ...
})
```

**`config/config.exs`（umbrella）：**
```elixir
config :ezagent_domain_provider_connection,
  :local_authorization_backend_pairs, %{{"github", "oauth_user"} => "pair-github-v1"},
  :credential_backend_implementations, %{"github-credential-v1" => EzagentPluginGithub.GitHubCredentialBackend},
  :callback_redirect_pairs, %{"github-oauth" => "pair-github-v1"}

config :ezagent_plugin_github,
  :oauth_client_id, {:system, "GITHUB_CLIENT_ID"},
  :oauth_client_secret, {:system, "GITHUB_CLIENT_SECRET"}
```

**web router 加一行：**
```elixir
forward "/github/callback", EzagentPluginGithub.GitHubCallbackPlug
```

## 5. Security boundaries

- `credential_material` 从 Driver 返回后立即进入 AEAD 加密存储，永不进日志/inspect/event
- `portable_secret?` 校验由 D1 的 `Support.validate_consume_result/5` 执行——credential_material 不能包含 pid/ref/port/function
- 所有 HTTP 调用（`github_client.ex` → `github_adapter.ex`）走 EffectBoundary 防泄漏
- token 存储：`github_token_store.ex` 用 Erlang `:crypto`（AES-256-GCM），per-connection 独立 nonce，启动时从 DB 解密到内存，不落磁盘

### 5a. Key management（TDD 最小实现 → 生产升级路径）

**TDD 阶段（batch 1-3）**：编译时生成随机 AES-256 密钥，存在模块属性中。测试不依赖外部密钥。

**生产升级路径**：`runtime.exs` 从 `System.fetch_env!("GITHUB_TOKEN_ENCRYPTION_KEY")` 读取 base64 编码的 32 字节密钥，启动时校验长度（`byte_size == 32`），长度不符立即 crash。密钥轮换：新密钥解密旧 ciphertext → 重新加密 → 更新 stored ciphertext。

### 5b. Token 存储实现路径

**TDD 阶段**：Process dictionary（`Process.put/2`），per-test-process 隔离，测试间不泄漏。

**生产升级路径**：ETS 表（`{:github_tokens, ref} -> {ciphertext, version}`），owned by `GitHubCredentialBackend` GenServer，crash 后重建（token 从加密 blob 重新加载），或直接升级为 Ecto schema（`github_tokens` 表，列 `id / credential_ref / ciphertext / nonce / credential_version / inserted_at / updated_at`）。

## 6. Error mapping

GitHub HTTP 状态码 → Driver/DomainGit 错误原子：

| GitHub 状态码 | 含义 | 映射错误 |
|---|---|---|
| 200-299 | 成功 | 正常返回值 |
| 401 | token 无效/过期 | `:authentication_rejected` |
| 403 | 权限不足/限流 | `:provider_denied` |
| 404 | 资源不存在（含私有 repo 未授权——GitHub 对非成员也返回 404） | `:repository_not_found` |
| 422 | 校验失败（如 PR 重复、ref 不存在） | `:change_request_conflict` |
| 5xx | 服务端错误 | `:provider_unavailable` |
| 网络超时/连接失败 | Req 层异常 | `:backend_unavailable` |

**GitHub 404 歧义说明**：GitHub 对"不存在"和"私有且无权限"都返回 404。D2 不做区分——统一返回 `:repository_not_found`。这是 GitHub 的故意设计（防止信息泄漏），ezagent 跟随。

## 7. Non-goals（明确排除，代码级记录）

- **GitHub App installation 流程**——D2 只做 OAuth App，Driver 接口同构，升级不改框架
- **分页处理**——D2 只做单页请求（default `per_page=100`），不做游标遍历。Adapter 调用者如需全量数据，在 skill 层做多次调用
- **速率限制**——D2 不做 rate limit 感知（不读 `X-RateLimit-Remaining` 头、不做 backoff）。调用频率控制属于上层（skill 编排）
- **Webhook 接收**——D2 不做 GitHub webhook（push event、check suite 等）。这些属于后续的 event-driven 功能
- **服务器端 revoke**——D2 的 `revoke` 只做本地 token 删除，不调 `DELETE /applications/{client_id}/token`。原因：OAuth App 的 client_secret 不应出现在 revoke 路径上（避免 code→token 和 revoke 共享 secret 面）

## 8. Testing strategy

**Driver 测试：** Req.Test stub HTTP响应，验证：
- `begin_authorization` 返回正确 GitHub authorize URL
- `consume_callback` POST 到正确 token endpoint，带正确参数
- 错误响应（401, 403, 404, 422, 5xx）映射到正确 Driver error 词汇表

**Adapter 测试：** 构造 DomainGit 值类型输入，验证输出 struct 字段正确 + 错误 JSON → `Error.t()`

**CredentialBackend 测试：** 验证 token 加密/解密往返、replace version CAS、revoke 后 status 返回 error

**集成测试（Task 8）**：完整 `begin_authorization` → `consume_callback` 流程，通过 `Store.execute/3` + Req.Test stub 验证 Driver 注册、回调 ingress、credential handoff 全链路

## 9. Implementation batches

| 批次 | 内容 |
|---|---|
| 1 | app 骨架 + GitHubClient + GitHubOAuth + OAuth Driver + callback Plug |
| 2 | Git Adapter（5 个 Req-based API 调用） |
| 3 | CredentialBackend（token 加密存储 + replace + revoke） |
| 4 | 集成测试 + 配置收尾 |