# Design Brief: #1372 飞轮 IA/视觉 → world/hello LiveView 面

> **目标**：将 #1372 飞轮原型的 IA 结构和视觉方向映射到真实 world/hello 面，作为 zhaomato hello live E2E + hello↔kanban 融合的设计参照。
> **受众**：zhaomato（hello 产品面开发）
> **约束**：本文件夹是设计参照，不替代研发的技术方案
> **PR**：#1378

---

## 1. IA 映射表：flywheel → 真实面

> **术语约定**：Gallery 货架展示的是 **socialware 产品**（用户用 world+hello 构建的产物，可发布形态是 `Socialware.Definition`，config-only、不含代码），不是 plugin（plugin 是代码扩展，提供 mechanism）。见 GLOSSARY.md #156–#158。

| Flywheel 页面 | 作用 | 对应真实面 | 当前状态 |
|--------------|------|-----------|---------|
| **gallery.html** | socialware 产品货架（搜索/筛选/瀑布流卡片） | 🔴 **不存在。** WorldLive 的 `/plugins` 页显示的是已安装的**代码插件**，和 gallery 展示的 socialware 产品是两回事 | 真正的 gallery 浏览/搜索/详情 API 待建（W-G1）；前端 UI 待建 |
| **product-detail.html** | 产品详情（manifest + Try + Fork CTA） | 🔴 **不存在。** Hello external feed 是 AI 生成页面的查看器，不带 socialware metadata | 无产品详情页；Hello external feed 渲染 @json-render 内容，不含 manifest 展示 |
| **world-step.html** | 构建/Fork 中转（发布表单占位） | 🟡 Fork 后端已落地（`session.fork_config`），CR 管线已落地——**缺前端入口和表单** | W-G2（发布入口+表单）、W-G3（Gallery→Fork 触发）待建 |
| **publish-landing.html** | 发布确认 + 卡片进入货架（闭环反馈） | 🔴 **不存在。** | H-G4 待建 |
| **gallery → product → world → publish → gallery 闭环** | 5 步飞轮（多租户 marketplace：Builder × Seller） | hello 自举链（单次开发任务流：用户 × Agent） | hello live E2E 待建（zhaomato 当前任务） |

### 🔴 关键空缺：真正的 Gallery 还没有

flywheel 原型里的 gallery 是一个 **socialware marketplace**（浏览 → 试用 → Fork → 上架），而真实 WorldLive 里没有任何一个页面对应它：

- WorldLive `/plugins` = 已安装的代码插件列表（不是 marketplace）
- 真正的 gallery 需要 W-G1（目录 API）+ 前端 UI（浏览/搜索/筛选/详情），**目前全部待建**

这个空缺意味着：flywheel 的 IA 映射到真实面时，**多数对应行是 "不存在" 而非 "改这个页面"**。这不是坏事——它恰恰说明了设计参考的价值：告诉 zhaomato 在构建 hello live E2E 时，哪些 flywheel 页面结构应该被带上。

### 关键映射

> 以下映射的是**结构模式**（浏览→查看→触发→执行→闭环），不是页面功能的字面对应。Flywheel 是产品 marketplace，自举链是工程开发环——结构相似，用途不同。

```
Flywheel 飞轮                    Hello 自举链
──────────────────────────────────────────────────
gallery 浏览产品              →  kanban 看板（任务可见）
product-detail 查看+T/F       →  hello 入口页（greeter + 功能说明）
Try 试用                      →  进 hello session 真交互
Fork 改造                     →  kanban 派活给 agent
Publish 发布                  →  agent 产 PR → CI merge
publish-landing 确认          →  看板流转 → 三面绿 ✓
```

---

## 2. 视觉方向：从 flywheel 提取可移植模式

### 可移植到 shadcn 体系的模式

| Flywheel 模式 | 描述 | shadcn 对应 |
|--------------|------|------------|
| **卡片瀑布流** | CSS columns，`270px` 最小列宽，hover 上浮 3px | shadcn Card + Grid（`repeat(auto-fill, minmax(270px, 1fr))`） |
| **产品身份 glyph** | 每个产品一个中文字形 + 颜色，圆角头像 | 已有的 `avatar.ex`（procedural conic gradient）可扩展 |
| **双语文案** | `中文 · English` 并存，EN 用 Space Mono 小写 | Viewer SPA 已支持；hello @json-render 的 Text/Heading 组件可用 |
| **闭环反馈** | "刚上架 · new" badge，卡片动画滑入 | shadcn Badge + CSS animation；CR 状态变更时触发 |
| **搜索/筛选** | 实时过滤，中文 + 英文匹配，分类 chip | shadcn Input + Tabs/Badge 组合 |
| **"占位页"策略** | 未实现功能用虚线框 + 待办列表标明，不伪造 | 在 hello kanban 连接处用 `EmptyState` 原语明确标注 "松耦合，非最终挂载" |
| **Manifest 条纹网格** | 键值对网格展示 product metadata | shadcn Table 或 Description List 原语 |

### 不可移植的（保持各自风格）

- Flywheel 的暗色玻璃 + 渐变背景 → 不进 world
- World 的 3 面板 IM 布局 → 不进 homesite
- 两者共用：cobalt `#0B5CFF` 主色、Inter/Space Mono 字体、`--radius` 圆角

---

## 3. Hello↔Kanban 连接点的设计方向

### Flywheel 的 "试用 → Fork → 发布" 流

```
gallery 看中一个产品
  → product-detail 查看详情
    → Try 试用（进 world 试玩）
    → Fork（一键复制到自己 workspace）
      → world-step 改造它
        → publish-landing 发布确认
          → 回到 gallery（新产品上架 ✨）
```

### 对应到自举链的 "hello 派活 → kanban → agent 产 PR"

```
hello 入口页（greeter 欢迎 + 说明功能）
  → 用户输入需求（真 prompt）
    → hello 生成 @json-render 页面（live 渲染）
      → concierge 确认需求
        → 派活到 kanban（"hello↔kanban 连接点"）
          → kanban 看板显示任务
            → agent 接任务、产 PR
              → PR merge → 看板流转 ✓
```

### 设计提示

1. **hello 入口页**：参照 flywheel `product-detail.html` 的结构——产品名、描述、功能说明、CTA（"开始使用" / "派个任务"）
2. **hello→kanban 连接点**：参照 flywheel 的 "Fork" 按钮——一个明确的 CTA，触发后看板创建任务。标注 "松耦合，非最终挂载"
3. **kanban 任务卡**：参照 flywheel 产品卡片的 glyph/color 身份系统，给不同任务类型分配视觉标识
4. **闭环反馈**：任务完成后 kanban 看板上的状态流转，参照 flywheel 的 "刚上架 · new" → "live" 状态变化

---

## 4. 不做的事

- ❌ 不把 homesite 暗色玻璃风格写进 world 的 Tailwind/shadcn 体系
- ❌ 不设计 Gallery API 的后端实现（那是 W-G1~G6，后端工程任务）
- ❌ 不替代 hello @json-render catalog（36 组件已定义，本次不增不减）
- ❌ 不新建 LiveView 页面或路由

---

## 5. 与 page-flow.md 的关系

本文件夹是 **设计参考层**——不在 mainsite 的导航流中，但为真实 world/hello 面的开发提供 IA/视觉方向。交付后更新 `doc/page-flow.md` 的设计参考节。
