# dev-together 团队回顾 — 2026-06-24 周期

> 团队同步版。昨日提交的 PR 列表 → 暴露的问题分析 → 改进建议。（今日安排见 `2026-06-25/plan.md`。）

## 一、昨日提交的 PR

| PR | 内容 | 负责人 |
|---|---|---|
| #931 | cc-headless：真实 SDK sidecar 运行时（替换 stub） | gaga |
| #938 | agent-config：后端 facade + 增删改查契约 | gaga |
| #945 | codex-remote：恢复 session roundtrip | gaga |
| #952 | protocol-api + sidecar 生命周期计划（文档） | gaga |
| #958 | agent console：world agent 增/查/改/删 UI | fatnine |
| #918 | echo→Entity.Agent + soul 进 create（**仍 OPEN**） | fatnine |
| #956 | hello：单轮 AI 页面生成 | zhaomato |
| #944 | 全流程人肉验证 + rebase-batch 验证 | zyli |
| #949 | world：登出/切换账号入口 | zyli |
| #950 | world：录入 agent API key 的 UI | zyli |
| #953 | F14 文档归因修正 | zyli |
| #937 | Bug B：resolver 重启重放插件 resource 类型 | lead |
| #939 | Bug A：投递前静默 cast 丢失改为可观测 | lead |
| #943 | agent-config 读权限与写对称（cap-gate） | lead |
| #947 | workspace-locality gate（分布式预备） | lead |
| #948 | 修复 umbrella sandbox owner-exit 测试竞争（#92） | lead |
| #951 | 修复 MentionFailedTest 串扰 flake（#94） | lead |
| #954/#955/#957/#960 | LocalRuntime facade + 迁 cc/codex/echo/feishu/advisor + 文档（#95） | lead |
| #959 | 路由自环保护（#98 / F14） | lead |
| #922/#928 | 插件自有 resource:// 类型注册 PR-1/PR-2 | lead |
| #925 | EZAGENT_NO_DISTRIBUTION dev 基建开关 | lead |
| #940/#941/#942 | LOGO / CF 部署成本调研 / 全容器化 Mac stack | allenwoods（out-of-scope） |
| #962/#965/#966/#967/#968 | CI 闸 + dev-together 流程升级 + delete_path 加固 + 审计 + #958 合入 | allenwoods（周期收尾） |

## 二、昨日暴露的问题（分析）

1. **多个 PR 返还时本身不绿。** hello（#956）提交时自身 6 处红（编译告警 + 自带测试与自身 shadcn 迁移不一致 + 架构基线超标）；agent console（#958）合并后才发现一个配置路由 404。**根因**：返还前没有强制"自身绿 + rebase 到当前 main"的机器校验，全靠 lead 在合并时本地把关 —— 又晚又会漏。
2. **跨层迁移只做了一半。** hello 后端 catalog 迁到 shadcn 组件，但前端渲染器（`catalog.ts`/`registry.tsx`）没跟着迁 → 生成的页面渲染空/坏。**根因**：迁移任务的"完成"没有从契约源头枚举出"消费端 parity"，也没要求端到端的产品级验证（只验了单层单测）。
3. **UI 功能缺自动化测试。** agent console 的测试都在后端 dispatch 层，没有一个走真实 LiveView/路由 —— 所以路由 404 漏到了手动验证才发现。**根因**：UI 功能的"可演示产物"只用了截图（一次性），没有穿真实界面的回归测试。
4. **权限校验顺序漏洞。** agent-config 的 `delete_path` 先读 body 再鉴权，无权限调用者可借错误码探测字段是否存在（存在性泄漏）。**根因**：读-改-写在 facade 层，鉴权没前置到任何存在性读之前。（已加固。）
5. **测试隔离 flake。** ExternalMirror Grill-5 不变量测试被一个动态命名的测试 fixture 串扰（泄漏进全局模块扫描），非确定性失败。**根因**：异步测试间的模块/状态隔离不彻底（与 #92/#94 同类）。
6. **out-of-scope 工作未预算。** 一个名义上聚焦 4 条人类开发 track 的周期，额外吸收了若干基建/调研 PR（部署成本、全容器化等）。单看合理，合起来是范围漂移，让周期真实工作量不可见。

## 三、改进建议

1. **机器化的返还闸（已落地）**：新增 CI（`precommit + check_invariants`）+ main 分支保护 —— PR 必须 CI 绿 + rebase 到当前 main 才能合，"自身绿"不再是口头声明。
2. **完成的定义（DoD）四性质**：目标派生（迁移类从源头枚举 parity）/ 可验证且自带证明 / 在用户面验证（UI 用 LiveViewTest 或浏览器驱动，截图只是辅助）/ 闭集（可延期某条、不可删）。
3. **返还前先 rebase 并自测绿**；跨层/迁移任务必须带 parity 清单 + 端到端产品证明，禁止只验单层。
4. **延期由 lead 裁定**，开发不自宣"可合并"。
5. **回顾走系统功能层面 + 按人完成 + 待办**（模版化，本周期 ruihua 负责）。
6. **out-of-scope 工作先在 plan 的 off-plan 段声明预算**，让周期真实工作量可见。
7. **补测试隔离**：把动态 fixture 模块从全局不变量扫描里隔离（ExternalMirror Grill-5）。
