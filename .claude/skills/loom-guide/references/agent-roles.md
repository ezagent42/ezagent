# Loom 角色体系 — 5 套 Behavior / Entity(Kind) / Template 三件套

每个角色由三个文件组成（`apps/ezagent_plugin_loom/lib/ezagent/` 下）：
`behavior/<role>.ex`（动作处理）+ `entity/<role>.ex`（Kind 声明）+
`template/<role>.ex`（flavor / Template Class 声明）。

## 角色一览

| 角色 | URI 命名 | 职责 | LOC（behavior） |
|---|---|---|---|
| **LoomOrchestrator** | `entity://agent/<ws>/loomorch_<sid>` | 每轮：拆解 → fan-out → 聚合 → 组 scene-card | 715 |
| **LoomWorker** | `entity://agent/<ws>/loomworker_<sid>_<theme>` | 主题内容片段（预制 theme：`policy` 政策侧 / `company` 企业侧；可自定义） | 229 |
| **LoomV0Worker** | `entity://agent/<ws>/loomv0_<sid>` | in-session AI **页面**生成（出第一个 JSX 代码块，page-gen prompt） | 317 |
| **LoomMetaAgent** | `entity://agent/<ws>/loommeta_<sid>` | 团队管家：@自然语言动态改 team（一次 @ = 一次 LLM = 一次 op） | 489 |
| **Loom** | （fixed-reply 测试桩） | 原始单 agent bot，迁移清单标记 🗑️ 纯测试桩 | 250 |

另有 `template/loom_agent.ex`：通用 pure-spawn flavor（不绑定具体角色）。

## 共同契约

1. **Mention-gated**：所有角色的 `handle_receive` 只在被 @ 时动手，其余消息一律
   忽略。没装任何自定义路由规则——默认 `system_default`
   （`{:always} → [$session_users, $mentions]`，`EzagentDomainInstanceMessage.DefaultRules`）
   已保证消息只投给被 @ 的 agent + User 成员，**worker↔worker 串话在结构上不可能**。
2. **ref_id 回执**：orchestrator 派单带 `ref_id`，worker 回复带同一 `ref_id`，
   orchestrator 按 ref_id 收齐聚合；dead-worker 兜底超时由 `LLM.max_run_ms/1` 推导。
3. **零 spawn-time 配置注入**：orchestrator 在运行时从 session members 发现 roster
   （`LoomOrchestrator.discover_workers/1`）；worker 从自己 URI 名末段读 theme
   （`LoomWorker.theme_for/1`、`worker_label/1` 正则 `loomworker_<sid>_<theme>`）。
4. **New-contract**：全部走 `use Ezagent.Behavior` + `action :receive` +
   `handle_receive(args, ctx) → {:ok, result, effects}`，LLM 调用统一走
   `EzagentPluginLoom.LLM.chat/2`（见 `llm-backends.md`）。

## 团队装配（两条路径）

- **主路径（现行）**：`template/loom_session.ex` —— `session.loom` Template Class。
  `instantiate/3` 起裸 Session Kind → `EzagentPluginLoom.Team.ensure_team/1`
  装配团队 → join 声明的成员。**幂等 reconciler**：重跑不重复 spawn、join 短路。
  /workspaces 的 "Add template" 表单即走这条。
- **早期路径（保留）**：`bootstrap.ex` —— per-visitor 命令式建 session + 临时用户
  + 绑飞书。迁移清单标记 🗑️。

⚠️ 历史事故：LiveView 的 `trigger_instantiate` 曾在 `Workspace.add_template/3`
内部 instantiate 之外再叠一发，导致 `Team.ensure_team` 重复 spawn + join、
chat.members 成员数翻倍 —— 该函数已整段删除（2026-06-01，见 `pitfalls.md`）。

## 存为模板 / 发布的动态 Class

`saved_classes.ex`：每次"存为模板"动态生成一个新 Template Class 模块
（template_name = `session.<name>`，发布为 `session.pub_<hex>`），注册进
`Ezagent.TemplateRegistry`，Class picker 自动可见；持久化在
`~/.ezagent/<profile>/loom_saved_classes.json`，boot 时重建模块。
删除（`delete_saved_class`）只摘注册 + 标记，已 spawn 实例继续活。

⚠️ 已知债：`saved_classes.ex` 直调 `TemplateRegistry.register/table`，违反
plugin 契约 SPEC §3.2 grep gate（注册必须走 `Ezagent.Plugin.boot/1` 声明），
迁移时按 `migration-map.md` 改 `template.read/write` 重做。

## 已知测试债

`loom_orchestrator_test.exs` 的 `worker_label/1` 测试用了无 sid 段的 fixture
（`loomworker_policy`），不匹配 2026-06-01 引入的 `loomworker_<sid>_<theme>`
正则 → 预期 "policy" 实得 "worker"。分支上既有失败，修 fixture 或修正则二选一。
