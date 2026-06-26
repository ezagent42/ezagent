# 2026-06-26 · E2E 自动化中发现的产品/UI 缺口

> 来源:本日把 `docs/e2e/` 黄金路径补成 agent-browser 可自动跑通时,用 agent-browser 实地跑 02→03→04 整链,撞到以下 3 个**后端/UI 缺口**。
> 性质:不是 E2E 文档问题,是 **world 操作员 UI 的产品缺口**——属今日 handoff 第二交付项(UI 修复清单)的素材。
> 判定纪律(guide §6 / CLAUDE.md grill 文化):**不在执行层擅自"修"**,记清复现 + 证据,交 lead/Allen 裁决是 bug 还是设计。

---

## GAP-1 · New Agent 表单建不出可对话 agent(`py` flavor 缺脚本入口)

- **复现**:`/identities/agents/new` → flavor 选 `py` → 填 name → 提交。
- **现象**:`#world-root` 的 `data-last-dispatch = "error:missing_script"`,agent 未创建。
- **根因推测**:py flavor 需要 `agent.py` 脚本,但 New Agent 表单**不提供脚本入口**。零配置可建的 flavor 是 `native`/`np`/`hello_builder`,**但这些不回显聊天**;唯一会逐字回显的是 seeded `py_default`(随 seed 带了 `echo.py`)。
- **后果**:**操作员无法从 UI 创建一个能对话的 agent** —— 要么建出不回话的 native,要么得有脚本的 py(但表单没地方放脚本)。黄金路径"创建 agent → 加入 session → 往返"用一个新建 agent 走不通。
- **严重度**:高(核心 onboarding 流程断裂)。
- **证据**:`evidence/scenario-02/s02-step3-uri-preview-auto.png`(表单)+ 实测 dispatch 串。
- **待裁决**:是 UI 漏了脚本字段 / 模板选择,还是 py agent 本就该走"建后在详情页配脚本"两步流程?

## GAP-2 · New session 默认模板 `advisor` 无效

- **复现**:`/sessions` → New session → 填名 → **不动模板下拉**(默认 `advisor`)→ 提交。
- **现象**:`data-last-dispatch = "error:{:invalid_template, %{\"class\" => \"session.advisor\", ...}}"`,session 未建。
- **对策(实测可绕)**:显式把 `#world-session-template` 选成 `default`(选项:`advisor / default / generic / hello`)→ `data-last-dispatch = "ok"`,session 建成。
- **后果**:**操作员照默认点 New session 必失败**,且报错只在 `data-last-dispatch` 属性、UI 无明显提示。
- **严重度**:中-高(默认路径即坏 + 错误不可见)。
- **待裁决**:`advisor` 模板类是否漏注册?还是默认不该是 advisor?是否该把默认改为 `default` 或在无有效模板时禁用提交并提示?

## GAP-3 · 邀请成员框拒绝裸名,只接受完整 URI

- **复现**:会话页 → Invite a member → `#world-invite-input` 填裸名 `e2e-native` → 提交。
- **现象**:`data-last-dispatch = "error:bad_member_uri"`,成员未加。
- **对策(实测可绕)**:填**完整 URI** `entity://system/agent/e2e-native` → 成功,成员 online。
- **对比**:聊天里的 `@mention` autocomplete **会**把裸名解析成成员(`@py` → `@py_default`);但邀请框**不做**这层解析,要求用户手敲完整 URI。
- **严重度**:中(可绕,但 UX 不一致 + 错误不可见)。
- **待裁决**:邀请框是否应复用 mention 的成员 autocomplete/解析?或至少接受裸 handle?

## GAP-4 · cc agent UI-create:字段约束无提示 + 有效提交静默失败

- **复现**:`/identities/agents/new` → flavor `cc` → 填 name → 提交。
- **现象链(2026-06-26 实测)**:① 不填 cwd → `error:cwd_required_for_cc`;② 填不存在的 cwd → `error:{:cwd_not_a_dir, "/tmp/e2e-cc"}`;③ cwd 填**已存在目录** → `data-last-dispatch="idle"` 但 **agent 未创建**(疑似 cc 慢激活撞 `invocation.ex` 5s 默认 deadline → activate_timeout 回滚,印证 scenario-05 记录的 UI-create DX bug)。
- **后果**:操作员无法从 UI 可靠创建 cc agent;且 ③ 是**有效提交却静默不创建**(无成功也无错误提示)。
- **严重度**:高(与 scenario-05 的 cc UI-path bug 同源:`agent_actions.ex` 创建未传足够 `deadline_ms`)。
- **待裁决**:UI 是否应为慢 flavor(cc/codex)传更长 deadline?cwd 约束是否应在表单内联校验+提示而非只落 `data-last-dispatch`?

## GAP-5 · 无「删除 session / 移除 session 成员」入口 → agent 删除死锁

- **复现**:清理 E2E 测试实体时,删 agent `e2e-native`(已加入 session `e2e-test-1`)→ `error:{:agent_bound_to_live_session, [session://system/default/e2e-test-1]}`。转去删那个 session → **找不到任何入口**:操作员 Sessions 列表页、会话页**成员行(只有 "Open terminal for X",无移除/踢出按钮)**、Admin 区,全都没有 delete/remove/terminate session 的 affordance。
- **死锁**:agent 绑在 live session 上就**删不掉**,而 session 又**删不掉**、成员也**移不掉** → 测试/陈旧 session+agent **只能累积**,除了 `mix ezagent.db.reset` 全量重置无清理路径。
- **CLI 也补不上**:`mix ezagent.workspace.remove_member` 是 **workspace** 成员(非 session 成员);无 `session.remove_member`/`session.delete` 任务;且这些 mix 任务 `Mix.Task.run("app.start")` 会和运行中 server 抢端口,无法旁路操作。
- **后果**:① 无 session 生命周期 teardown,运维债累积(陈旧 `r2-*`/`r3-*`/`e2e-*` 印证);② 连带 agent 无法删除;③ agent 上配的凭据(如 curl 的 api_key)随之无法清理。
- **严重度**:中-高(缺核心生命周期操作 + 连锁阻塞清理)。
- **待裁决**:会话页成员行是否应加「移除成员」?Sessions 列表/Admin 是否应加「删除/归档 session」?或提供 `mix ezagent.session.delete` 走运行中节点(非 app.start)?

---

## 备注:错误可见性是共性问题

三个 GAP 的报错都只落在 `#world-root` 的 `data-last-dispatch` 属性,**UI 层无 toast/inline 错误提示**。这与 `docs/e2e` 黄金路径反复撞到的「P22 没人接收要有人知道」是同一气味的 UI 侧表现:**后端 reject 了,但操作员在界面上看不到为什么**。建议 UI 清单里单列一条「表单/分发错误的用户可见性」。

> 全量 UI 巡检(handoff 第二交付项)尚未做;本清单只是 E2E 整链路 + 实体清理时**顺手撞到**的 5 条(GAP-1..5),优先级应在全量巡检后统一排。
