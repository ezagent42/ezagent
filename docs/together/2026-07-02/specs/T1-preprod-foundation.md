# SPEC T1 · pre-prod 基建收口: ActionSet 改名 + config:// 去 URI 化 + URI gate 兜底

> **Date:** 2026-07-02 · **Owner:** Allen (lead) + Claude · **Base:** origin/main `adf5fad5`
> **窗口:** 下周上生产 → 最后能低成本改基础概念命名/寻址格式的时间（cap 身份 + config subject 一旦铸进生产数据，迁移代价高）。
> **独立于 T2(app-package)**：先做，T2 rebase 到本任务之上。文件重叠仅 `definition_registry.ex`（不同函数，低冲突）。
> **闸门:** 定稿 → codex 对抗性评审（钉 origin/main）→ plan+handoff → codex 实现。

## 0. 为什么这三件合成一个基建任务

三者都是"上线前的地基收口"——纯机制/寻址/命名，**不含业务语义**，且都受"pre-prod 是最后低成本窗口"约束（改的东西会铸进生产持久化数据）。合成一个任务是因为它们同源（都触及持久化标识 + gate），且都必须在上线前落地。

---

## 项目 A · Behavior → ActionSet 改名

### A.1 为什么
`Ezagent.Behavior` 名不副实——它是"某领域的一组 action handler"（moduledoc `behavior.ex:1` 自述："contract for a piece of action-handling logic"，声明 `actions/0` + 每 action 一个 `handle_<action>`），不是单个行为；且撞 Elixir 内建 `@behaviour`。`ActionSet` 更准。

### A.2 改名面 + 关键坑（codex 核实，非纯机械）
- **规模**：`Ezagent.Behavior` 在 lib 里 **212 文件 / 777 处**。
- **坑 1 — cap 身份嵌 module（5 轴，非 3）**：cap = `{kind, behavior_module, action, instance, workspace}`（`capability.ex:5-7` + `capability/match.ex:7-18`）。改 behavior 模块名 → **cap 逻辑身份变**。cap JSON 序列化 behavior 模块字符串（`capability/normalize.ex:7-23`），strict decode 期望已加载模块名（`normalize.ex:164-205`）。→ `users.caps_json` / seeds / fixtures / snapshots 里的旧 `"Ezagent.Behavior.*"` 字符串**不会自动 rebuild**。
- **坑 2 — `:kind_base` 是 load-bearing 运行时状态**：`KindBase` 持久化确切 behavior 模块列表（`behavior/kind_base.ex:3-45`）；`effective_set/2` reload 后与声明模块求交（`kind/behavior_set.ex:51-58,171-207`）；session Kind 缺 `:kind_base` 直接 raise 要求 backfill（`behavior_set.ex:180-193`）。现有 backfill 明说 test/sandbox only（`ezagent.kind_base.backfill.ex:4-17`）。
- **坑 3 — 动态/字符串引用机械替换会漏**：`Module.concat([:Ezagent, :Behavior, :Session])`（`ezagent.stress.ex:95-104`）；cap decoder 错误文案 + 测试里的字符串模块名（`normalize.ex:181-185`）。

### A.3 做法
1. 全局 `Ezagent.Behavior.X` → `Ezagent.ActionSet.X`（module 定义 + 所有引用，212 文件）。
2. **stale behavior-string 迁移/清洗（codex T1 #3 — 不只 caps_json）**：behavior 模块字符串**存在多处持久化**：`users.caps_json`（`normalize.ex:7,17`）+ **recipe body**（`recipe_registry.ex:361,367`，decoder 要已加载 atom `recipe.ex:200`）+ **socialware definition body**（`definition.ex:75,80,135`）+ seeds/fixtures/home data。全部重写 `Ezagent.Behavior.*` → `Ezagent.ActionSet.*`；pre-prod dev 可 wipe+reseed。
3. **snapshot 处理**：`kind_snapshots.:kind_base` 里的旧模块 atom → 决定 **wipe+rebuild dev / 或 boot 时 loud stale-module 扫描**（不是静默）。
4. **动态引用**：修 `Module.concat([:Ezagent,:Behavior,...])`（`ezagent.stress.ex:95-104`）+ 字符串常量 + cap decoder 错误文案（`normalize.ex:181-185`）。
5. **grep gate（codex T1 #4 — 扩大 pattern）**：CI 拒绝 `Ezagent.Behavior\b`（不只 `.` 后缀——含 `defmodule Ezagent.Behavior`/`@behaviour Ezagent.Behavior`/`use Ezagent.Behavior`，`lifecycle.ex:199-200`）+ `:Behavior`(atom) + `Module.concat([:Ezagent,:Behavior` + **持久化 body/caps_json 字符串** + 选定的 test/support/docs fixture（`scenario_30_..._test.exs:64-65`）。扫描范围 `apps`（不只 `apps/*/lib`）。arch gate 元数据 `"Behavior" => [{:required_caps,0}]`（`arch.scan.ex:184`）改 `"ActionSet"`。

### A.4 不变式
- 改名零**生产**迁移（pre-prod 无生产 cap）；dev 数据 wipe+reseed。
- grep gate 上线后，旧 `Ezagent.Behavior.` 字符串不可再出现（含 caps_json / snapshots）。

---

## 项目 B · config:// → 结构化非-URI subject

### B.1 为什么
ConfigStore 的 subject 现在写成 `config://<ws>/<kind>/<name>`（`definition_registry.ex:definition_subject_uri` + recipe 同格式），**长得像 URI 但**：(a) 从不被 `Ezagent.URI.new!` 解析（grep 零处）；(b) 从不被别的 scheme 对象跨引用（grep 零处）；(c) `config` 不是注册 scheme（`scheme_registry.ex:14-18` 只有 6 个）。→ 它是"伪 URI"，违背"所有 URI 必须走 Ezagent.URI"的 gate 意图。

### B.2 subject 的真实语义
ConfigStore 按 `(layer, workspace_uri, subject_uri, key)` 四元组定位（`config_pointer.ex:32` `id = join([...],"\|")`）。**subject = 被配置对象的身份**（哪个 socialware / 哪个 recipe），**key = 配置类别**（`"socialware"`/`"recipe"`/`"advisor.behavior"`）。workspace 已是独立字段 → subject 里不需再嵌 workspace。

### B.3 做法
**scope 收窄（codex T1 #1）**：ConfigStore 的 subject 是**通用**的——agent config 用 `agent_uri`、socialware install 用 `session_uri` 当 subject（`agent/config.ex:197`、`installation.ex:177,230`），这些**是真 entity URI、不能动**。B **只改 `config://<ws>/<kind>/<name>` 那类"伪 URI subject"**（socialware definition + recipe），不碰用真 URI 当 subject 的。
1. subject 从 `"config://<ws>/<kind>/<name>"` → **结构化非-URI 标识**：`"<kind>:<name>"`（如 `"socialware:autoservice"` / `"recipe:orchestrator"`），去掉 `config://` 前缀 + workspace 段（workspace 已单列）。**仅限 definition/recipe 的 subject builder。**
2. 改 subject builder：`DefinitionRegistry.definition_subject_uri` + recipe registry 的对应函数 → 生成新格式。
3. **数据迁移（codex T1 #2 — 三处，非只列）**：
   - `socialware_config_objects.subject_uri` + `socialware_config_pointers.subject_uri` 列的存量 `config://` 串。
   - **`ConfigPointer.id` 把 subject 嵌进主键**（`config_pointer.ex:31-33`）→ 迁移要**重建 pointer id + 碰撞预检**（先例：`20260627..._rename_advisor_behavior_to_agent_soul.exs`）。
   - **`socialware_config_objects.body` JSON 里内嵌的 `definition_subject_uri`**（`installation.ex:240,244`）→ 也要 rewrite,列迁移不够。
   - pre-prod dev 可 wipe+reseed 规避大部分。
4. 更新 moduledoc（去掉 "config://... mirroring role-as-data" 措辞）。

### B.4 不变式
- subject 不再是 `<scheme>://` 形态 → 不与 URI 体系混淆。
- 只由 ConfigStore subject builder 构造（不许别处裸拼）。
- workspace 不在 subject 内（避免与四元组的 workspace_uri 重复）。

---

## 项目 C · URI gate 兜底（枚举 → 全 scheme 拦截）

### C.1 为什么
`uri_query/scan.ex:25` 的 `@affected_schemes` 是**固定 6 元白名单**（entity/session/template/resource/workspace/system），检测 `String.contains?(text, scheme<>"://")`。→ **任何列表外 scheme（config:// 就是）零防御**，静默绕过 gate。这是"枚举式"漏洞。

### C.2 做法
1. scan 从"只查 6 个已知 scheme"改成"**任何 `<scheme>://` 裸构造/解析都报**，除非该 scheme 在显式 allowlist"。即 default-block unknown（fail-closed，符合 let-it-crash）。
2. **两个 allowlist（codex T1 #5 — 防误伤）**：
   - **ezagent 一等 URI scheme**（6 个：entity/session/template/resource/workspace/system）→ 必须走 Ezagent.URI。
   - **外部传输/协议 URL 白名单**：`postgresql://`(`home/migration.ex:558`) / `unix://`(codex remote) / `http(s)://`(curl/feishu) / `cc-bridge://`(audit 合成 id) 等**现有在用的**→ 登记为"允许的外部 URL"，不报。
   - **只对"ezagent-like 未知 scheme"硬拦**（既非一等 scheme、又非登记的外部 URL）。config 在 B 之后已非 `://`，自然不触发。
3. 若未来要加真 scheme → 必须同时进 `scheme_registry` + gate allowlist，否则 CI 红。**加新外部 URL 也要显式进白名单**（逼作者声明"这是外部 URL 不是 ezagent 寻址"）。

### C.3 不变式
- 未知 `<scheme>://` 默认被 gate 拦（翻转 default-allow → default-block）。
- 加新 scheme 必须显式登记两处（registry + gate），无静默绕过。

---

## 分 PR

- **PR-A1 ActionSet 改名**（212 文件机械替换 + 动态引用修 + arch 元数据）
- **PR-A2 stale-cap/snapshot 迁移 + grep gate**（依赖 A1）
- **PR-B config:// → 结构化 subject + 数据迁移**（独立于 A）
- **PR-C URI gate 兜底**（依赖 B 落地后，config 已非 `://`）

依赖：A1→A2；B→C；A 与 B 并行。全部 pre-prod 窗口内完成、上线前 merge。

## DoD
- [ ] `grep -rn "Ezagent.Behavior\b" apps` = 0（含 `defmodule`/`@behaviour`/`use`/字符串/测试 fixture；不只 `apps/*/lib`）；grep gate 绿。
- [ ] cap/ConfigObject-body/snapshot 里无残留 `Ezagent.Behavior.` 字符串（含 `users.caps_json` / recipe & definition body / `:kind_base`）。
- [ ] `grep -rn "config://" apps` = 0；subject 全为结构化格式；`socialware_config_objects.body` 内嵌的 subject 也已迁移；`ConfigPointer.id` 已重建（碰撞预检）。
- [ ] URI gate：未知 `foo://bar` ezagent-like 裸串 → CI 红；现有外部 URL（postgresql/unix/http/https/feishu/cc-bridge）在白名单、不误报。
- [ ] **skill 同步**：`ezagent-developer` skill 全 references 的 `Ezagent.Behavior` → `Ezagent.ActionSet`；grep skill 目录无残留（config:// / Behavior 旧引用）。
- [ ] 全套 arch gate + precommit 绿（300s timeout 跑 arch）。
- [ ] dev 数据 wipe+reseed 后系统正常（cc/socialware/recipe 都能起）。

## 开放点
1. snapshot(`:kind_base`) 处理：wipe+rebuild dev vs boot-time loud 扫描？（我倾向 pre-prod wipe+reseed，最简。）
2. subject 分隔符：`"socialware:autoservice"`（冒号）vs `{kind, name}` 结构 map？（冒号串更省改动，map 更类型安全。）
