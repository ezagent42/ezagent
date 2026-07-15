# Design Brief: Recruit → Publish 发布流程原型

> **目标**：补齐 recruit 页 "发布你的 agent" 按钮对应的 Builder 发布链路，使 flywheel 的 Builder 弧完整。
> **受众**：研发（zhaomato 等）——理解 Builder 发布流的设计参照
> **约束**：本文件夹是设计参照，不替代研发的技术方案
> **PR**：#1378

---

## 1. 页面与流转

| 页面 | 作用 | 状态 |
|------|------|------|
| **publish-entry.html** | Builder 入口：选 agent → 写说明 + 领域标签 → 提交审核。左侧 2 步编辑，右侧实时 Gallery 卡片预览 | 🆕 新建 |
| `../flywheel/gallery.html` | 审核通过后 agent 出现在货架 | 🟡 已存在 |

### 流转

```
recruit/index.html "发布你的 agent →"
  → recruit-publish-flow/publish-entry.html    [🆕 Builder 入口]
    ① 选 agent（搜索 + 分类筛选，从 workspace 列表选）
    ② 写说明 + 领域标签（标题/简介/封面 + 预设标签/自定义）
    ③ 提交审核
      ⬇
    审核中（占位，3s 模拟）
      ⬇ 审核通过
    ../flywheel/gallery.html  ← agent 上架 ✨
```

### UX 顺序说明

Agent-first：用户意图是 "把这个 agent 发上去"，不是 "在某个领域下找能发的 agent"。选完 agent 后标题自动填入，减少重复输入。2 步完成——选 agent → 写说明 + 打标签（合并步骤，减少页面跳转）。

## 2. publish-entry.html 设计

### 页面结构（2 步，左侧编辑 + 右侧实时预览）

**Step 1 — 选 agent**：搜索框 + 分类筛选 chip（全部/法务/招聘/客服/增长/研发/其他），展示 workspace 中所有 agent 列表（glyph + 名称 + 角色）。选中高亮，名称自动带入 step 2。

**Step 2 — 写说明 + 领域标签**：标题（预填 agent 名称，可覆盖）+ 简介 + 封面图上传（mock）+ 领域标签（6 预设 + 其他→文本框）。

**提交 → 审核**：提交后页面内显示 "审核中" 虚线框 → 3 秒模拟通过 → "审核通过" 确认 + 去 Gallery 链接。

### 视觉方向

- Ezagent Design System CDN（`styles.css`）：cobalt `#0B5CFF` 交互色，De Stijl 三原色，22px 圆角卡片，6 层柔影
- 步骤指示器：毛玻璃 pill 容器 + 圆点（Ant-style），蓝色当前/绿色完成/灰色待完成
- FadeUpBlur 页面切换动画（500ms）
- 双语文案：`中文 · English` 模式
- 按钮 hover lift(-1px) + active scale(.98)，focus 3px cobalt ring

## 3. 与已有页面的关系

| 已有页面 | 本次是否改动 | 说明 |
|---------|------------|------|
| `recruit/index.html` | 是——改链接 | `mainsite.html#intro` → `../recruit-publish-flow/publish-entry.html` |
| `mainsite.html` | 是——加链接 | 加入 Builder 发布入口 |
| `flywheel/gallery.html` | 否 | 发布后落点 |
| `flywheel/world-step.html` | 否 | Builder 发布流不经过（那是 Fork 流程） |
| `flywheel/publish-landing.html` | 否 | Builder 发布流不经过（那是 Fork 流程） |
| `doc/page-flow.md` | 是——更新流转 | 交付后更新 |

## 4. 不做的事

- ❌ 不实现真实后端（workspace agent 列表 API、发布 CR 流程、合规审核 W-G6）
- ❌ Builder 发布流不经过 world-step.html 和 publish-landing.html——那是 Fork 流程
- ❌ 不涉及 hello/kanban 自举链——这是 flywheel 产品飞轮的 Builder 弧
