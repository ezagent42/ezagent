# GitHub Plugin 使用指南

## 概述

`ezagent_plugin_github` 以 **GitHub App**（app_id `4361756`）身份认证，提供两个能力：
1. **用户身份连接（user-to-server OAuth）**——用户授权，绑定 GitHub 账号身份（仅用于确认「谁」，不再申请 `scope=repo`）
2. **Git 操作**——通过 agent 调用 GitHub REST API；仓库操作使用 **App 安装令牌（installation token）**，由 App 私钥签发，而非用户令牌

使用分为三步：连接 GitHub 账号 → 签发 Git 操作权限 → agent 调用。

---

## 第一步：连接 GitHub 账号

### 前置条件

1. 配置 GitHub App（app_id `4361756`）：https://github.com/settings/apps
   - User authorization callback URL: `https://<你的 ezagent 地址>/github/callback`
   - 仓库权限：Contents、Pull requests、Checks
   - 在目标账号/组织上**安装** App（安装决定仓库访问权，而非用户令牌）
2. 设置密钥环境变量（详见 `docs/guide/github-plugin-config.md`）：
   - `GITHUB_APP_PRIVATE_KEY`（App 私钥 PEM，签发安装令牌）
   - `GITHUB_CLIENT_SECRET`（user-to-server OAuth）
   - `GITHUB_WEBHOOK_SECRET`（webhook 校验）
   - `GITHUB_TOKEN_ENCRYPTION_KEY`（凭据加密）

   `app_id` 与 `client_id` 为公开标识，已写入 `config/config.exs`。

### 调用 begin_authorization

通过 admin 用户发起授权，需要签发的 capability artifact：

```elixir
# 1. 构造 begin_authorization 的参数
args = %{
  connection_id: Ecto.UUID.generate(),
  provider_id: "github",
  governed_host: "github.com",
  acquisition_method: "oauth_user",
  requested_execution_identity_class: "connected_user",
  requested_permissions_digest: "user-to-server-identity",
  redirect_uri_id: "github-oauth",
  correlation_id: "github-auth-#{System.unique_integer([:positive])}",
  callback_artifact: callback_artifact  # 需要 Ezagent.Cap.issue/3 签发
}

# 2. 通过 Router dispatch 调用
Ezagent.Router.dispatch(%Ezagent.Invocation{
  target: Ezagent.URI.with_action(owner_uri, :user, :begin_authorization),
  mode: :call,
  args: args,
  ctx: %{caller: admin_uri, caps: admin_caps, mode: :call}
})

# 3. 返回
{:ok, %{attempt_ref: "...", authorization_url: "https://github.com/login/oauth/authorize?...", expires_at: "..."}}
```

将 `authorization_url` 返回给用户浏览器，用户点击后在 GitHub 授权。

### 回调处理

GitHub 授权完成后重定向到 `https://<host>/github/callback?code=...&state=...`。

回调 Plug 自动调用 `Ezagent.ProviderConnection.CallbackIngress.consume/3`，内部走完整流程：
- 验证 state / PKCE
- 用 code 换 access token（POST `https://github.com/login/oauth/access_token`）
- 调 `GET /user` 获取 GitHub 账号 ID 和 login
- token 加密存入 CredentialBackend
- 连接状态变为 `active`

回调成功返回 200。

---

## 第二步：签发 Git 操作权限

授权成功后，连接处于 `active` 状态。要让 agent 能执行 Git 操作，需要签发 `GitTaskAccess` capability。

```elixir
# 构造 capability
requested = Ezagent.Capability.cap(
  :git_task_access,                              # kind
  Ezagent.ActionSet.GitTaskAccess,               # behavior
  :create_change_request,                        # action（可签发多个）
  Ezagent.URI.instance("acme", "git-task-access", "task-1"),  # instance
  Ezagent.URI.workspace("acme")                  # workspace
)

# admin 签发
{:ok, artifact} = Ezagent.Cap.issue(
  {:admin, Ezagent.Entity.User.admin_uri()},
  agent_owner_uri,
  requested
)
```

**可用的 action**（都是 `Ezagent.ActionSet.GitTaskAccess` 上的）：

| Action | 做什么 |
|---|---|
| `:resolve_repository` | 验证仓库存在 + 获取默认分支 |
| `:create_change_request` | 创建 PR（含文件变更） |
| `:read_change_request` | 读取 PR 状态 |
| `:list_checks` | 列出 CI 状态 |
| `:list_reviews` | 列出 review 意见 |
| `:provision_workspace` | 为 Git 操作准备 workspace |
| `:cleanup_workspace` | 清理 workspace |

---

## 第三步：agent 调用 Git 操作

### resolve_repository

```elixir
{:ok, repo} = Ezagent.DomainGit.RepositoryRef.new(%{
  repository_uri: URI.parse("resource://acme/git-repository/my-repo"),
  provider_adapter: :github,
  provider_host: "github.com",
  external_id: "owner/repo",
  owner_path: "owner",
  base_ref: "main",
  visibility: :public
})

Ezagent.Router.dispatch(%Ezagent.Invocation{
  target: task_access_uri,
  mode: :call,
  args: %{repository: repo},
  ctx: %{caller: agent_uri, caps: agent_caps, mode: :call}
})
# => {:ok, %Ezagent.DomainGit.RepositoryRef{...}}
```

### create_change_request（建 PR）

```elixir
{:ok, repo} = RepositoryRef.new(%{...})
{:ok, base_sha} = CommitSha.new(%{value: "abc123..."})

changes = [
  {:ok, FileChange.new(%{path: "README.md", operation: :upsert, content: "# Updated"})}
]

request = {:ok, CreateChangeRequest.new(%{
  title: "feat: add new feature",
  body: "This PR adds...",
  head_ref: "feature-branch",
  expected_base_sha: base_sha
})}

Ezagent.Router.dispatch(%Ezagent.Invocation{
  target: task_access_uri,
  mode: :call,
  args: %{repository: repo, changes: changes, request: request},
  ctx: %{caller: agent_uri, caps: agent_caps, mode: :call}
})
# => {:ok, %Ezagent.DomainGit.ChangeRequest{
#       external_id: "123",
#       url: "https://github.com/owner/repo/pull/123",
#       head_ref: "feature-branch",
#       head_sha: "def456...",
#       base_ref: "main",
#       state: :open
#     }}
```

### list_checks（查 CI）

```elixir
{:ok, sha} = CommitSha.new(%{value: "def456..."})

Ezagent.Router.dispatch(%Ezagent.Invocation{
  target: task_access_uri,
  mode: :call,
  args: %{repository: repo, commit_sha: sha},
  ctx: %{caller: agent_uri, caps: agent_caps, mode: :call}
})
# => {:ok, [%Ezagent.DomainGit.Check{name: "CI", status: :completed, conclusion: :succeeded}, ...]}
```

### list_reviews（查 review）

```elixir
{:ok, cr_id} = ChangeRequestId.new(%{external_id: "123"})

Ezagent.Router.dispatch(%Ezagent.Invocation{
  target: task_access_uri,
  mode: :call,
  args: %{repository: repo, change_request_id: cr_id},
  ctx: %{caller: agent_uri, caps: agent_caps, mode: :call}
})
# => {:ok, [%Ezagent.DomainGit.Review{author_label: "reviewer", state: :approved}, ...]}
```

---

## 断开连接

```elixir
Ezagent.Router.dispatch(%Ezagent.Invocation{
  target: Ezagent.URI.with_action(owner_uri, :user, :revoke),
  mode: :call,
  args: %{connection_id: "...", expected_version: 1, assurance: assurance},
  ctx: %{caller: owner_uri, caps: owner_caps, mode: :call}
})
```

---

## 错误码

| 错误 | 含义 |
|---|---|
| `:authentication_rejected` | token 无效，需重新授权 |
| `:repository_not_found` | 仓库不存在或无权限 |
| `:provider_denied` | 权限不足或限流 |
| `:change_request_conflict` | PR 重复或参数无效 |
| `:provider_unavailable` | GitHub 没能给出可用应答（传输失败，或未专门分类的 HTTP 状态）。**可重试** |
| `:provider_response_unrecognized` | GitHub 应答成功（2xx）但内容读不懂 —— 未知枚举值、字段缺失或改名、body 形状不对。重发同样的请求会得到同样的结果，所以**不重试**、直接 blocked。看到这个码去查 GitHub API 是不是变了 |
| `:base_sha_mismatch` | base 分支已变化，需 rebase |
| `:base_ref_not_found` | base 分支不存在 |
| `:authorization_backend_unavailable` | CredentialBackend 未就绪 |
