# 扩展旅程：从 Beta → 企业构建 Demo 网站（与 PORTABILITY.md 关联）

> 2026-07-23 · ruihua（designer）
> 前置：Beta 核心闭环（G4+G5）验证通过
> 关联：`docs/rh/ciia-demo/PORTABILITY.md`

---

## §1 从 beta 到「企业有产出」

```
beta 终点                       扩展起点                         扩展终点
   │                              │                                │
   ▼                              ▼                                ▼
agent 能回复  ──────→  企业导入真实数据  ──────→  构建 demo 网站
(G4+G5 交付)          (需 G8 KB 导入 UI)       (类似 CIIA demo)
```

Beta 只验证「配 key → agent 回复」。但企业的真实需求是：**用 ezagent 做出能对外展示的东西**（如产品 demo 展厅）——这正是 CIIA demo 展示的能力。

---

## §2 与 PORTABILITY.md 的对应关系

PORTABILITY.md 把 demo 架构分三层：

```
┌─ PORTABILITY.md §2.2 ────────────────────────────┐
│  内容替换层（企业自助做）                            │
│  · 品牌名/Logo/产品数据/会员名录/关于我们            │
│  · → 需 G8 KB 导入 UI + demo 构建工具              │
│                                                    │
├─ PORTABILITY.md §2.1 ────────────────────────────┤
│  平台层（ezagent 通用，不改）                        │
│  · Session 引擎 / Hello Builder / Bento 设计系统    │
│  · 搜索匹配引擎 / View-switching / Toast/Modal      │
│  · → beta G4+G5 就绪后，此层已可用                  │
│                                                    │
├─ PORTABILITY.md §2.4 ────────────────────────────┤
│  可新增的 socialware（企业可选）                     │
│  · 活动报名 / 项目申报 / 人才招聘 / 在线课程 / 融资   │
│  · → 属于「企业自己决定加不加」                     │
└────────────────────────────────────────────────────┘
```

**关键结论：** beta 把平台层（§2.1）拉到可用状态；企业要走到「有产出」，需要 G8（KB 导入）把 §2.2 的内容替换从「开发者手动改 HTML」变成「企业用户自助填数据」；demo 构建工具把 PORTABILITY.md 的 6 步操作指南自动化。

---

## §3 扩展旅程角色泳道

| Step | 企业 User | ezagent 平台 | 对应 Gap |
|:--|:--|:--|:--|
| X.1 | **导入真实数据**（产品信息、会员名录、企业介绍文本） | 提供 KB 导入界面：上传文件 / 粘贴文本 / URL 抓取 | G8（KB 导入 UI，post-beta P2） |
| X.2 | **数据就绪后试玩** → 搜索产品、发起对话 | Agent 基于真实数据回复（而非 mock 数据） | 同 G8，数据源从 mock → 真实 |
| X.3 | **构建 demo 网站**：选择 socialware 模板 → 填入内容 → 生成公开页面 | 平台提供 demo 构建工具 / 模板选择 / 一键发布 | 需新建（不在 G1-G10 内） |
| X.4 | **对外展示** → 客户访问 demo 页面 → 搜索产品 → 发起 Session | 同 CIIA demo 的 openSessionView + matchProducts 链路 | 无 gap（平台层已就绪） |

---

## §4 与 beta 的依赖链

```
G4 (cap-signing)
  └→ G5 (错误机制)
       └→ G8 (KB 导入 UI)  ← 企业导入真实数据的前提
            └→ Demo 构建工具  ← 企业自助出 demo 的前提
```

每一步的触发条件按产品计划 §4/§5 的约定：

- **G8 启用条件：** beta 闭环验证通过 + 真实企业用户有导入数据的需求 + lead 将 G8 纳入周目标
- **Demo 构建工具：** 超出 G1-G10 范围，需单独产品化。可以从 PORTABILITY.md 的 6 步操作指南（§3 操作步骤）出发，设计自动化工具

---

## §5 PORTABILITY.md 中「写死不变」的部分 = 扩展旅程的平台基础

PORTABILITY.md §5（Do not touch）列出的框架层代码——Session 创建/投递、`matchProducts()` 搜索、Hello Builder CSS/JS、Bento 设计 token、View-switching 架构——**在 beta G4+G5 就绪后全部可用**。这意味着：

- 企业用户不需要理解这些框架代码
- 他们只需要替换 §2.2 的内容层（数据/品牌/文案）
- 替换的方式从「开发者手动改 HTML」→「通过 ezagent UI 填入数据」是扩展阶段的核心工作
