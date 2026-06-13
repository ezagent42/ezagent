# 场景 35：外部用户匿名访问（仅限成员资格）

**分类**：1 — 认证与访问（登录、令牌、成员资格）
**状态**：🚧 确定性层部分完成（铸造/加入/读取 + 隔离已 GREEN；public_view 门控 +
48h GC 标记为 `@tag :pending_impl`）；实景层 = Allen / agent-browser 运行手册
**作者**：Claude，issue #51（规格说明
`docs/superpowers/specs/2026-06-12-external-user-anonymous-access-design.md`）

> 双语逐行镜像：[`scenario.md`](./scenario.md)。

## 意图

一个沿着分享链接进入的**匿名外部用户**必须能够**查看**会话——但仅限其 Template 被标记为
`public_view: true` 的会话，并且仅仅因为我们把他变成了一个真实的、只读的会话**成员**。
他无法读取任何其他会话，任何**写入**尝试都会引导他去登录。访问模型是**仅限成员资格**：
不引入任何新的"非成员可读"权限——匿名读取就是一个由临时匿名用户发起的、真实的
`Ezagent.Session.Membership.authorize/2` 成员读取。

这正是 B 线 E2E 收尾所需的匿名首次打开 → 写入门控 → 登录置换用户路径，
而此前的已认证成员 + 客户投递门控都没有覆盖它。

## 匿名用户（承重原语）

- 匿名用户是 `Ezagent.Entity.User` Kind 的一种变体：
  `entity://<被查看会话的工作区>/user/anon-<random>`。`anon-<random>` 名字是一个不可猜测的
  URL-safe 令牌；`anon-` 前缀是 GC 与过滤的句柄。
- 它在**构造上即只读**：其 `users.caps_json` 为空（没有 `User.default_caps/1`），
  因此 `User.initial_caps_for_spawn/1` 给它注入零个会话 cap。它只持有结构性的自我 Identity cap。
  → 它（通过成员资格）可读，但 `chat.send` 会在 CapBAC 第 5.5 步被拒。
- 它的工作区段 = 被查看会话的工作区，因此永远无法跨工作区使用。
- 在 `last_seen_at` 之后 48 小时由一个进程内受监督的 sweeper 进行 GC（**不是 Oban**——
  依赖树中没有 Oban）。

## public_view 是 TEMPLATE 级配置

一个会话可被匿名查看，当且仅当它所材料化自的 SessionTemplate 声明了
`public_view: true`。Template 未声明的会话即私有——匿名 GET 会跳转到 `/login`，
且不铸造任何匿名用户。这个决定在被授权的创建瓶颈处（Template）**只做一次**，
而不是由持有 URL 的人对每个会话重新论断。

## 用户路径（被测属性）

```
1. 从一个 public_view 的 Template 材料化出一个会话。
2. 匿名访客打开 GET /socialware/chat?session_uri=<该会话>。
   → 铸造匿名用户 + chat.join + 发放 ChatFeedAuth 令牌。
   → 成员资格门控的快照渲染出来（不是 /login 跳转）。
3. 访客尝试回复 → "登录后回复" CTA（不发送消息）；
   伪造的 send 被拒 :unauthorized（无静默丢弃）。
4. 访客登录 → 同一个会话渲染，现在带可用的撰写框；
   匿名用户已离开并被 GC。
5. 此匿名用户 / 匿名访客无法读取另一个（或非 public）会话。
6. 弃用 48 小时后，匿名用户被回收（离开 + 删除行）。
```

无新权限不变式：读取仅通过 `Session.Membership.authorize/2` 推进（对活的 `:session`
切片的成员资格）。不引入 `is_anon?` 分支、访客白名单或非成员读取路径。

## 验证——两层

### 第 1 层 — 确定性 ExUnit 测试（CI）

快速预门控位于 `apps/ezagent_domain_socialware/test/ezagent/socialware/`：

| 文件 | 证明什么 | 状态 |
|---|---|---|
| `anon_user_test.exs` | `AnonUser.mint/1` 恰好铸造一个只读匿名用户（`anon-` 前缀、被查看工作区段、空 caps_json 以致 `User.initial_caps_for_spawn/1` 给出零会话 cap）；`anon_uri?/1` 谓词 | GREEN |
| `anon_access_membership_test.exs` | 在 `chat.join` 已铸造的匿名用户后，`ChatFeed.snapshot/2` 授权它（成员资格门控读取通过）；非成员 / 另一个会话被拒；绑定到会话 A 的 `ChatFeedAuth` 令牌对会话 B `verify` 失败（跨会话隔离） | GREEN |
| `anon_public_view_test.exs` | `PublicView.public_view?/1` 为真当且仅当会话的 Template 声明 `public_view: true`；匿名访问入口仅对 public_view 会话铸造 | `@tag :pending_impl` |
| `anon_user_gc_test.exs` | sweeper 回收 `last_seen_at` 早于 48h TTL 的匿名用户（离开 + 删除 `users`/绑定行），并对新铸造者是无操作 | `@tag :pending_impl` |

运行：

```bash
cd apps/ezagent_domain_socialware && MIX_ENV=test mix test \
  test/ezagent/socialware/anon_user_test.exs \
  test/ezagent/socialware/anon_access_membership_test.exs
```

两个 `:pending_impl` 文件是尚未构建的 `PublicView` 读取器 + 绑定表 + GC sweeper 的 TDD
定义；它们被标记为 `:pending_impl`，以便 CI 默认的 `--exclude pending_impl` 在这些失败测试
作为可执行规格留存期间保持套件 GREEN。

### 第 2 层 — 实景 agent-browser 运行手册（Allen 的一次性栈——真正的门控）

在一次性栈上（`http://100.64.0.27:10044`，dev 模式，全新种子），其中有一个从
`public_view: true` Template 材料化出的种子会话，以及一个登录用户 `e2e-visitor`
（自生成密码）：

- **35a [视觉] 匿名首次打开渲染。** 全新浏览器上下文（无 cookie），打开该 public 会话的
  `/socialware/chat?session_uri=…`。截图：聊天快照渲染出来；URL 没有变成 `/login`。
  服务端断言：会话的 `:session` `members` 中现在有一个 `entity://<ws>/user/anon-…` 成员。
- **35b [视觉] 写入尝试提示登录。** 点击回复控件。截图：出现"登录后回复" CTA；不发送消息。
  服务端断言：伪造的 send 被拒 `:unauthorized` / `:login_required`（无静默丢弃）。
- **35c [视觉] 登录后 = 同一会话，匿名消失。** 跟随 CTA，以 `e2e-visitor` 登录。
  截图：同一会话渲染，带可用撰写框。服务端断言：`e2e-visitor` 是成员；`anon-…` 用户不再是成员，
  其 `users` + 绑定行已删除。
- **35d [视觉/授权] 跨会话 / 非 public 拒绝。** 另一个全新上下文：非 public 会话 URL 跳转
  `/login`（不铸造匿名用户）；把匿名用户的会话 A 令牌指向会话 B 被拒。截图拒绝/跳转。
- **35e [回归] 匿名进入不削弱成员门控。** 在匿名用户被 GC-离开后，其渲染视图立即清空
  （既有的 `unauthorized` 推送 + 关闭），且无后续消息——匿名用户由与真实成员相同的活成员
  谓词门控。

实景层在一次性栈上运行，不进 CI；截图 35a–35c 附到 Feishu 线程。

## 本场景锁定什么（防漂移）

- `Ezagent.Session.Membership.authorize/2` 保持逐字节不变——匿名读取就是成员读取，仅此而已。
- 匿名用户的只读性来自写入 cap 的**缺失**，绝不来自新的成员标志或访客白名单。
- `public_view` 是在被授权创建瓶颈处决定的 Template 策略，不是 URL 持有者的逐会话开关。
