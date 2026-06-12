# AutoService 调试记录 — 2026-06-12

## 背景

完成 autoservice Phase D 后启动测试，发现三个问题：customer 输入框文字看不清、发送无回应、operator 页面为空、admin 崩溃。

## 问题 1: Feishu WsClient 日志爆炸

**现象**: `mix phx.server` 输出文件 85 分钟膨胀到 516K/5889 行，全是：
```
[warning] EzagentPluginFeishu.WsClient: cannot start (:credentials_unfilled); retry in 5000ms
```

**根因**: `ws_client.ex` 硬编码 `@restart_backoff_ms 5_000`，credentials 缺失时每 5s 重试一次，永无止境。

**修复** (`4067c39d`):
- `:credentials_unfilled` / `:credentials_not_found` → **不重试**（永久性配置错误，重试无意义），log 一次 warning 后 `enabled? false`
- sidecar crash → 指数退避 5s→10s→20s→40s→80s→160s→300s(cap)，首次 warning 后续 info

**影响范围**: 1 文件 `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/ws_client.ex`

---

## 问题 2: Admin 页面崩溃

**现象**: 打开 `/admin/autoservice?as=admin&workspace=system` 后重定向到 `/sessions`，然后 GenServer timeout。

**根因**: URL 中的 `&` 在通过 cmd.exe 传递时被解释为命令分隔符，`workspace=system` 被丢弃。实际登录身份是 `entity://cinnox/user/admin`（种子脚本创建的 workspace-scoped admin），而非 `entity://system/user/admin`。前者不满足 `:require_admin` gate（`admin?/1` 只认 system admin URI），被 bounce 到 `/sessions`。

**修复** (`2edf339a`):
- DevAutoLogin plug: 改为使用完整 entity URI `?as=entity://system/user/admin`，避免 `&` 在 shell/cmd.exe 中被截断

**影响范围**: 1 文件 `scripts/dev_test_start.sh`

---

## 问题 3: Chat 输入框文字看不清

**现象**: customer 页面输入框文字与背景色对比度低。

**根因**: `ChatUI.composer` 组件的 `<input>` 没有显式设置 `text-gray-900` 和 `bg-white`，在 dark theme 下默认文字颜色可能是浅色。

**修复** (`2edf339a`):
- 添加 `text-gray-900 bg-white placeholder-gray-400` 到 input class

**影响范围**: 1 文件 `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/chat_ui.ex`

---

## 问题 4: Customer 发送消息无回应

**现象**: customer (alice) 发送消息后没有 AI 回复。

**根因**: `CustomerSession._ensure_joined/1` 在 LiveView mount 时只恢复了 session + customer 的 join，**没有 re-join fast agent**。

**链路分析**:
1. 种子脚本 (`ezagent.demo.seed_autoservice`) 在自己的 BEAM 里创建 session、fast agent、join、发 greeting
2. 种子 VM 退出 → 所有 Kind 进程死亡
3. 服务 VM 启动 → `Workspace.Loader.load_all/0` 从 workspace 的 `session_templates` 重新实例化 fast agent（`curl.agent` template）✅
4. Customer 打开 `/autoservice` → `CustomerSession.ensure_joined` 被调用
5. `_ensure_joined` 做: `ensure_user_alive` → `ensure_session` → `join(customer)` → **结束**
6. ❌ **fast agent 没有被 join** → session Kind rehydrate 后丢失了 join 成员信息
7. Customer 发消息 → dispatch 到 session → session 尝试 route 到 fast agent → fast agent 不在 session 的成员列表里 → 消息丢失

**验证**: DB 中存在 fast agent snapshot (`entity://cinnox/agent/curl_fast-alice`, `curl_fast-bob`)，`DEEPSEEK_API_KEY` 已配置。fast agent Kind 进程在运行（Loader 已实例化），但不在 session 的 join 列表里。

**修复** (`3c8b4231`):
- `_ensure_joined` 增加 `join(session_uri, fast_uri, ctx)`

**影响范围**: 1 文件 `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_session.ex`

---

## 问题 5: Operator 页面 session 列表为空

**现象**: operator (op) 打开 `/autoservice/operator` 后看不到任何 customer session。

**根因**: URI 格式变更导致 filter 失配。

`Uris.session_uri/1` 的 URI 格式是:
```
session://<workspace>/cs/<name>    # 例: session://cinnox/cs/alice
```

但 `list_cs_sessions` 的 filter 写的是:
```elixir
|> Enum.filter(&String.starts_with?(&1, "session://cs/"))
```

`String.starts_with?("session://cinnox/cs/alice", "session://cs/")` → **false**

session snapshot 存在于 DB 中:
```
session://cinnox/cs/alice  workspace="workspace://cinnox"
session://cinnox/cs/bob    workspace="workspace://cinnox"
```

但因为 filter 匹配不上，operator 永远看到空列表。

**修复** (`3c8b4231`):
```elixir
# Before
|> Enum.filter(&String.starts_with?(&1, "session://cs/"))
# After
|> Enum.filter(&String.contains?(&1, "/cs/"))
```

**影响范围**: 2 文件（两处同名 operator_live.ex，分别位于 `ezagent_plugin_autoservice` 和 `ezagent_plugin_liveview`）

---

## 其他发现

### 单浏览器多角色登录限制

当前 session 架构使用单一 `_ezagent_web_key` cookie 存储 `current_entity_uri`。一个浏览器只能有一个身份。登录 B 会覆盖 A。

解决方案：Chrome 无痕窗口 × 3，每个有独立 cookie jar。

### DevAutoLogin plug

新增 `EzagentWeb.Plugs.DevAutoLogin`（`970587e9`）：dev 环境通过 `?as=<handle>` 或 `?as=entity://system/user/admin` 自动登录，跳过登录表单。GET-only，redirect 移除参数，prod 编译期裁剪。

### 测试启动脚本

新增 `scripts/dev_test_start.sh`（`970587e9`）：一键 seed + 启动 + 打开 3 个无痕窗口分别登录 customer/operator/admin。

---

## 提交记录

| Commit | 描述 |
|---|---|
| `4067c39d` | fix(feishu): stop infinite retry loop on permanent credential errors |
| `970587e9` | feat(dev): DevAutoLogin plug + test startup script |
| `2edf339a` | fix(autoservice): chat input text visibility + admin URL encoding |
| `3c8b4231` | fix(autoservice): re-join fast agent on rehydrate + fix session URI filter |

## 待验证

- [ ] Admin 用完整 entity URI `?as=entity://system/user/admin` 能否正常进入 `/admin/autoservice`
- [ ] Customer 发消息是否有 AI 回复（已 re-join fast agent）
- [ ] Operator 能否看到 customer session 列表（已修复 filter）
