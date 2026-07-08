# dev-together 回顾 · 2026-07-07 周期

数据窗口：`merged:2026-07-07`（GMT+9 工作日，含 07-08 UTC 凌晨的 #1230 / #1234 / #1237 三笔——按 GMT+9 归本工作日）。本回顾面向全体开发者：呈现产品大局、统计团队效能、诚实复盘事故与教训。

## 指标速览

- **~15 个 PR 合入**（本工作日范围，见下方口径）
- **代码变更 +5,691 / −4,867 = 10,558 行**（口径注：−4,130 来自 #1214 删除部署资产，非功能量；扣除后功能净增约 +5.6k）
- **6 份 spec 两日内写就并经 codex 对抗评审判 SOUND**（orchestration 4 份 + crgov/manifest + M3）
- **编排主线 M1→M2→M3 代码全量合入 main**（注：M3 部署尚未跑通，见 §2 事故）
- **贡献者 3 人**：allenwoods（13）· jjkysy（1）· zyli-developer（1）——本日高度集中于 lead

## 大局

本工作日主线是把「编排即 socialware」（orchestration-as-socialware）从设计落成可运行的三级里程碑，并同步完成**部署迁移**（把部署资产从应用仓库剥离、修复上线阻断）。

- **编排线 M1→M2→M3**：M1（声明式角色编排路由，#1212，前一周期）→ 四个支线修复（T1 行为折叠 / T3 mention 按角色解析 / T4 安装可靠性 / T2 dispatch 立场）→ M2（编排器本身成为 socialware 定义）→ M3（socialware 可声明 requires 依赖、自动安装）。一句话：**「一个 socialware 可以依赖另一个 socialware（含编排器），并自动装齐」这条能力链打通。**
- **平台面**：会话列表按成员过滤（关闭 W0 per-entity-membership 缺口）、agent 成员显示名修复、sw-home 单次晚扫 manifest 车道、关键前端资产本地化。
- **部署迁移**：应用仓库不再承载部署资产（+ gitleaks 扫描），PTY UTF-8 码点边界修复根治长 CJK 回合杀死 PTY，随后修复迁移连带问题。

## §1 昨日工作统计（按主题分组）

### 编排线（orchestration-as-socialware）

| PR | 标题 | 开发者 | summary |
|---|---|---|---|
| #1219 | fix(agent): 模板物化时折叠 recipe 行为（T1） | allenwoods | 模板实例化把 recipe 行为折叠进 agent，编排角色行为正确挂载 |
| #1220 | feat(world): 按 role_name facet 解析 @mention（T3 / #1201④） | allenwoods | @提及按角色名解析，编排器可按角色寻址成员 |
| #1221 | [codex] 安装/一致性可靠性 bundle（T4） | allenwoods（codex） | 安装可靠性 + 卸载不留残规则（primary 目标依赖的清理保证） |
| #1225 | [codex] 经 capabilities 派发 hello rebuild（T2） | allenwoods（codex） | dispatch 立场 + M2-follow-up 一致性 warn（spec ⑦，待 stable 验证） |
| #1223 | feat: 让编排器成为 socialware 定义（M2） | allenwoods | 编排器不再是特例，收编为标准 socialware |
| #1230 | [Done] feat(socialware): requires 依赖安装（M3） | allenwoods | socialware 可声明 requires；装 A 自动装齐依赖 B（含编排器） |

### 平台

| PR | 标题 | 开发者 | summary |
|---|---|---|---|
| #1217 | fix(session): 会话列表按成员过滤（关闭 W0 缺口） | allenwoods | 列表只显示自己是成员的会话 |
| #1216 | Fix agent member display names | zyli-developer | 修复 agent 成员显示名 |
| #1224 | feat(socialware): sw-home 车道——单次晚扫 manifest，无早期投机 | jjkysy | boot 车道晚扫，避免早期投机式扫描 |
| #1222 | fix(web): 关键资产本地化 | allenwoods | 关键前端资产本地服务，去外链依赖 |

### 部署迁移

| PR | 标题 | 开发者 | summary |
|---|---|---|---|
| #1214 | chore: 从应用仓库移除部署资产（+ gitleaks） | allenwoods | 部署资产脱离应用仓库；引入 gitleaks 扫描（−4,130 行） |
| #1215 | fix(pty): 码点边界缓冲裁剪（#1201①） | allenwoods | 长 CJK 回合不再杀死 PTY server |
| #1234 | fix(deploy): 恢复 entrypoint.prod.sh——Docker 构建需要 | allenwoods | 修复 #1214 连带删除（Dockerfile.prod 仍 COPY 它） |
| #1237 | fix(ci): 更新 full-suite runner 标签——解阻 CI 队列 | allenwoods | 修复 runner 标签大小写不匹配，解阻 CI 队列 |

### Spec 合入

| PR | 标题 | 开发者 | summary |
|---|---|---|---|
| #1228 | docs(spec): M3 requires socialware→socialware 依赖——SOUND rev2 | allenwoods | M3 设计 spec，codex 对抗评审判 SOUND |

> **口径**：本工作日「今日」范围 = 上表 15 个 PR。#1212（M1）、#1213（crgov+manifest）、#1211/#1210（spec）、#1201（handoff）属前一周期上下文，此处仅作大局引用，不计入 15。

## §2 事故与教训（诚实复盘——这些最有价值）

### 事故 A — CI mac runner 停摆（约 3 小时 CI 排队）

- **经过**：部署迁移清理期间，lead-agent 误把 CI 用的 mac runner 当成旧的 deploy runner 一并下线。重新注册后又遇到 label 大小写不匹配（`macos` ≠ `macOS`），full-suite 作业无法调度，CI 队列积压约 3 小时。
- **修复**：#1237 更新 runner 标签解阻队列。
- **教训（流程，非追责）**：① 下线任何 runner 前**先核对 runner 身份**（用途/标签/最近作业），不凭名字近似判断；② runner label **大小写敏感**，注册后立即用一个 dummy 作业验证调度成功再收工。

### 事故 B — M3 部署 boot-crash（CI 绿但 reflow 重试暴露）

- **经过**：seed 内建升级路径在 entrypoint 重试下**非幂等**——`source_turn_id` 唯一约束在第二次 entrypoint 重试时冲突，导致启动崩溃。全新 DB 的 CI 是绿的，只有 reflow-retry 场景才暴露。
- **修复**：#1235 已合入（2026-07-08 02:27 UTC，seed built-in upgrade 对 source_turn_id 冲突幂等）。**修复已 land，但 stable 尚待带 #1235 重新部署跑通——这是本日主线 M3「代码完成但未部署」的原因（部署验证结转 07-08）。**
- **教训**：**改变持久化形态（persistence-shape）的变更需要 reflow 彩排，而非仅靠全新 DB 的 CI。** 幂等性必须在「重试 / 已存在数据」场景下验证。

### 事故 C — #1214 连带删除 entrypoint.prod.sh

- **经过**：#1214 移除部署资产时删掉了 `entrypoint.prod.sh`，但 `Dockerfile.prod` 仍 `COPY` 它，导致 Docker 构建失败。
- **修复**：#1234 恢复该文件。
- **教训**：删除跨仓库/跨文件被引用的资产前，grep 全部引用点（Dockerfile / 脚本 / CI）再删——与团队既有「删除前枚举全部 gate」原则一致。

### 诊断改进

- `deploy.sh` 现在在健康检查失败时**dump 容器日志**——上线排障不再盲。这是本轮迁移的正向副产品。

## §3 数据统计

### 按开发者（口径：能力交付，非 PR 数排名）

| 开发者 | feishu | 本日 PR | summary |
|---|---|---|---|
| allenwoods | 林懿伦（lead） | 13 | 编排线 T1-T4 + M2 + M3 全量 · 部署迁移全套（资产剥离/PTY/entrypoint 恢复/runner 解阻）· 会话过滤 · 资产本地化 · M3 spec |
| jjkysy | 姚升悦 | 1 | sw-home 单次晚扫 manifest 车道（#1224） |
| zyli-developer | 李震宇 | 1 | agent 成员显示名修复（#1216） |

> **注**：本日工作高度集中在 lead（13/15）。编排线是深度地基改造，context 集中在一人属合理；下一步 stable 打通后，socialware 验证与官网全流程可分散给团队并行（见 07-08 plan）。

### 效能观察

- **spec 先行的回报**：M3 走了「spec → codex SOUND → 实现（#1230）」，实现阶段顺滑。orchestration 4 份 + crgov + M3 共 6 份 spec 两日内写就并全部判 SOUND——地基/契约先行的一贯回报。
- **迁移的连带成本**：部署资产剥离（#1214）一次删 4,130 行，连带引出 entrypoint 恢复（#1234）与 runner 误下线（事故 A）。**大规模删除是高风险操作**——引用点枚举 + 身份核对本可避免两次返工。
- **CI 绿 ≠ 部署绿**：M3 boot-crash（事故 B）再次印证——**部署形态变更需要 reflow 彩排**，全新 DB 的 CI 覆盖不到重试/已存在数据路径。

## §4 profile 更新（据本日 review）

- **allenwoods**：强化「架构/地基/大改造 + 部署」标签；本日独力打通编排线三级里程碑 + 部署迁移。**新增注意点**：大规模删除操作需引用枚举 + runner 身份核对（事故 A/C 的流程红线）。
- **jjkysy**：sw-home 车道体现对 socialware boot 时序的把握（晚扫 vs 早期投机）。
- **zyli-developer**：agent 成员显示名——UI/成员呈现面。

---

本回顾面向全体开发者，仅含团队相关内容。团队向 HTML 版见 `review.html`。
