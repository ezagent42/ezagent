# 日报 · ruihua · 2026-07-28

**分支 / PR:** `mfu-demo-tree` → [draft PR #1586](https://github.com/ezagent42/ezagent/pull/1586)（reused） · base `main`

## 今天做了什么 / 产出

- `mfu-demo/doc/platform-concept-model.md` — 建立 MFU 平台概念模型，并补充“订单拆解 → 猎人匹配 → 协作交付 → 形成组织”的角色和关系；请 lead 审核这套统一语言。
- `mfu-demo/doc/infographics/MFU-v0.15-机制信息图.html` — 更新后的 pitch deck，以新人才培养、新组织形式、新市场机制三段展开；具体功能页使用可点击放大的新版 demo 局部截图。
- `mfu-demo/MFU-v0.15-可试玩原型.html` — 从 v0.14 可玩经营游戏重建的 v0.15，接入匹配步骤、任务路由、外包、订单聊天室、初验、评价、上下游邀请和孵化器视角。
- `mfu-demo/role-pages/` — 九个角色操作页，作为正式 demo 中各工作台的独立设计基准。
- [draft PR #1586](https://github.com/ezagent42/ezagent/pull/1586) — 继续复用现有 PR，不翻转、不自行合并。

![订单拆解工作台](../../../../mfu-demo/doc/infographics/assets/demo-v0.15-crops/feature-decompose.png)

![猎人协作工作台](../../../../mfu-demo/doc/infographics/assets/demo-v0.15-crops/feature-hunter-workbench.png)

## 设计决策

- 经验、成长树、声望/信用和认证继续保持独立，不再用一个成长概念承担全部作用。
- 平台匹配的是步骤与猎人；猎人可在自己的步骤内再次使用“本人 / AI / 外包猎人”的小循环。
- 同单协作者身份互相可见，并共享订单聊天室；长期组织由人类猎人主动邀请形成。
- v0.15 不再使用流程演示器方向，改为在 v0.14 可玩经营循环上自然接入新机制。
- 信息图只在具体功能页展示局部产品截图，概念和总览页不再机械附图。

## 下一步计划（必填）

- 根据 lead 与团队试玩反馈，调整 v0.15 各入口的顺序、提示和操作密度。
- 确认步骤拓扑编辑器正式版的拖动与改线交互。
- 决定过期的旧整页 demo 截图是否归档或删除。

## 待办 / 阻塞

- `mix precommit` 受本地 Phoenix 依赖未安装阻塞；本轮 HTML 脚本、截图引用和差异检查均已单独验证。
- draft PR 由 lead 翻转并合并，ruihua 不自行 merge。

## 关联

- handoff: off-plan 设计工作
