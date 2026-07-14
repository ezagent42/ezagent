# Design Brief: DealScout 投融资撮合 demo

> **目标**：投融资撮合 socialware 的静态原型——用户描述需求，AI 匹配信号，双方牵线。
> **受众**：研发——理解撮合类 socialware 的产品形态
> **约束**：本文件夹是设计参照，不替代研发的技术方案
> **PR**：#1378

---

## 1. 页面与流转

| 页面 | 作用 | 状态 |
|------|------|------|
| **index.html** | 撮合入口：描述需求 → AI 匹配 → 查看结果 → 牵线 | 🆕 新建 |
| `../flywheel/gallery.html` | Gallery 货架入口 | 🟡 已存在 |

### 流转

```
mainsite.html / flywheel/gallery.html
  → dealscout/index.html
    ① 描述需求（我正在找…）
    ② AI 生成匹配（mock 匹配池）
    ③ 查看匹配结果卡片（匹配度 + 简介）
    ④ 选中牵线 → 进入 workspace
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
