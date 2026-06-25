# 2026-06-24 周期分析（系统功能层面）

> @林懿伦 反馈"review 质量不行"，要求**按系统功能层面**分析昨天进度 → **按负责人完成情况** → **待处理事项**。这份替代之前按 PR 流水的 review。判定用四性质 DoD：能力是否**端到端真能用**，不只是"代码合了"。

---

## 一、按系统功能 / 产品能力的推进（这才是"进度"）

| # | 系统功能 / 产品能力 | 本周期推进 | 端到端状态（DoD 视角） |
|---|---|---|---|
| F-1 | **Headless agent 运行**（cc 不占 PTY 也能跑） | #931 真 SDK sidecar（Python `claude-agent-sdk` 子进程）替换 stub | ✅ **后端真通**（真 Claude turn 有证）；⚠️ 只有手动 E2E，CI 用 fake worker，无真-SDK 回归 |
| F-2 | **Agent 配置管理**（operator 配 agent） | #938 后端 facade + #943/#966 读写 cap-gate + #958 console 增查改删 UI | ⚠️ **部分可用**：cc/curl 能配；**echo 配不了**（卡 #918）；console **0 UI/路由测试**（回归无保护）；是通用 kv 编辑器、非每字段结构化表单 |
| F-3 | **Hello AI 页面生成 / json-render 渲染** | #956 落地（→#961 greened） | ⚠️ **能力实际是坏的**：后端 catalog 迁了 shadcn，**前端渲染器没迁** → 页面渲染空/坏。今天 zhaomato 修 |
| F-4 | **路由 / agent 回路正确性** | #98/#959 自环保护 + Bug A #939 静默 cast 丢失观测 | ✅ 真修 + 回归测试 |
| F-5 | **插件运行时去中心化**（LocalRuntime owner-gate） | #95 系列（facade + 迁 cc/codex/echo/feishu/advisor） | ✅ 核心通；**hello/protocol_api/world 未迁**（#99）；echo 迁移与 #918 设计冲突待决 |
| F-6 | **插件自有 resource:// 类型** | #922/#928 注册 + Bug B #937 重启重放 | ✅ 真修 + 回归 |
| F-7 | **测试/CI 基建健康** | #92 sandbox 竞争 + #94 flake + **CI 闸 #962 + branch protection** + dev-together 大改 #965 + delete_path 鉴权 #966 | ✅ **大幅改善**（从"本地把关"到"机器闸"）；遗留 ExternalMirror Grill-5 测试串扰 flake（#968 暴露） |
| F-8 | **人肉可用性**（团队日用 = 目标①的度量） | zyli 全流程跑通 + #949 logout + #950 API-key UI | ⚠️ **核心流程通，但 Feishu 入口仍缺**：F9（chat→session 绑定 UI 无）、F12（@ 不解析成 agent mention）→ 还不能完全日用 |
| F-9 | **codex-remote** | #945 恢复 roundtrip | ⚠️ 修了，建议补 live 抽查 |
| F-10 | **外部适配器 / 邮件入站** | 无推进（#88 阻塞于 #82） | ⛔ 未动 |
| F-11 | **部署/基建（out-of-scope）** | #941 CF 成本调研 + #942 全容器化 + #940 LOGO + #952 protocol/sidecar 计划 | docs/研究；决策待你；**#942 scope 存疑**（disposable stack 本周已停用） |

**一句话进度**：基建/正确性/去中心化这几条**真推进了**（F-4/5/6/7）；但**产品能力**（F-2 agent 配置、F-3 hello 渲染、F-8 日用）都还**卡在"做了但端到端不完整"**——这正是今天的重点。

---

## 二、按负责人的完成情况

| 负责人 | 交付 | 完成情况 |
|---|---|---|
| **gaga (gagameow)** | #931 cc-headless / #938 agent-config 后端 / #945 codex-remote / #952 计划 | #931 ✅真完成 · #938 ✅(泄漏缺陷由 lead 修#966) · #945 ⚠️建议 live 抽查 · #952 ✅docs。**3 完成 + 1 待抽查。** |
| **fatnine (戴明)** | #958 agent-console / #918 echo→Entity.Agent | #958 ✅已合并（UI 测试延期给 gaga）· #918 ⛔OPEN、落后 main 37、与 #957 冲突需 rebase+决策。**1 完成 + 1 待 rebase。** |
| **zhaomato (张宁)** | #956 hello AI 页面生成 | ⚠️ 提交时全红（6 个），lead 修绿并合（#961）；**前端渲染器脱节未修** → 今天的任务。**返工。** |
| **zyli (zylideveloper)** | #944 人肉验证 / #949 logout / #950 API-key UI / #953 F14 文档 | 全部 ✅；人肉跑暴露 F9/F12 产品缺口（新工作）。**4 完成 + 暴露 2 缺口。** |
| **lead / Claude（allen 身份）** | Bug A#939 / Bug B#937 / #943 / #947 / #92#948 / #94#951 / #95(954/955/957/960) / #98#959 / resource#922#928 / #925 + 今晚 CI#962 / skill#965 / fix#966 / docs#967 / #958-close#968 | 全部 ✅（合并时本地或 CI 把关）。**净：基建+正确性轴几乎全清。** |
| **ruihua (chenruihua)** | （昨天无 PR；今天起接 dev-together 模版） | 新加入 track。 |

---

## 三、待处理事项（含今天分派）

**今天分派（你定的新方向）：**
1. **zhaomato** — F-3：json-render 组件对齐后端 shadcn catalog + 切换 style 验证 + 稳定 hello 整体结构（官网搁置）。
2. **lead/我** — F-5+F-1+F-2 后端：LocalRuntime + agent 后端（sidecar + api）合并成一个完整任务；**等 gaga 的现状分析 handoff**。
3. **zyli** — F-8：产品剩余缺口（F9 Feishu chat→session 绑定 UI、F12 @ 解析）完成实现。
4. **gaga** — F-2：agent config 面板实现；并先给 #2 出一份后端现状 handoff。
5. **ruihua** — F-7：更新 dev-together 的 review + plan 模版（提升分析/规划质量）。

**未分派/待决：**
- echo #918 rebase + **LocalRuntime 是否加带-behaviors 的 spawn arity**（与 #99 共用，建议加）— 谁做取决于 #2 是否吸收。
- agent-console **UI LiveViewTest 框架**（#958 欠的回归保护）— gaga follow-up。
- **ExternalMirror Grill-5 测试串扰 flake** 修复（test-isolation 类，#968 暴露）。
- #945 codex-remote **live 抽查**。
- **#96**（Protocol API 命名/拆分）/ **#97**（sidecar 生命周期）— 你分析拍板。
- **#88** 邮件入站 — 阻塞于 #82。
- **#942** 全容器化 stack — 确认还用不用（否则标投机性）。
- **#55** 文档强制测试 — 已完成（enforcement 早在 main）。

**决策已定**：`enforce_admins` 保持 false（lead 保留 override）。
