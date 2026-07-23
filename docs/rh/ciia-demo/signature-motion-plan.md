# Signature Motion · 方法与实施计划

> P0 动效：Agent 角色交接 + Session 创建

---

## 一、方法论调研

### 1.1 业界三种主流路径

| 路径 | 代表 | 做法 | 优势 | 风险 |
|:--|:--|:--|:--|:--|
| **Token-first** | Google Material Design | 先定义 motion token（duration/easing），所有动画从 token 派生 | 一致性强 | 个性不足——token 无法定义"感觉" |
| **Moments Map** | Apple HIG | 先绘制用户旅程的情绪曲线，在峰值放 signature animation，其余用通用过渡 | 情感精准 | 需要深入理解用户旅程 |
| **Brand-in-Motion** | Stripe / Linear | 先定义品牌的 motion personality，动画是人格的延伸 | 品牌辨识度最高 | 对品味要求高 |

**推荐路径**：Moments Map + Brand-in-Motion 混合。先定人格 → 再定峰值 → 最后定 token。Token 是收束点，不是起点。

### 1.2 关键概念

| 概念 | 来源 | 说明 |
|:--|:--|:--|
| **Anticipation** | Disney 12 Principles | 动作前有小幅预备——旧 avatar 先微亮（"我要交接了"），再缩小退出 |
| **Staging** | Disney 12 Principles | 一次只让用户关注一件事。交接时：旧退出 → 暂停 → 新进入，不做并行动画 |
| **Spatial Continuity** | Apple HIG | 元素从哪来、到哪去必须明确。头像从 sheet 位置飞到 overlay 位置，不凭空出现 |
| **Easing as personality** | Material Design | 缓出（deceleration）= 稳重可靠 vs 弹性（spring）= 活泼。**ezagent 应该偏稳重但有温度** |
| **Secondary action** | Disney 12 Principles | 主动作外的小动作。产品名片滑入后，标签逐个 pop-in（不是同时出现） |

### 1.3 ezagent 的 Motion Personality

| 维度 | 值 | 理由 |
|:--|:--|:--|
| **速度感** | 中速偏慢（300-600ms） | 太快=工具感，太慢=拖沓。中速传递"组织在认真做事" |
| **重量感** | 有重量（ease-out + subtle overshoot） | 组织不是轻飘飘的 chatbot——每一动作有分量 |
| **温度** | 暖（微弹性，非机械线性） | 组织是有人的，不是自动化流水线 |
| **精度** | 精确（时序不可漂移） | 不可靠的动画 = 不可靠的组织 |

---

## 二、两个 P0 Moment 的设计方向

### 2.1 Agent 角色交接（"组织内多角色在协作"）

**触发时机**：对话中 Agent 从一个角色切换到另一个（如"展厅顾问"→"匹配助手"）

**设计方向**：两个 avator 之间的一次"接力"。不是 A 消失→B 出现，而是有传递感。

```
┌─ Sheet header ────────────────────────┐
│                                        │
│  [旧Avatar]  ──✦──  [新Avatar]         │
│   缩小淡出    交接点    滑入放大         │
│                                        │
│  旧Agent发出交接语："让我请匹配助手"      │
│                   新Agent："正在检索…"   │
└────────────────────────────────────────┘
```

**时间线**：
```
0ms     旧 Agent 发出交接语句
400ms   旧 avatar 微亮（anticipation），新 avatar 从右侧预位（opacity 0, translateX 20px）
500ms   旧 avatar 缩小（scale 1→0.8）+ 淡出。同时一个光点从旧飞向新位置
700ms   光点到达新 avatar 位置 → 新 avatar 放大（scale 0.8→1）+ 淡入
800ms   新 avatar 到位，开始打字
```

**传递什么**：组织内部有分工——"我把你交给更合适的人"。光点是"信息已传递"的视觉隐喻。

### 2.2 Session 创建（"组织为你连接了真实企业"）

**触发时机**：用户点击"联系企业" → Session 创建

**设计方向**：空间从"对话"展开为"对接"。不是跳转，是扩张。

```
┌─ Sheet（收起的背景）──────────────────┐
│                                       │
│     [你的头像]  ←─✦─→  [企业头像]       │
│          双方靠近     连接建立           │
│                                       │
│  ┌─────────────────────────────────┐  │
│  │  Session 空间（径向展开覆盖全屏）  │  │
│  │  ┌──────┐ ┌───────────────────┐ │  │
│  │  │产品名片│ │    对话区          │ │  │
│  │  │(左入) │ │   (下升)          │ │  │
│  │  └──────┘ └───────────────────┘ │  │
│  └─────────────────────────────────┘  │
└───────────────────────────────────────┘
```

**时间线**：
```
0ms     用户点"联系企业"
150ms   Sheet 开始下沉（translateY 0→20%）——"对话退后了"
200ms   双方头像从两侧向屏幕中心靠近
400ms   头像相遇 → 连接光效（圆环从中心扩散）
550ms   Session 空间从中心径向展开（clip-path circle(0→100%)）
650ms   产品名片从左侧滑入（translateX + fade）
750ms   对话框从下方升起（translateY + fade）
900ms   系统消息："信息协会已为您连接 [企业名] 的对接人"
1100ms  企业方 greeting 出现
```

**传递什么**：组织在行动——"我正在为你建立连接"。三个阶段：提出需求（Sheet 退后）→ 建立连接（头像相遇+光效）→ 就绪（空间展开，名片+对话到位）。

---

## 三、实施计划

### Step 1 — 确认 Motion Personality + 两个 Moment 的设计方向（本次讨论）

确认后会得到：一套 motion token（duration/easing/spring）+ 两个 moment 的完整 storyboard。

### Step 2 — 制作独立原型

| 原型 | 文件 | 内容 |
|:--|:--|:--|
| Agent 角色交接 | `docs/rh/ciia-demo/visual-tests/sig-agent-handoff.html` | 独立可播放的交接动画，可调参数 |
| Session 创建 | `docs/rh/ciia-demo/visual-tests/sig-session-create.html` | 独立可播放的创建动画，可调参数 |

每个原型：
- 可单独打开，循环播放
- 有按钮/滚轮控制播放、暂停、调速
- 参数（duration/delay/easing）可调

### Step 3 — 审查 + 记录

- 逐个 review → 调参数 → 定稿
- 记录最终的 motion spec（token + 关键帧数值）
- 补充到 signature-interactions.md

---

## 四、待确认

1. **Motion Personality**：中速/有重量/暖/精确——这四个维度是否符合你心里的 ezagent？
2. **两个 moment 的设计方向**：Agent 交接的"接力"隐喻、Session 创建的"空间扩张"隐喻——方向对吗？
3. **原型粒度**：需要和现有 carousel-socialware.html 集成在一起，还是先做独立的可播放动画文件？
