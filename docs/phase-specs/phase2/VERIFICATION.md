# Phase 2 — VERIFICATION

> Phase 2 验收契约。**先于 PLAN.md 写**(Decision #80)。
> 配套:`SPEC.md` / `PLAN.md` / `DECISIONS.md`(将在 brainstorm sign-off 后写)

## 验收原则(继承 Phase 1)

1. **验证 SUPERSETS 人类 review**(memory `feedback_goal_human_ergonomic_verification`):自动 gate 跑的所有 check 中,**必须包含人类 review 时实际会做的所有事**;gate 可以**比**人类做的更多。**任何 UI-touching phase 的最终 gate MUST 以 `agent-browser screenshot` 结尾**

2. **人 review 步骤要人体工程学**:任何需要人手动输入的步骤,必须**提供完整 paste-able 文本**。

3. **User actions required 显式列出**(memory `feedback_flag_user_assist_steps`):每个 sub-step gate 把"需要用户介入的步骤"显式标出来,不能 silently scope down 成"agent 自己跑完"。Phase 2 部分 e2e 需要 user 在另一个终端启动 claude;**这一步必须显式 surface**。

---

## Phase 2 整体 demo(验收的终极标准)

Allen 应该能跑通这条流(顺序敏感):

1. Ezagent 启动(`mix phx.server`)
2. 第二个终端启动真 claude session(`bash scripts/cc-bridge-attach.sh`)
3. agent-browser 打开 `http://100.64.0.27:4000/admin`
4. LV 显示 **session://main** 里有两个成员:`user://admin`(自己 boot 即存在)和 `agent://cc-builder`(claude 上线后加入)
5. LV 表单输入"你好",发送
6. claude TUI 看到 `<channel source="esr-bridge" sender="user://admin">你好</channel>`
7. claude 回复
8. **LV 的 audit/message stream 现在显示两条形状一样的 chat row**:
   - `[user://admin]: 你好`
   - `[agent://cc-builder]: 你好,我能帮你...`
   两条都是 `%Ezagent.Message{}`,不再有"主消息流 vs ← from claude 独立面板"区分
9. 浏览器刷新 → 所有历史消息仍可见(MessageStore 持久)

**offline / rejoin 测试**(F1.5,Phase 2 新增的"真双向 + 状态机"验证):

10. Allen `Ctrl-C` claude TUI → Agent Kind 死 → LV 显示 cc-builder 离线状态(状态变 offline)
11. Allen 在 LV 发"还在吗?" → 消息持久到 MessageStore 但没有 receiver online → LV 看到自己的消息但 cc-builder 行显示"offline"
12. Allen 重新跑 `cc-bridge-attach.sh` → Agent Kind 重新 spawn → :join → Session 从 MessageStore 把"还在吗?"replay 给 cc-builder
13. claude TUI 看到刚才离线时的消息,回复
14. LV 显示完整的 chat 历史 + 新 reply

---

## Sub-step 切分(候选)

Phase 2 切 3 个 sub-step,每个有自己的 gate:

| sub-step | 名字 | 主题 | 终极 demo |
|---|---|---|---|
| **2a** | data 层 | Message struct + MessageStore + Chat Behavior 接口契约 | `mix test` 验各模块单元;无 e2e |
| **2b** | router 接线 | Session/Agent/User Kinds + Chat 各 action handler + boot/dynamic spawn 配齐 + LV 改用 Session 视图 | agent-browser 验:LV 显示 session 内 chat row,Echo button 还能用,member list 实时更新 |
| **2c** | bridge 切换 + 真 e2e | bridge POST 流改走 Agent Kind 自 dispatch,LV "← from claude" 老面板删,offline/rejoin 行为加入 | 上面"整体 demo" + offline/rejoin 全跑通,人眼 screenshot |

---

## Gate per sub-step

### 2a Gate · data 层 + 抽象

- [ ] `Ezagent.Message` struct 6 字段 + `new/3` + `Jason.Encoder`
- [ ] `Ezagent.MessageStore` 4 函数(`write/2`, `in_session_since/2`, `recent_in_session/2`, `by_uri/1`),Ecto 实现 + custom URI type
- [ ] `Ezagent.Behavior.Chat` 行为契约定义(4 actions menu + interface schema for `%Message{}` 作 args)
- [ ] SQLite migration:`messages` 表 + 2 索引(per §10.4)
- [ ] 单元测试覆盖:Message 构造 / MessageStore 4 函数读写 / Chat Behavior @interface schema
- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix test` 全绿
- [ ] `mix format --check-formatted` clean
- [ ] `mix ezagent.check_invariants` exit 0(继承 Phase 1 + Phase 2 不引入新不变式)

### 2b Gate · router 接线

- [ ] `Ezagent.Entity.Session` Kind 模块 + Application boot 时 spawn `session://main`
- [ ] `Ezagent.Entity.User` 升级为真 Kind(Phase 1 stub callbacks 去掉,加 Chat Behavior :receive 实现)+ boot spawn `user://admin`
- [ ] `Ezagent.Entity.Agent` Kind 模块 + DynamicSupervisor wiring + bridge announce 时由 controller 触发 spawn
- [ ] Chat Behavior 4 invoke clauses 实现(`:send` / `:receive` / `:join` / `:leave`),Process.monitor + `:DOWN` 处理
- [ ] BehaviorRegistry per-Kind subset 注册(Session 接 send/join/leave,Agent/User 接 receive)
- [ ] LV `/admin` 加 "Session" 区域显示 session://main 成员列表(在线/离线状态)
- [ ] 单元 + 集成测试:Chat Behavior 各 action handler / boot Kind 存在 / :join 后 monitor 建立 / `:DOWN` 后 last_seen 写入
- [ ] 1a/1b 原 functionality(Echo button / Manual Dispatch / audit log)不退化
- [ ] G1/G2/G3 gates(同 2a)

### 2c Gate · bridge 切换 + 真 e2e(强制最终 gate)

- [ ] CcBridgeAnnounceController.reply/2 改为通知对应 Agent Kind(不再写 `Server.record_reply`)
- [ ] Agent Kind 收到 reply 通知 → 构造 `%Ezagent.Message{sender: self_uri, body, mentions: ...}` → dispatch `session://main/behavior/chat/send`
- [ ] LV `/admin` 老的 "← from claude" 独立面板**删除**;reply 在主 message stream 显示
- [ ] **LV chat-window UI 重建**:垂直 message stream + 成员侧栏(在线/离线状态)+ 底部 compose 区(bridge dropdown + 文本 + 发送)。Allen 输入和 claude 回复**视觉模板一致**(同一种 chat row component,只 sender / 颜色微差)。Phase 1 老的 Echo button / Manual Dispatch form / Audit Log 仍可达但**移到 "Debug" 区**(折叠或独立 tab),不占主视野
- [ ] LV 主 message stream 用 MessageStore.recent_in_session(50) on mount 加载历史
- [ ] offline / rejoin 状态机:Process.monitor 建立,`:DOWN` 写 last_seen,rejoin 时 replay
- [ ] **USER ACTION REQUIRED 显式列**:

  > **Allen 操作步骤**(无法 agent 自动化):
  > 1. 在 Ezagent 的一个终端跑 `mix phx.server`(esrd)
  > 2. 在第二个终端跑 `bash scripts/cc-bridge-attach.sh`(启动真 claude session, interactive 模式)
  > 3. 第三个终端 / 浏览器打开 `http://100.64.0.27:4000/admin`

- [ ] agent-browser F1 e2e(自动化部分):
  - open /admin → snapshot 看 Session 成员列表显示 admin + cc-builder
  - 在 Send-to-Claude form 选 `agent://cc-builder` + paste 文本 "你好" + click Send
  - snapshot 看 LV chat stream 多一条 `[user://admin]: 你好`
  - 等 5-15s(claude 推理)→ snapshot 看 LV 又多一条 `[agent://cc-builder]: <回复>`
  - **关键 invariant 重述**:两条 row 走**同一个 Phoenix HEEx template**;只 `sender` 字段是 data-driven 变量,template 内根据 `sender` URI scheme(`user://` vs `agent://`)选 `data-sender-scheme="user"` 或 `data-sender-scheme="agent"` 属性,该属性触发不同浅色背景 CSS class。**Pass 条件**:DOM 检查两条 row 的 component template 一致,无独立 `<section class="from-claude">` 或类似面板;只有 inline `data-sender-scheme` 属性 + 背景 class 差异
  - screenshot 到 `/tmp/phase2-final.png`

- [ ] **offline/rejoin 验证**(agent 半自动 + Allen 配合):
  - Allen 在 claude 终端 Ctrl-C(USER ACTION)
  - agent-browser snapshot 看 LV 显示 cc-builder offline
  - LV 表单发"还在吗?" → snapshot 看到 message 已发但 cc-builder 还 offline
  - Allen 重跑 `cc-bridge-attach.sh`(USER ACTION)
  - agent-browser snapshot 看 cc-builder 重新 online + claude TUI 收到 replay 的"还在吗?"+ 给出新回复
  - screenshot

- [ ] SQLite 验证(paste-able):`SELECT count(*), sender FROM messages WHERE session_uri = 'session://main' GROUP BY sender;` **期望输出**:Allen 发了"你好" + "还在吗?"两条,claude 各回了 1 条 → 共 4 行,2 个 sender:
  ```
  2|user://admin
  2|agent://cc-builder
  ```

- [ ] **Phase 1 regression script(自动化)**:
  - agent-browser open /admin → expand "Debug" `<details>` toggle 可见 → click → click "Echo 测试" button → snapshot 验 audit log 多一行 `agent://echo/behavior/echo/say, authz=stub_grant`
  - 在 Debug 区 Manual Dispatch form paste:`agent://echo/behavior/echo/say` / `{"msg": "回归测试"}` / mode `call` → click Dispatch → snapshot 验 audit log 多一行 `result=ok`
  - 这两步证明 Phase 1 Echo + Manual Dispatch 没退化

---

## Phase 2 整体 Gate(`phase2` tag = 2c 完成)

- [ ] 2a + 2b + 2c 全部 sub-step gate 绿
- [ ] `git tag phase2` 存在并 push origin
- [ ] `sub-step-gate.sh` 在 commit `phase2` 时实际跑过且通过
- [ ] `docs/phase-specs/phase2/VERIFICATION.md` 全部 checkbox 打勾(执行记录)
- [ ] `mix ezagent.check_invariants` 输出干净
- [ ] `/tmp/phase2-final.png` screenshot 生成并拷贝进 `docs/phase-specs/phase2/artifacts/`
- [ ] Phase 1 所有 functionality 不退化(回归):Echo button / Manual Dispatch / audit log 仍工作

---

## 人 review 关键点(Allen)

- LV `/admin` 主 stream 里 claude 回复跟 Allen 输入**没视觉差异**?(没了"← from claude"独立面板?)
- offline 时 LV 是否清晰显示成员离线状态 + pending 消息数?
- rejoin 后 claude 是否真看到了离线期间发的消息?
- BEAM 重启后 LV 仍能看到旧 session 历史(MessageStore 持久)?
- 多个 bridge 同时连(假设用不同 EZAGENT_AGENT_URI)是否各自独立工作?(Phase 2 boundary 测试)

---

## 不变式 grep(继承 Phase 1)

```bash
# Phase 1 不变式 #1-#7 继续 grep(实际命令在 mix ezagent.check_invariants 已自动化)
mix ezagent.check_invariants
```

Phase 2 不引入新硬不变式 — Chat / Message / MessageStore 的 invariants 通过单元 + 集成测试覆盖,不走 grep 路径。
