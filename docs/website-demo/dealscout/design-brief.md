# Design Brief: DealScout 投融资撮合 demo

> **目标**：投融资撮合 socialware 的静态原型——用户描述需求，AI 匹配信号，双方牵线。
> **受众**：研发——理解撮合类 socialware 的产品形态
> **约束**：本文件夹是设计参照，不替代研发的技术方案
> **PR**：#1388

---

## 0. 实现路径（重要）

DealScout 是一个 **组合 socialware**（composite socialware）：
- **hello** 负责页面渲染——通过 @json-render spec 动态生成 UI（36 组件 catalog：Card / Grid / Heading / Text / Button / Badge / Input / …）
- **crawler plugin** 负责数据——爬取外部信号，dispatch `refresh_page` 触发 hello 重建页面
- 用户交互动作（牵线、接受/拒绝）→ 后端 dispatch action（参照 kanban 的 `dispatch 板动作` 模式）

**本文件夹的 HTML 原型是设计 spec**——告诉研发 hello 应该生成什么样的页面。原型组件均在 catalog 内，可直接映射为 @json-render spec。

参考：`docs/together/2026-07-06/handoffs/system-mechanism-feedback.md` — "dealscout v2 e2e 再证：crawl 完成 dispatch `refresh_page` → handler 真跑 → 页面重建"

---

## 1. 页面与流转

| 页面 | 作用 | 状态 |
|------|------|------|
| **index.html** | 撮合入口：描述需求 → AI 匹配 → 查看结果 → 牵线 · 保存搜索 | 🆕 新建 |
| `profile/index.html` | 个人名片：身份 + 行业标签 + 资源/需求 | 🔴 **不在 dealscout 内**——名片是平台级功能（`achievement-center.html` 的角色档案），dealscout 只读取 |
| `connection/request-sent.html` | 牵线请求已发送 + 等待对方确认 | 🆕 新建 |
| `connection/inbox.html` | 牵线收件箱：查看请求 + 接受/拒绝 | 🆕 新建 |
| `notification/saved.html` | 保存的搜索 + 新匹配通知 | 🆕 新建 |
| `../flywheel/gallery.html` | Gallery 货架入口 | 🟡 已存在 |

### 流转

```
mainsite.html / flywheel/gallery.html
  → dealscout/index.html
    ├── achievement-center.html           [名片：平台级角色档案，dealscout 读取]
    │
    ├── ① 描述需求 → ② AI 匹配 → ③ 查看结果
    │     ├── 选中牵线 → connection/request-sent.html  [等待对方确认]
    │     │     └── → connection/inbox.html              [对方视角：接受/拒绝]
    │     │           ├── 接受 → workspace
    │     │           └── 拒绝 → 通知发送方
    │     │
    │     └── 保存搜索 → notification/saved.html        [异步通知]
    │           └── 新匹配 → 回 dealscout/index.html
    │
    └── connection/inbox.html             [牵线收件箱：查看他人请求]
```

## 2. index.html 设计

### 页面结构（3 步）

1. **描述需求**：自由文本 + 类型选择（找钱 / 找项目 / 找联合创始人 / 找退出机会）
2. **匹配结果**：mock 匹配池返回 3-5 个匹配项，每项显示匹配度 + 简介 + 关键标签
3. **牵线确认**：选中后确认 → 双方进入 workspace

### 视觉方向

- Ezagent Design System CDN，匹配 recruit/flywheel 风格
- 匹配卡片：glyph + 匹配度百分比 + 一句话简介 + 标签
- "牵线"是主 CTA（cobalt 色），区别于 flywheel 的 "Fork"

## 3. 与已有页面的关系

| 已有页面 | 本次是否改动 | 说明 |
|---------|------------|------|
| `mainsite.html` | 是——加链接 | 加 DealScout 入口 |
| `flywheel/gallery-data.js` | 是——改 tryUrl | `dealscout-matching` 的 tryUrl 指向 `../dealscout/` |
| `flywheel/gallery.html` | 否 | |
| `doc/page-flow.md` | 是——更新 | 交付后更新 |

## 4. 不做的事

- ❌ 不实现真实匹配算法
- ❌ 不涉及 hello/kanban 自举链
