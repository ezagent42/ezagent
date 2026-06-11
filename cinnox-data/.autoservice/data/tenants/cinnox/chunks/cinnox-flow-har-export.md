---
unit:
  tenant: cinnox
  role: customer
  slug: cinnox-flow-har-export
  layer: tenant
  kind: flow_directive
chunk_id: cinnox-flow-har-export
kb_type: flow_directive
layer: tenant
intent_trigger:
- existing_customer.bug.har_export
source_section: §9.8 + §16 example (.har submitted → recap → transfer)
extracted_at: '2026-05-19'
editable_by: tenant_admin
companion_examples:
- cinnox-flow-existing-bug-cinnox
- cinnox-flow-attachments
enabled: true
---

# Flow: .har Export Guidance — after self-troubleshoot fails

When the customer reports a CINNOX / AI sales-bot bug that survived
all 3 self-troubleshoot steps in the bug-cinnox flow
(`cinnox-flow-existing-bug-cinnox`), ask them to export a browser
.har file so engineering can see exact network / console traces.

## Export instructions

> "好的,既然前面三步都没解决,我们就让工程师看下具体的网络日志。
> 麻烦您按以下步骤导出 .har 文件:
>
> 1. 在出问题的页面按 F12 打开浏览器开发者工具
> 2. 切到 Network / 网络 面板,勾选 'Preserve log / 保留日志'
> 3. 复现一次问题(让请求都录进来)
> 4. 在请求列表上右键 → 'Save all as HAR with content / 全部保存为 HAR'
> 5. 保存好后,点对话框左下角的 📎 上传附件按钮把 .har 文件发给我"

## Recap-then-handoff

After the customer confirms they've exported and attached the file
(handled per the `cinnox-flow-attachments` flow), emit a one-line
recap turn first:

> "好的，我整理一下：[姓名 / 公司 / 联系方式]；问题：[bug 现象一句话]；
> 自助 3 步（设备/浏览器、登出重登、强关浏览器）都已试过；.har 文件已收到。
> 我现在帮您接通工程师。"

EN:

> "Got it — to recap: [name / company / contact]; issue: [one-line bug
> description]; self-troubleshoot 3 steps (device/browser, re-login,
> force close) all tried; .har file received. Connecting you to an
> engineer now."

Then hand off on the next turn (same byte-pure contract as the
billing / telco recaps).

## Example: .har submitted → recap → transfer

> Customer: "登入之后 console 一直转圈，已经换了浏览器、重登、强关都试过了，还是不行。"
>
> Bot: *(Step 1 已完成；判定 path C；自助 3 步已穷尽，进入 .har 导出流程)* "好的，既然前面三步都没解决,麻烦您导出一份 .har 文件给工程师看 ... [导出步骤]"
>
> Customer: *(attaches console.har)* "传好了。"
>
> Bot: "好的，我整理一下：李四 / Beta Ltd / li@beta.com；问题：CINNOX console 登录后持续 loading；自助 3 步（设备/浏览器、登出重登、强关浏览器）都已试过；.har 文件已收到。我现在帮您接通工程师。"
>
> *(next turn: handoff)*
