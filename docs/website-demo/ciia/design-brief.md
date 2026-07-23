# 信息协会产品展厅 Demo · 设计简报

## IA 映射

| Demo 元素 | 真实平台对应 | 实现方式 |
|-----------|-------------|---------|
| 展厅顾问（💬, 左侧聊天） | 前台接待 agent（Hello front-desk） | 预设对话脚本，关键词触发 |
| 产品匹配助手（🤖, 左侧聊天） | Hello 匹配 agent（builder/concierge） | 前端关键词匹配（mock） |
| **右侧渲染页面** | Hello Surface（json-render spec 树） | 自建 mini json-render 引擎 |
| 分类 Tab（🏛 全部 / 医疗健康 / …） | Hello Tabs 组件 | `switchCategory` 切换 spec 树 |
| 产品卡片 Grid | Hello Grid + Card 组件 | json-render Grid(cols:2-3) 渲染 |
| 💬 聊聊这个 按钮 | Hello 交互式卡片 `on.press.action:send` | 触发 `chatAboutProduct` → 聊天追问 |
| 快捷标签 | 平台导航/分类筛选 | 6 个场景入口按钮 |
| 详情弹窗 | 产品详情页 | Modal 弹窗 |
| 联系企业 | 平台咨询/对接功能 | 占位弹窗 |

## Hello 页面渲染模型（v2 新增）

```
用户输入需求（聊天）
  → 展厅顾问确认意图
  → 产品助手匹配产品
  → buildPageSpec(products, title, subtitle) 生成 json-render spec 树
  → renderPage(spec) 驱动 mini json-render 引擎渲染右侧页面
  → 页面自动更新（Grid 产品卡片 + Tabs 分类筛选）
```

### 自建 json-render 引擎支持的组件类型（Hello 36 组件子集）

| 组件 | 用途 |
|------|------|
| Stack | 垂直/水平弹性布局 |
| Grid | 响应式产品卡片网格（2-3 列） |
| Card | 产品卡片（图片+标题+描述+标签+操作按钮） |
| Heading | h1/h2/h3 标题 |
| Text | 段落文本（lead/default/muted 三种变体） |
| Badge | 彩色标签（6 种颜色对应产品类别） |
| Button | 操作按钮（primary/outline 两种变体，支持 onClick） |
| Tabs | 分类筛选 Tab（全部/医疗健康/数据智能/…），支持 onChange |
| Separator | 分割线 |
| Alert | 提示信息条（fallback 时的精选推荐提示） |

## 真实代码对应

| Demo 层 | Ezagent 实现层 |
|---------|---------------|
| `index.html` (本文件) | Hello socialware + 信息协会 Definition |
| 产品数据 (PRODUCTS 数组) | Recipe seed data / ConfigStore 产品记录 |
| `buildPageSpec()` | Hello Generator.build_spec → LLM 生成 json-render |
| `renderSpec()` mini 引擎 | `/assets/hello/main.js` HelloRenderer + catalog_render.mjs |
| `renderPage()` | TurnDriver.drive → Surface.put_version → ExternalFeed |
| `switchCategory()` Tab 切换 | Hello Tabs 组件 jr-tab-switch 事件 |
| `chatAboutProduct()` 交互卡片 | Hello `on.press.action: "send"` |
| 对话流 (handleQuery) | Socialware routing_rules + agent recipe |
| 快捷标签 (suggestions) | prompt_templates / legends |

## Gap 标注

- [ ] **无真实后端** — 纯前端 mock，未接 ezagent 任何服务
- [ ] **json-render 引擎是简化版** — 仅 10 种组件，Hello 真机有 36 种 + shadcn 主题
- [ ] **无 LLM 生成** — spec 树是预定义模板，非 AI 动态生成
- [ ] **无 Surface 版本管理** — 无 put_version/approve/commit 流程
- [ ] **无 Feishu 对接** — Allen 的 Feishu 入站/出站链路未体现
- [ ] **无产品录入** — 会员企业上传产品的流程未做
- [ ] **无用户认证** — 匿名访问，无 anon-user / 登录 / 身份绑定
- [ ] **无真实匹配逻辑** — 仅关键词字符串匹配，无向量检索/语义理解
- [ ] **移动端未专门适配** — 基础响应式可用但未精细优化

## 不做事项

- ❌ 不做 ezagent 后端对接（Phase 2）
- ❌ 不做产品管理后台
- ❌ 不做 Feishu 渠道（等 Allen 侧对接完成后再连）
- ❌ 不做真实数据对接（等协会提供产品目录后再 seed）
- ❌ 不做真正的 json-render → Surface 落地（纯前端 demo）

## 修改计划 v2 — 产品录入 + 自动 Session

### 目标概述

两个新增用户路径：
- **会员路径**：录入产品到展厅
- **客户路径**：联系企业时自动创建 session（参考 Dealscout 的 workspace 模式）

---

### Phase 1: 会员录入产品

#### 入口
- Browse 模式 topbar 右侧新增 `＋ 录入产品` 按钮（与 `重新开始` 并列）

#### 录入表单（Modal）
| 字段 | 类型 | 必填 |
|------|------|------|
| 产品名称 | text input | ✅ |
| 企业名称 | text input | ✅ |
| 一句话描述 | textarea (≤80字) | ✅ |
| 详细说明 | textarea (≤300字) | — |
| 所属分类 | `<select>` 从 ALL_CATS 取值 | ✅ |
| 标签 | text input（逗号分隔，2-5个） | — |

#### 提交后行为
- 自动生成 `id`、`tags` 数组、`kw` 关键词（从名称+描述+标签拆词）、`img` 颜色（随机从6色取）
- 追加到 `PRODUCTS` 数组头部
- 新增 `memberSubmitted: true` 标记（区分 seed 数据）
- Toast 提示"产品已录入 · 3秒后可从展厅搜索到"
- 关闭 Modal，自动刷新当前展厅视图

#### 数据约束
- 会员录入的产品支持后续"我录入的产品"列表查看
- 产品名称+企业名称组合去重（demo 级别，不强制）

---

### Phase 2: 客户联系企业 → 自动创建 Session

#### 参考模式
- Dealscout `index.html`：双方匹配 → 接上头弹窗 → "进入 workspace" → `world-placeholder.html`
- Dealscout `world-placeholder.html`：session 占位页，列出 workspace 需要哪些功能

#### CIIA 版实现

**Step 1 — 联系确认弹窗（替换当前占位）**

当前 `contactCompany()` 仅显示"需求已记录"占位。改造为：

```
┌─ 联系企业 · Contact ──────────────────────┐
│                                            │
│   您的需求已发送给 【企业名称】              │
│   产品：【产品名称】                        │
│                                            │
│   ┌──────────────────────────────────┐     │
│   │  👤 访客          🏢 企业方       │     │
│   │  您              企业对接人       │     │
│   └──────────────────────────────────┘     │
│                                            │
│   信息协会为您创建专属 Session 通道          │
│                                            │
│   [进入 Session · Open Session]   (主按钮)  │
│   [继续浏览 · Keep browsing]   (次按钮)    │
└────────────────────────────────────────────┘
```

**Step 2 — Session 页（新增 inline view）**

点击"进入 Session"后，切换到 Session 视图（类似 Hero→Browse 的翻转动画）：

```
┌─ Topbar ────────────────────────────────────┐
│ 🏛 信息协会 · Session                [返回展厅] │
├──────────────┬──────────────────────────────┤
│  产品名片     │  聊天区                       │
│              │                              │
│  [产品图]    │  系统：已为您连接             │
│  产品名称     │  【企业名称】的对接人         │
│  企业名称     │                              │
│  描述         │  企业方：您好，感谢关注！     │
│  标签         │  请问您想了解哪方面？         │
│              │                              │
│  ────────    │  ─────────────────────       │
│  联系信息     │  ┌──────────────────┐       │
│  (demo占位)  │  │ 输入消息…         │       │
│              │  │              [发送]│       │
│              │  └──────────────────┘       │
└──────────────┴──────────────────────────────┘
```

**Step 3 — 我的 Session 列表（topbar 入口）**

Browse 模式 topbar 新增 `我的 Session · Sessions (N)` 链接：
- 列出所有已创建的 session
- 每项显示：企业名称 + 产品名称 + 创建时间
- 点击进入对应 session 页

---

### Session 数据模型（前端 mock）

```js
const SESSIONS = []; // 全局 session 数组
// 每个 session:
{
  id: 'sess_001',
  productId: 1,
  companyName: '北京智影医疗科技有限公司',
  productName: '心脏超声辅助诊断系统',
  customerName: '访客',
  createdAt: '2026-07-21T10:30:00',
  messages: [
    {role:'system', text:'已为您连接企业对接人'},
    {role:'company', text:'您好，感谢关注！请问您想了解哪方面？'},
  ],
  unread: 1,
}
```

---

### 修改范围清单

| 文件 | 修改内容 |
|------|---------|
| `index.html` | ① `--accent-hover` bug fix（已完成）|
| | ② topbar 新增 `＋录入产品` + `我的 Session(N)` 按钮 |
| | ③ 新增 `#addProductModal` 表单弹窗 |
| | ④ 重写 `contactCompany()` — 联系确认弹窗 |
| | ⑤ 新增 `#sessionView` — Session 页 |
| | ⑥ 新增 `#sessionsListModal` — 我的 Session 列表弹窗 |
| | ⑦ JS：`addProduct()` / `createSession()` / `renderSession()` / `sendSessionMsg()` |
| | ⑧ JS：`SESSIONS` 数组 + session 管理逻辑 |

#### 不新增独立 HTML 文件
- Session 页内嵌在 `index.html` 中（通过 view 切换），保持单文件 demo 架构
- 这与 Dealscout 的 `world-placeholder.html` 策略不同：CIIA demo 用 view-switching 而非多页跳转，更流畅

---

### 暂不做
- ❌ 不做真实后端 session 创建（Phase 2）
- ❌ 不做企业方登录/身份认证
- ❌ 不做真实消息推送（WebSocket/PubSub）
- ❌ 不做产品编辑/删除（仅录入）

### UI Bug 修复记录
- [x] `--accent-hover:var(--accent-hover)` → `--accent-hover:#0040C4;`（自引用变量导致 hover 按钮变白）

## 修改计划 v3 — 侧边导航 + Bento 风格 + 登录

### 改动概述
- **左侧主导航栏**：会员产品展厅 / 我的 Session 两级
- **Bento 设计语言**：卡片网格、大圆角、柔阴影、白色卡片 + 浅灰底
- **登录**：侧边栏左下角，mock 登录
- **录入产品**：移入展厅内按钮，点击需登录

### 布局架构

```
┌──────────┬─────────────────────────────────────┐
│ Sidebar  │  Main Content                        │
│ (220px)  │                                      │
│          │  [Hero / Browse / Session / List]    │
│ 🏛 Logo  │                                      │
│          │                                      │
│ ◉ 展厅   │                                      │
│ ○ Session│                                      │
│          │                                      │
│          │                                      │
│ 👤 登录  │                                      │
└──────────┴─────────────────────────────────────┘
```

### Bento 设计 Token
- `--bg: #F0F0F3` (页面底色)
- `--card: #FFFFFF` (卡片)
- `--r-card: 18px` (卡片圆角)
- `--shadow-card: 0 1px 2px rgba(0,0,0,.04), 0 8px 16px rgba(0,0,0,.04)` (柔阴影)
- 导航项：pill 形状，左边距缩进

### 视图切换
- `showroom` → Hero（首页搜索）/ Browse（搜索结果）
- `sessions` → Session 列表（主视图）
- `session-detail` → 单个 Session 页
- 点击侧边栏切换顶层视图，Session 详情从列表进入

### 登录逻辑
- 侧边栏左下角显示头像 + "访客" + "登录"按钮
- 点击登录 → 简易弹窗输入姓名
- 登录后：头像变彩色，显示用户名
- 录入产品需登录态检查

### 已完成 Changelog
- [x] v3: 侧边导航 + Bento 风格 + 登录（sidebar 220px, bento cards, localStorage 登录）
- [x] v3: 录入产品需登录态检查（`openAddProduct` 检查 `currentUser`）
- [x] v2: Session 页（inline view-switching）
- [x] v2: Session 列表
- [x] v1: `--accent-hover` bug fix

## 下一步

1. 给协会看过 demo → 收集反馈
2. 根据反馈确定后端实施范围
3. 创建 信息协会 socialware Definition (YAML manifest)
4. 对接 Feishu 入站/出站（Allen 侧）
5. 产品数据 seed → 替换 mock 数据
