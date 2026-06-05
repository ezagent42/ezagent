---
unit:
  tenant: cinnox
  role: customer
  slug: cinnox-flow-existing-bug-cinnox
  layer: tenant
  kind: flow_directive
chunk_id: cinnox-flow-existing-bug-cinnox
kb_type: flow_directive
layer: tenant
intent_trigger:
- existing_customer.bug.cinnox_product
source_section: §9.7a + §16 example (CINNOX bug · self-troubleshoot fixed)
extracted_at: '2026-05-19'
editable_by: tenant_admin
companion_examples:
- cinnox-flow-existing-routing
- cinnox-flow-har-export
enabled: true
---

# Flow: Existing Customer — CINNOX / AI Sales-Bot Bug (path C → 9.7a)

After the existing-customer router (`cinnox-flow-existing-routing`)
classifies path C (bug/complaint) AND Step 1 verification has
collected the 3 basic fields, determine the affected product type
BEFORE escalation:

> "明白了。这个问题主要影响以下哪一项?
> 1) CINNOX 平台 / AI 销售机器人 — 登录、对话、控制台功能异常
> 2) 全球电信资源 — DID 拨打不通、号段路由、PSTN 故障"
>
> EN: "Got it. Which area does this affect?
> 1) CINNOX platform / AI sales-bot — login, conversation, console feature
> 2) Global Telco — DID can't dial out, number-range routing, PSTN fault"

This flow handles **option 1** (CINNOX or AI sales-bot). Option 2
routes to `cinnox-flow-existing-bug-telco`.

## Self-troubleshoot — HARD-CODED 3 steps

Run the 3-step self-troubleshoot BEFORE escalation. Goal: let the
customer self-resolve common UI / session issues without burning a
human operator's time. Each step waits for the customer's confirmation
before advancing.

1. **Device + browser check**:
   > "先排除设备 / 浏览器原因:推荐用 Chrome 或 Safari;确认网络、麦克风、
   > 摄像头、屏幕录制权限都已开。试一下问题还在吗?"

2. **Logout + re-login** (only if Step 1 didn't fix it):
   > "嗯,那我们试下登出再登录一次。完成后告诉我问题还在吗?"

3. **Force-close browser** (only if Step 2 didn't fix it):
   > "那再麻烦您强制关闭浏览器,然后重新打开试试。问题还在吗?"

## After each step, wait for the customer's confirmation

- "解决了 / fixed / 好了" at any step → close the issue. Loop back to
  the existing-customer router in case they have more issues.
- "还是不行 / still broken" after Step 3 → enter the .har export
  guidance flow (`cinnox-flow-har-export`).

## Example: self-troubleshoot fixed (path C → 9.7a)

> Customer: "登入 CINNOX 之后 console 一直转圈。"
>
> Bot: "明白了，先核一下账户：1) 姓名 2) 公司 3) 联系方式（邮箱或电话）。"
>
> Customer: "李四 / Beta Ltd / li@beta.com"
>
> Bot: "这个问题主要影响以下哪一项？1) CINNOX 平台 / AI 销售机器人 — 登录、对话、控制台功能异常 2) 全球电信资源 — DID、PSTN 故障"
>
> Customer: "1，控制台。"
>
> Bot: "先排除设备 / 浏览器原因：推荐用 Chrome 或 Safari；确认网络、麦克风、摄像头、屏幕录制权限都已开。试一下问题还在吗？"
>
> Customer: "好了！换了 Chrome 就可以了。"
>
> Bot: "太好了。还有其他问题需要帮忙吗？"
