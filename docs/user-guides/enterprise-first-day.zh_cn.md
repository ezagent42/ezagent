# 企业用户第一天：从注册到第一次协作

本指南面向第一次使用 Ezagent 的团队负责人。全部步骤都可以在浏览器里完成，不需要运行 `mix` 命令或修改数据库。

## 1. 获得访问权限

打开 `/register`：

- 如果管理员开放了公开注册，填写邮箱、显示名称和密码。系统会为你创建一个独立 workspace，并将你设为该 workspace 的负责人。
- 如果公开注册关闭，可以提交访问申请；页面始终返回相同的“已收到”结果，不会泄露邮箱是否已经登记。
- 如果同事发来了邀请链接，直接打开 `/register?invite=...`。有效邀请在公开注册关闭时仍可使用，并且只会加入签发邀请的 workspace。

完成注册后，先点击确认邮件，再登录。登录会直接进入产品，不会强制展示开发者 PAT。

## 2. 确认 workspace

页面顶部会显示当前 workspace。进入 **Manage → Workspace** 可以查看成员、Session Template、路由规则和注册邀请。

当前自助注册采用“一次注册创建一个 workspace”的明确模型。加入其他 workspace 需要对应 workspace 的邀请。

## 3. 创建第一个 Agent

在首页点击 **创建 Agent**，选择适合的 flavor 并填写名称。Agent 列表会同时显示人类可读名称、flavor、运行状态和完整 URI；URI 是不可变身份，显示名称可以后续修改。

如果 Agent 调用模型时缺少密钥，错误消息会给出该 Agent 的 **Keys** 页面链接。workspace 负责人可以管理本 workspace 内 Agent 的 API key；密钥保存后列表只显示掩码。

## 4. 开始第一次协作

回到首页或 Sessions 页面：

1. 使用 `default` template 创建 Session。
2. 进入 Session 后添加 Agent 或成员。
3. 在消息中 `@` 对应 Agent，确认它能正常回复。
4. 需要复用团队配置时，在 workspace 详情页创建 Session Template。

## 5. 邀请同事

workspace 负责人进入 **Manage → Workspace → Registration invites**：

1. 设置最多使用次数和有效小时数。
2. 点击 **Create invite**。
3. 复制完整注册链接发送给同事。
4. 不再需要时点击撤销。撤销只阻止后续注册，不影响已经加入的成员。

不要把邀请码贴到公开工单、公共频道或代码仓库。邀请码等同于加入该 workspace 的临时凭证。

## 6. 管理员控制注册

管理员进入 **Manage → Admin → Settings**：

- **Open public registration**：允许新用户为自己创建新 workspace。
- **Require an invite**：公开注册开启时也必须提供 workspace 邀请。
- **Pending access requests**：查看公开注册关闭时提交的访问申请。

生产环境建议默认关闭公开注册，由 workspace 负责人签发有期限、有限次数的邀请。

## 常见问题

- **邀请链接无效**：邀请可能已撤销、过期或达到使用次数上限，请联系签发者重新创建。
- **看不到邀请管理**：当前身份没有该 workspace 的邀请管理 capability，或当前选择了另一个 workspace。
- **无法编辑 Agent API key**：确认当前 workspace 正确，并让 workspace 负责人或 Agent 创建者操作。
- **没有收到确认邮件**：请管理员在 **Admin → Settings** 检查 SMTP 配置并发送测试邮件。
- **页面显示错误 workspace**：从顶部 workspace 切换器选择目标 workspace；不要通过手改 URL 猜测租户。
