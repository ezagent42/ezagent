# 证据 · ezagent_plugin_mindmap 增量1 e2e + PR gate（2026-06-22）

> 分支 `feat/df-tech`（基于 e2abc02f）。工具链 mise OTP27/1.18.4。
> 本文是开发后的**实测证据**：所有结果均为真实运行输出，**杜绝想象、不伪造绿**。
> 对应设计 `docs/superpowers/specs/2026-06-22-mindmap-plugin-design.md`、计划 `docs/superpowers/plans/2026-06-22-mindmap-plugin.md`。

## 1 · e2e 验收（增量1 gate）— 通过 ✅

**做法**：真实 spawn 一个 Mindmap Kind 实例，经 `Ezagent.Invocation.dispatch/1`（P14 唯一合法通路）走完"建节点 → 导出 markmap 文件 → 模拟人改文件 → 导入回来 → 读树反映改动"的**双向往返**。

测试文件：`apps/ezagent_plugin_mindmap/test/e2e/roundtrip_test.exs`。

**关键步骤**（均经真实 dispatch）：
1. `Kind.Server.start_link({EzagentPluginMindmap.Mindmap, %{uri: "entity://system/mindmap/e2e-…"}})` + `ReadyGate` 等待就绪。
2. dispatch `mindmap.add_node` ×3（caps = `admin_genesis_cap`）→ 建根 + 两个子节点。
3. dispatch `mindmap.export_markmap` → 得 `"# 根\n## 子1\n## 子2\n"`，写入 `/tmp/mm_e2e_*.md`。
4. 模拟人在 XMind/markmap 改：追加 `## 子3`，存盘覆盖。
5. dispatch `mindmap.import_markmap`（读改后的文件）→ `count: 4`（文件覆盖）。
6. dispatch `mindmap.get_tree` → 断言树含 "子3"、节点数 4。

**真实输出**：
```
EzagentPluginMindmap.RoundtripTest [test/e2e/roundtrip_test.exs]
  * test 双向往返：建节点 → 导出 → 改文件 → 导入 → 树反映改动 (15.7ms) [L#25]
Finished in 0.1 seconds
1 test, 0 failures
```

**结论**：思维导图与 markmap 文件**双向打通**、ezagent 为真相源，在真实 ezagent 上验证可行——非臆想。

## 2 · 单元测试 — 通过 ✅

`apps/ezagent_plugin_mindmap/test/`：
```
..................
18 tests, 0 failures
```
- Markmap render/parse 往返（7）：单根 / 三层中文 / 空串失败 / 非根失败 / `render(parse(md))==md` / 幂等。
- Behavior handler（10）：create 空树 / add 建根+加子+parent_not_found / move 禁环+正常 / remove 级联 / export 空+渲染 / import 覆盖+解析失败不清空。
- e2e 双向往返（1，见上）。

## 3 · 仓库 PR gate（CONTRIBUTING.md）— 全绿 ✅

| gate | 命令 | 真实结果 |
|---|---|---|
| 编译 | `mix compile --force` | exit 0（全 umbrella，含 `:ezagent_plugin_check` 插件契约 gate 绿）|
| 架构 | `mix ezagent.arch.scan` | PASS `set_effect_sites: count=122 cap=122` |
| 不变式 | `mix ezagent.check_invariants` | ✓ all in-scope invariants clean |
| 生命周期 | `mix ezagent.check_invariants.lifecycle` | ✓ all Phase C lifecycle + naming gates clean |
| 文档覆盖 | `mix ezagent.doc.scan` | PASS `undocumented_public_defs: count=392 cap=392` |
| 格式 | `mix format --check-formatted <我的文件>` | rc=0 |

## 4 · 合规自查（不越界）✅

- 纯 plugin：新增代码全在 `apps/ezagent_plugin_mindmap/`。
- **唯一动到插件外的文件** = `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`，`set_effect_sites` 121→122——这是 arch.scan 文档规定的**法定 ratchet 抬升**（`# arch-cap-bump:` 注释带论证），**非逻辑改动、非绕过**。umbrella 基线本就卡在 cap=121，而"写状态的 Behavior 至少需 1 条 set-effect"是结构最小值；已把整棵树收进单一 `:tree` key + 唯一 `commit/1` 收敛到只新增 1 个站点。**此项已在 commit 与本文档显著标注，留待 review。**
- P14：跨 Kind 只走 `Invocation.dispatch`，无 `PubSub.broadcast` 到入站 topic（grep 验证）。
- 不手写 `def init/1`（check_invariants #2 绿）；插件不 import EventLog/SnapshotStore/StateRebuilder/Router internals/SagaRunner.execute（lifecycle gate 绿）。
- node_id 确定性（`"n"<>seq`，无 `Math.random`/时间）。

## 5 · 诚实声明：本增量未覆盖 / 推迟项

- **全量 `mix test`（整 umbrella）未跑到全绿**：主线存在**与本插件无关的既有失败**（liveview/workspace 那批，已在 df-prd 文档记录；本仓库无 CI、主线带红）。本插件自身 18 测试全绿、整 umbrella **编译干净**，证明本插件自包含、不破坏编译。
- **durable 持久化推迟到增量 1.5**：Mindmap Kind 当前 `:ephemeral`，往返在同一进程内验证通过；跨重启的 durable 快照（`:persistent`）是紧接的 fast-follow。
- **export/import mix 任务（CLI）推迟到增量 1.5**：独立 mix 任务够不到运行节点里的实例，且需 durable 持久化才能支撑"AI 建树→人改文件→导入"的跨进程循环。强行写会是伪能力，故**诚实推迟**，不伪造。e2e 已用 dispatch 证明导出/导入机制本身可行。
