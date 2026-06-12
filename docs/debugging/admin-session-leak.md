# Admin Session 泄露问题分析

> 日期: 2026-06-12

## 现象

每次服务重启后，operator 页面偶尔出现一个"admin"会话条目。DB 中会多出 `session://system/cs/admin` 记录。

## 根因链

```
system admin 浏览器窗口
  → 访问 /autoservice (customer 页面)
    → CustomerLive.mount
      → CustomerSession.ensure_joined(entity://system/user/admin)
        → ensure_session → 创建 session://system/cs/admin
        → join(session, customer) → join(session, fast_agent) → fast agent 不存在 → ERROR
```

**为什么 system admin 会访问 `/autoservice`？**

1. **主动点击**: `MasterDashboardLive` 页面有个链接 `href="/autoservice/tenant/<tid>"`。这是个无效路由（404），但 admin 可能手动导航到 `/autoservice`。

2. **LiveView 自动重连**: 服务重启后，Phoenix LiveView JS 自动重连。如果 admin 窗口曾以某种方式处于 `/autoservice`，重连触发 `mount/3` 重新执行。

3. **DevAutoLogin 副作用**: 任意窗口访问 `?as=` 参数即可切换身份。admin 窗口的 session cookie 存的是 `entity://system/user/admin`，如果误入 `/autoservice` 就会触发 session 创建。

**为什么 session://system/cs/admin 会出现在 operator 列表？**

不会出现在 `workspace://cinnox` 的 operator 页面——两个 session 在不同 workspace。operator 看到的是 `session://cinnox/cs/admin`（如果 cinnox admin 也误入了 `/autoservice`）。

## 为何之前没有这个问题

`43e6c845` 之前，admin 页面可能不存在独立路由，admin 用户直接访问 `/autoservice` 是正常的。当前实现了独立的 `/admin/autoservice` 路由和 master dashboard，但缺少访问控制——`/autoservice` 路由对所有已登录用户开放，不区分角色。

## 错误的修复思路（已记录）

两次尝试添加代码层防护（guard/hook），均被拒绝。原因：

1. 测试页面上加角色检查 → 隐藏了真正问题（admin 为何到了 customer 页面）
2. 这是"打补丁"思维——在症状处加判断，而非修正错误的数据流

**正确的方向**：确保浏览器重连到正确的 URL，而非在服务端拒绝合法请求。LiveView 自动重连机制应该保持用户在原页面，不应跳转到其他路由。

## 当前处理

- 每次测试用 `bash scripts/dev_test_start.sh` 启动，确保 seed 数据完善
- 服务重启后关闭旧窗口，重新打开无痕窗口
- `session://system/cs/admin` 在 DB 中的残留由下次 seed 覆盖（seed 脚本在创建 session 前先清理 DB）
