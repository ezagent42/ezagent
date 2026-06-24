# L7 — world 渲染 + customer 公开视图

**日期:** 2026-06-24 · server 活 :10042

## world 渲染(L1 已验)
world UI(`world.localhost:10042`)各页正常渲染:Overview(Layout + Session activity)、Identities(agent 卡片)、Agent detail 等。证据见 `L1c-world-ui.png` / `agent-list.png` / `*-agent-detail.png`。

## customer 公开视图(本次)
用户经 world UI「New session」勾「Public socialware app」建会话 `session://system/public/public`(从 public_view 模板 `template://system/session/public@0a6690...` 物化)。

```
GET http://localhost:10042/socialware/customer?session_uri=session%3A%2F%2Fsystem%2Fpublic%2Fpublic   [无登录/匿名]
→ 200
→ <html data-theme="customer"><title>Socialware Customer</title> + /assets/css/customer.css + customer JS
日志: CustomerController.show/2 → CustomerFeed.snapshot + customer_page
      读 public 模板(public_view:true)→ 匿名放行,无 400 fail-closed
对照: 无 session_uri 参数 → 400(fail-closed 正确)
```

## 结论
✅ world 渲染正常 · ✅ customer 公开视图无登录可见(public_view 模板级闸门生效)。**L7 PASS,零 finding。**
