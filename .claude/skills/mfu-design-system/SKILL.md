---
name: mfu-design-system
description: Apply the MFU (My First Unicorn) parchment-and-paper visual system to playable HTML demos, capability maps, infographics, stakeholder explainers, and related UI. Use whenever creating or modifying MFU visual artifacts, especially the single-file prototype and school/incubator-facing mechanism diagrams.
---

# MFU Design System

> 提取自 `MFU-v0.13-可试玩原型.html` 的完整设计语言。
> 任何对 MFU demo 的 UI 改动必须遵循此文件中的规则。

## 工作流

1. 先读取目标 artifact 的真实内容与现有组件，不用占位文案。
2. 复用本文 token 与组件；新增样式必须能解释为 MFU 世界中的纸张、档案、印章、徽章或课程记录。
3. 信息图与 demo 使用同一套组件语言，使信息图成为产品界面的放大解释，而不是另一套宣传模板。
4. 优先用结构表达关系：学校绿、孵化器橙、协会蓝只标识真实角色；金色只表示当前重点或待达成目标。
5. 完成后在目标尺寸与窄屏各检查一次；确认无溢出、正文不小于 9.5px、键盘焦点可见，并遵守 `prefers-reduced-motion`。
6. 截图复核视觉层级和文字密度，至少删除一个不服务信息理解的装饰元素。

---

## 1. 色彩系统

```css
:root{
  --ink:       #5b4632;   /* 主文字色 · 暖棕 */
  --ink-dark:  #3d2e1f;   /* 深色文字 · 标题 */
  --cream:     #fdf6e0;   /* 卡片/面板底色 · 奶油 */
  --bg:        #e9d6a4;   /* 页面背景 · 羊皮纸 */
  --gold:      #f5b301;   /* 主强调色 · CTA/选中/高亮 */
  --school:    #3f9e4d;   /* 学校绿 */
  --school-bg: #e2f3e4;   /* 学校绿底色 */
  --incu:      #e07b1f;   /* 孵化器橙 */
  --incu-bg:   #fdeeda;   /* 孵化器橙底色 */
  --assoc:     #2f6fc4;   /* 协会蓝 */
  --assoc-bg:  #e3edfb;   /* 协会蓝底色 */
  --red:       #d94f3d;   /* 危险/警告 */
  --teal:      #1d9e75;   /* 成功/完成 */
  --purple:    #7a4fc9;   /* 特殊/稀有 */
}
```

**使用规则**：
- 所有面板/卡片/弹窗 → `background: var(--cream)`
- 页面背景 → `var(--bg)` + 45° 网格纹理
- 强调/选中/CTA → `var(--gold)`
- 成功/完成态 → `var(--teal)`
- 锁定/禁用/危险 → `var(--red)`
- 次要文字 → `#8a765a`（暖灰棕）
- 元数据/提示 → `#7a6c58`

---

## 2. 字体系统

**字体栈**：`"PingFang SC", "Microsoft YaHei", "Segoe UI", sans-serif`

**字重层级**：
- `800` — 重要标签、按钮文字
- `700` — 正文、列表项、面板标题
- `600` — 日志文字、辅助说明

**字号比例**：
| 用途 | 大小 |
|------|------|
| 微标签（tag） | 10.5px |
| 小字（辅助信息） | 9.5px |
| 正文/列表 | 11.5px |
| 按钮/标题 | 12.5px |
| 面板标题 | 13.5px |
| 弹窗标题 | 16px |
| Logo 大字 | 16px, letter-spacing: 2px |

**规则**：`letter-spacing` 在标题上用 1-2px，正文不需要。

---

## 3. 边框与深度（"纸叠"系统）

### 边框

| 元素类型 | 边框规格 |
|---------|---------|
| 面板（panel） | `3px solid var(--ink)` |
| 卡片（agent-card, order-card, shop-item） | `3px solid var(--ink)` |
| 嵌套元素（stat, bar） | `2px solid var(--ink)` |
| 空白态（hire-slot） | `3px dashed #a8977d` |
| 分隔线（列表/行间） | `2px dotted #e0d2ab` |
| 标签（tag） | `2px solid`（颜色跟随语义） |

### 阴影（关键特征——无模糊的"纸叠"阴影）

```css
/* 面板 */
box-shadow: 0 4px 0 rgba(91,70,50,.45);
/* 卡片 */
box-shadow: 0 3px 0 rgba(91,70,50,.35);
/* 小按钮 */
box-shadow: 0 2px 0 var(--ink);
/* 弹窗 */
box-shadow: 0 8px 0 rgba(0,0,0,.35);
/* 面板内发光 */
inset 0 0 0 2px #fff;
```

**规则**：阴影不用 blur。偏移量 = 边框厚度的 1-2 倍。颜色 = `rgba(91,70,50,.35-.45)`。

### 圆角

| 元素 | 值 |
|------|-----|
| 面板/弹窗 | 10-14px |
| 卡片 | 10px |
| 按钮/tag | 6-8px |
| 进度条 | 6px |
| 小方块（pip） | 3px |

---

## 4. 交互系统

### 按钮

```css
.btn{
  font-weight: 700; font-size: 12.5px; letter-spacing: 1px;
  border: 3px solid var(--ink); border-radius: 8px;
  background: #fff2cf; color: var(--ink-dark);
  box-shadow: 0 3px 0 var(--ink);
  cursor: pointer; transition: transform .05s;
}
.btn:active{
  transform: translateY(3px);
  box-shadow: 0 0 0 var(--ink);
}
.btn:hover{ filter: brightness(1.05); }
.btn:disabled{ opacity: .45; cursor: not-allowed; }
```

**变体**：
- `.btn-primary` — `background: var(--gold)` （主要操作）
- `.btn-green` — `background: #8fd694` （确认/接单）
- `.btn-small` — `font-size: 11.5px; padding: 3px 8px; box-shadow: 0 2px 0 var(--ink)`

### 选中态
- 当前选中 → `outline: 3px solid var(--gold)`
- 正确 → `outline: 3px solid var(--teal); background: #e5f6ef`
- 错误 → `outline: 3px solid var(--red); background: #fdeaea`

### 可点击提示
```css
cursor: pointer;
border-bottom: 2px dotted #b49a6d;  /* 虚线 = "可以点" */
```

---

## 5. 组件库

### 面板 `.panel`
```css
background: var(--cream); border: 3px solid var(--ink);
border-radius: 10px; padding: 11px;
box-shadow: 0 4px 0 rgba(91,70,50,.45), inset 0 0 0 2px #fff;
```

### 标签 `.tag`
```css
display: inline-block; font-size: 10.5px; font-weight: 700;
letter-spacing: .5px; border: 2px solid; border-radius: 6px;
padding: 1px 6px; vertical-align: middle;
```

### 进度条 `.bar`
```css
height: 14px; border: 2px solid var(--ink); border-radius: 6px;
background: #efe3c2; overflow: hidden; position: relative;
```
内部 `i` 用 solid fill，`span` 用绝对定位居中叠加文字。

### 弹窗 `.overlay` + `.modal`
```css
.overlay{ /* 遮罩 */
  position: fixed; inset: 0;
  background: rgba(61,46,31,.55); /* 暖色半透明 */
  z-index: 50; display: flex; align-items: center; justify-content: center;
}
.modal{ /* 弹窗本体 */
  background: var(--cream); border: 4px solid var(--ink);
  border-radius: 14px; padding: 16px;
  box-shadow: 0 8px 0 rgba(0,0,0,.35);
  animation: pop .18s ease-out; /* scale(.85)→scale(1) */
  max-height: 90vh; overflow-y: auto;
}
```

### 列表项 `.shop-item`
```css
display: flex; align-items: center; gap: 8px;
border: 2px solid var(--ink); border-radius: 8px;
background: #fff; padding: 5px 8px; margin-bottom: 6px;
font-size: 11.5px; font-weight: 700;
```

### Tab 导航 `.tabs`
```css
position: sticky; top: 6px; z-index: 30;
display: flex; gap: 6px;
background: var(--cream); border: 3px solid var(--ink);
border-radius: 10px; padding: 6px;
box-shadow: 0 4px 0 rgba(91,70,50,.45), inset 0 0 0 2px #fff;
```
Tab 按钮 `.tabbtn`：`box-shadow: 0 2px 0 var(--ink)`，选中态 `.on` = `background: var(--gold)`。

---

## 6. 动画

| 动画 | 实现 | 用途 |
|------|------|------|
| **Pop** | `scale(.85)→scale(1), .18s ease-out` | 弹窗出现 |
| **Press** | `translateY(2-3px)`, shadow 消失 | 按钮按下 |
| **Bob** | `translateY(0 ↔ -4px), .7s infinite` | Agent 工作中 |
| **Rise** | `translateY(0→-46px) + fade, 1.1s` | 资产+1 通知 |
| **Stamp** | `rotate(-8deg) scale(2.2→1), .3s` | 评级盖章 |
| **Progress** | `transition: width .4s` | 进度条填充 |

**规则**：所有动画 ≤ 1.1s，大部分 ≤ 0.4s。用 `ease-out` 缓出。支持 `prefers-reduced-motion`。

---

## 7. 布局

- **主网格**：`grid-template-columns: 1.22fr 1fr; gap: 10px`
- **响应式**：≤940px → 单列
- **面板间距**：`gap: 10px`
- **卡片网格**：`grid-template-columns: repeat(auto-fill, minmax(128px, 1fr)); gap: 9px`
- **双栏布局** `.duo`：`grid-template-columns: 1fr 1fr; gap: 10px`（≤900px 单列）
- **最大宽度**：`max-width: 1220px`

---

## 8. 语义色（角色/状态映射）

| 概念 | 颜色 | CSS 变量 |
|------|------|---------|
| 学校/教育/练习 | 绿 | `--school` |
| 孵化器/资金 | 橙 | `--incu` |
| 协会/认证/评审 | 蓝 | `--assoc` |
| 成功/完成 | 青 | `--teal` |
| 黄金/高级/CTA | 金 | `--gold` |
| 危险/警告 | 红 | `--red` |
| 稀有/特殊 | 紫 | `--purple` |
| 中性/通用 | 灰棕 | `#7a6c58` |

**给科技树节点的语义映射建议**：
- 已解锁 → `--teal`（成功）
- 可解锁/即将 → `--gold`（高级）
- 锁定 → `#a8977d`（中性灰棕）+ dashed border
- 资质类节点 → `--assoc`（蓝）
- 角色类节点 → `--purple`（紫）
- 平台专属 → `--incu`（橙）

---

## 9. 开发速查

```css
/* 面板 */
.panel{background:var(--cream);border:3px solid var(--ink);border-radius:10px;box-shadow:0 4px 0 rgba(91,70,50,.45),inset 0 0 0 2px #fff;padding:11px;}

/* 按钮 */
.btn{font-family:inherit;font-weight:700;font-size:12.5px;letter-spacing:1px;border:3px solid var(--ink);border-radius:8px;cursor:pointer;padding:6px 12px;background:#fff2cf;color:var(--ink-dark);box-shadow:0 3px 0 var(--ink);transition:transform .05s;}

/* 标签 */
.tag{display:inline-block;font-size:10.5px;font-weight:700;letter-spacing:.5px;border:2px solid;border-radius:6px;padding:1px 6px;}

/* 进度条 */
.bar{height:14px;border:2px solid var(--ink);border-radius:6px;background:#efe3c2;overflow:hidden;position:relative;}

/* 弹窗 */
.modal{background:var(--cream);border:4px solid var(--ink);border-radius:14px;box-shadow:0 8px 0 rgba(0,0,0,.35);padding:16px;animation:pop .18s ease-out;}

/* 阴影层级 */
/* 面板: 0 4px 0 rgba(91,70,50,.45) */
/* 卡片: 0 3px 0 rgba(91,70,50,.35) */
/* 小按钮: 0 2px 0 var(--ink) */
/* 弹窗: 0 8px 0 rgba(0,0,0,.35) */
```

---

## 10. 禁止事项

- ❌ 不使用模糊阴影（`blur`）——永远用 solid shadow
- ❌ 不使用无边框元素——所有容器至少 2px solid border
- ❌ 不使用纯黑（`#000`）——用 `var(--ink-dark)` 或 `var(--ink)`
- ❌ 不使用渐变按钮（`linear-gradient` 做背景可以，但不用于 CTA）
- ❌ 不使用圆角 > 14px
- ❌ 正文不 < 9.5px
- ❌ 不引入外部字体（用系统字体栈）
- ❌ 不引入 CSS 框架（纯手写）
