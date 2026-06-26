# Agent Console — QA 发现报告(2026-06-26)

> **范围:** `world` 插件的 agent console 全生命周期(创建→查找→查看→使用→修改→删除→删后验证)
> **基线:** main `6f123b8b`
> **方法:** 浏览器手动点击 + Playwright 自动跑,均钉后台状态(console 日志 / dispatch result)
> **测试计划:** [manual-tests/agent-console-manual-test-plan.md](manual-tests/agent-console-manual-test-plan.md)
> **证据截图:** `evidence/console-e2e/`、`evidence/lifecycle-e2e/`

## 结论

生命周期主干**功能可用**:创建(curl/py)、查找、查看、**进会话+收发消息(完整编排闭环)**、配置增改删(持久)、API key 读写、删除、占用禁删(后端)——全部跑通。

下面 **6 个发现**,其中 **F3 / F4 是静默失败类**(违反 "no silent drops"),建议优先。**F3 影响默认建会话流程**,优先级最高。

---

## F3 —【高】新建会话默认模板 `advisor` 无效,且失败被 UI 静默吞掉

- **现象:** `/sessions` → New session,模板下拉**默认选中 `advisor`**;直接点 Create → 后端返回 `{:invalid_template, %{"class" => "session.advisor"}}`,创建失败。**UI 无任何反馈**:表单关闭、列表仍 "No sessions in this workspace."、无报错 banner。
- **影响:** 新用户走默认流程**建不出会话且不知道为什么**。改选 `default` 才成功。
- **证据:** console `HANDLE EVENT "world:dispatch" session.create {template_name:"advisor"}` → `INSERT invocations … result {:invalid_template, class:"session.advisor"} … exception`。
- **根因方向:** ① 模板下拉提供了一个无效/未注册的 `advisor` 作为**默认选项**(有效的是 `default`,见 `conversation_actions.ex:64` 默认 `"default"`);② `session.create` 失败路径没有 push error banner(对比:`agents.create` 失败**有** banner,见 F-对比)。
- **建议:** 下拉默认值改为有效模板(或移除 `advisor`);`session.create` 失败补 error 反馈。

## F4 —【中-高】详情页删除"占用中"的 agent:后端禁删生效,但 UI 零反馈

- **现象:** agent 正处于一个 live session 时,在**详情页**点 "Delete agent" → "确认删除" → 确认框收起、agent 仍在、**无任何提示**。
- **后端是对的:** `agent_live_sessions/1` 命中 → 阻止删除(console 见 delete dispatch 后 `EntityPresenter.display(session://…/qa-session-1)` 在拼 "正在 N 个对话中" 文案)。
- **问题:** 该禁删 banner 被 push 到 **agents-list 路由**的 `action_error`,而用户是在**详情页**触发的 → 看不到。等于静默。
- **建议:** 详情页就地渲染禁删原因 banner("该 agent 正在 N 个对话中(…),先移出再删除")。

## F7 —【中-高】无 UI 移除会话成员 / 删除会话 → 占用中的 agent 根本删不掉(放大 F4)

- **现象:** 会话对话页**没有** remove-member / kick / end-session / delete-session 任何控件(只有 Invite a member / Open terminal / Restart orchestrator / routing 规则)。
- **影响:** F4 的禁删提示是"先从这些对话移出再删除",但 **UI 上没有"移出"入口** → 一旦 agent 被加进任意 live session,就**无法再通过 UI 删除**(也无法删除/关闭会话本身)。本次清理 `qa-browser-1`/`qa-session-1` 即卡在此。
- **建议:** 补成员移除(从 session `:leave`/踢出)+ 会话删除/归档入口。

## F6 —【中】py flavor:必填 script 未在前端标注/拦截 + 错误是裸 atom

- **现象:** 建 py agent 不填 Python script → Create 不禁用(script 无 `*`)→ 提交后报 **`创建失败: :missing_script`**(裸 atom,其他 create 错误都翻译成中文)。填了 script 能建成功。
- **建议:** Python script 标必填 + 客户端拦截;`:missing_script` 翻译成友好文案。

## F1 —【低-中】agents 列表无 flavor 过滤

- **现象:** `/identities/agents` 没有过滤/搜索条;`AgentsTable`(Identities.tsx:238)未接 `FilterBar`(组件在 :184,仅通用 identities 列表用)。
- **影响:** agent 多时不好找。组件 + `agent_flavors` 数据都在,接上即可。

## F2 —【低-中】删除后旧详情 URL 渲染"空壳详情页"

- **现象:** 删除后直链旧 `/identities/agents/<uri>` → 仍渲染完整详情布局,`Phase: not_found`、flavor 从 URL 推断、config 全 `nil`,**无明确"已删除/不存在"空态**。
- **建议:** 该状态显示明确的 not-found 空态。

## F5 —【低/cosmetic】Entity Caps 的 `instance` 列 dump 原始结构

- **现象:** `/…/caps` 表的 `instance` 列显示 `%URI{scheme: "entity", userinfo: nil, host: "system", path: "/agent/qa-browser-1", …}`,而非 `entity://system/agent/qa-browser-1`。
- **建议:** 渲染规范 URI 字符串。

---

## 对比观察(非 bug,佐证 F3)
- `agents.create` 失败**有**红 banner(实测 "同名 agent 已存在: …";cwd 必填/caps 格式均有客户端校验)。说明 create 错误反馈是**有能力做对的**,F3 的 session-create 静默是**遗漏**,不是全局设计。
- 创建页 error banner 在更改输入后**仍滞留**(改了 flavor/name 还显示上次错误)——轻微 UX,按规格可能是 by-design,留作 backlog。

## 通过项(供参考)
创建(curl 跳详情/py)· 列表 · 详情(Phase/Flavor/Template/Bridge/granted caps/还没接线)· **邀请进会话→@发消息→agent 回复(错误回灌不静默)** · 配置三层 cascade 增/改/删持久 · API key 写入掩码显示 · 普通删除确认流 · Extensions/Caps/PTY 页(非 PTY flavor 优雅降级)。
