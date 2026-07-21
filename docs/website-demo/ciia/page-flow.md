# 信息协会产品展厅 · Page Flow

> 单文件多视图架构（index.html），通过 CSS class toggle（`on` / `fade`）切换。无页面跳转，状态保持在 JS 全局变量中。

---

## 视图总览

### 顶层视图（同一时刻仅一个可见）

| # | 视图 | DOM ID | 说明 |
|---|------|--------|------|
| 1 | **Hero（首页）** | `#hero` | 搜索入口 + 跑马灯标签 + 快捷芯片 |
| 2 | **Browse（展厅浏览）** | `#browse` | 产品卡片网格 + 分类 Tab + 聊天浮层 |
| 3 | **Session 详情** | `#sessionView` | 产品名片（左）+ 实时聊天（右） |
| 4 | **Session 列表** | `#sessionsListView` | 所有已发起的对接列表 |

### 覆盖层（叠加在任意顶层视图之上）

| # | 覆盖层 | DOM ID | 触发条件 |
|---|--------|--------|---------|
| A | **产品详情** | `#overlay` → `#dlg` | 点击产品卡片 / "了解详情" |
| B | **联系确认** | `#overlay` → `#dlg` | 点击"联系企业" |
| C | **录入产品** | `#addProductOverlay` | 点击展厅 topbar `＋ 录入产品` |
| D | **登录** | `#loginOverlay` | 点击侧边栏"登录" / 未登录点录入 |
| E | **Toast** | `#toast` | 操作反馈（录入成功 / 校验失败 / 登录） |

### 常驻元素

| 元素 | 说明 |
|------|------|
| **侧边栏** | 品牌标识 + 导航（产品展厅 / 我的 Session）+ 登录区 |
| **Toast** | 全局通知，2.8s 自动消失 |

---

## 视图状态机

```
                    ┌──────────────────────────────────────┐
                    │            Hero（首页）                │
                    │  · 搜索框 + 跑马灯 + 快捷芯片         │
                    └──────┬───────────────┬───────────────┘
                           │               │
                    发送搜索          点击侧边栏
                           │          「我的 Session」
                           ▼               │
                    ┌──────────────┐        │
                    │   Browse     │        │
                    │  (展厅浏览)   │        │
                    │              │        │
                    │ · 产品网格   │        │
                    │ · 分类 Tab   │        │
                    │ · 聊天浮层   │        │
                    └──┬───┬───┬──┘        │
                       │   │   │           │
            点击        │   │   │   点击侧边栏
         「联系企业」    │   │   │  「产品展厅」
                       │   │   │           │
                       ▼   │   │           ▼
              ┌──────────┐ │   │   ┌────────────────┐
              │ 联系确认  │ │   │   │  Session 列表   │
              │ (Modal)  │ │   │   │                │
              └────┬─────┘ │   │   │ · 按时间倒序   │
                   │       │   │   │ · 点击进入详情  │
              点击「进入   │   │   └───────┬────────┘
              Session」    │   │           │
                   │       │   │     点击某个 Session
                   ▼       │   │           │
              ┌────────────┴───┴───────────┴──┐
              │       Session 详情              │
              │  · 产品名片（左）               │
              │  · 聊天区（右）                 │
              │  · 企业 mock 自动回复           │
              └────────────────────────────────┘
                           │
              点击 topbar「返回展厅」
              或「返回 Session 列表」
                           │
                           ▼
                    回到 Browse / Session 列表
```

---

## 各视图详细说明

### 1. Hero（首页）

**进入条件**：初始加载 / 点击侧边栏「产品展厅」/ 点击「重新开始」

**包含元素**：
- 协会 Logo + 标题 + 副标题
- **「会员企业 · 录入产品」入口卡片**（虚线边框 bento 卡片，hover 时绿色高亮，点击跳登录/录入流程）
- 搜索输入框（textarea，max 200 字）
- 5 个快捷芯片（医疗影像 / 数据分析 / 安全合规 / 智能制造 / 智能办公）
- "发送 · Send" 按钮
- 两行跑马灯标签（自动滚动，点击可触发搜索）

**用户行为**：
- 输入需求 → 点发送 → 进入 Browse
- 点击芯片 → 自动填充 → 进入 Browse
- 点击跑马灯标签 → 自动填充 → 进入 Browse

**退出条件**：发送消息后 → `handleQuery()` → Hero fade out → Browse fade in

---

### 2. Browse（展厅浏览）

**进入条件**：从 Hero 发送搜索 / 从 Session 详情点「返回展厅」

**包含元素**：
- Topbar：Logo + 标题 + **「＋ 录入产品」** + 「重新开始」
- Tab Bar：分类筛选（全部 / 医疗健康 / 数据智能 / …），动态生成
- Product Grid：3 列卡片网格（响应式 3→2→1）
  - 每张卡片：产品图 + 名称 + 企业 + 描述 + 标签 + 3 个操作按钮
  - 3 个操作按钮：**了解详情** / **联系企业** / **追问**
- 聊天浮层（底部居中，max-width: 520px）：
  - 消息列表（位置透明度：底部清晰 → 顶部渐隐）
  - 输入框 + 发送按钮
  - 「隐藏/查看对话记录」切换

**用户行为**：
- 点击分类 Tab → 筛选当前结果
- 点击产品卡片 → 打开产品详情 Modal
- 点击「了解详情」→ 同上
- 点击「联系企业」→ 打开联系确认 Modal
- 点击「追问」→ 填充聊天输入框
- 在聊天框输入 → 发送 → 重新匹配产品 → 更新网格
- 点击「＋ 录入产品」→ 登录检查 → 录入表单 Modal
- 点击「重新开始」→ 回到 Hero

**状态变量**：
- `activeCat` — 当前选中的分类（null = 全部）
- `currentProducts` — 当前展示的产品数组
- `isBrowsing` — 是否处于浏览模式

---

### 3. Session 详情

**进入条件**：
- 从联系确认 Modal 点击「进入 Session」
- 从 Session 列表点击某个 Session 卡片

**包含元素**：
- Topbar：Logo + 「信息协会 · Session」+ 企业名称 + **「返回 Session 列表」** + **「返回展厅」**
- 左侧面板（280px，响应式折叠）：
  - 产品图片
  - 产品名称 + 企业名称
  - 产品描述 + 标签
  - Session 元信息（编号 / 创建时间 / 连接状态）
- 右侧聊天区：
  - 消息列表（系统消息居中 / 企业消息左对齐 / 用户消息右对齐）
  - 输入框 + 发送按钮
  - 企业方 mock 自动回复（1.5-3.5s 延迟）

**聊天角色**：
| 角色 | CSS class | 气泡样式 | 头像 |
|------|-----------|---------|------|
| 系统 | `.system` | 居中、透明底、灰色文字 | 无 |
| 企业方 | `.company` | 左对齐、白底卡片、柔阴影 | 「企」蓝色 |
| 用户 | `.user-msg` | 右对齐、蓝色底白字 | 用户首字/登录色 |

**用户行为**：
- 输入消息 → 发送 → 企业 mock 回复
- 点击「返回 Session 列表」→ 进入 Session 列表视图
- 点击「返回展厅」→ 进入 Browse 视图

**状态变量**：
- `activeSessionId` — 当前打开的 session ID

---

### 4. Session 列表

**进入条件**：点击侧边栏「我的 Session」

**包含元素**：
- Header：标题 + 副标题
- 列表（按创建时间倒序）：
  - 每项：企业头像 + 企业名称 + 产品名称 + 时间 + 消息数 + 「● 已连接」标签
- 空状态：图标 + 「暂无 Session」+ 「去展厅看看 →」引导按钮

**用户行为**：
- 点击某项 → 进入 Session 详情
- 空状态点「去展厅看看」→ 切换到 Hero

**状态变量**：
- `SESSIONS` — 全局 session 数组（`localStorage` 未持久化）

---

## 覆盖层流

### A. 产品详情 Modal

```
点击产品卡片 / 「了解详情」
  → open #overlay
  → render detail HTML (名称 + 企业 + 标签 + 详细描述 + CTA)
  → CTA: 「联系企业获取方案」
     → 关闭详情 → 打开联系确认 Modal
  → 关闭: × 按钮 / 点击遮罩 / Esc
```

### B. 联系确认 → Session 创建

```
点击「联系企业」(传 productId)
  → open #overlay
  → render 双方身份卡 (访客 / 企业方)
  → 「进入 Session」
     → closeDetail()
     → createAndEnterSession(productId)
        → 检查 SESSIONS 是否已有该产品的 session
           → 有: 复用
           → 无: 创建新 session (id + productId + 初始消息)
        → updateSessBadge()
        → openSessionView(session.id)
           → 隐藏 Hero / Browse / Session 列表
           → 显示 #sessionView
  → 「继续浏览」
     → closeDetail()
```

**Session 创建数据**：
```js
{
  id: 'sess_' + Date.now(),
  productId, companyName, productName, productImg,
  createdAt: new Date().toISOString(),
  messages: [
    { role:'system', text:'已为您连接...' },
    { role:'company', text:'您好！感谢您关注...' },
  ],
  unread: 0,
}
```

### C. 录入产品

```
点击「＋ 录入产品」
  → 检查 currentUser (登录态)
     → 未登录: showToast → openLogin()
     → 已登录: openAddProduct()
        → populate 分类下拉
        → open #addProductOverlay
        → 用户填写 6 个字段
        → submitProduct()
           → 校验必填字段
           → 构建 product 对象 (自动生成 kw / img / id)
           → PRODUCTS.unshift(product)
           → 刷新 ALL_CATS
           → closeAddProduct()
           → 刷新 Browse 视图
           → showToast('已录入')
```

### D. 登录

```
点击侧边栏「登录」/ 未登录点录入
  → openLogin()
  → open #loginOverlay
  → 填写显示名称 + 选择头像颜色（6 色可选）
  → doLogin()
     → currentUser = { name, color }
     → localStorage.setItem('ciia_user', JSON)
     → updateLoginUI() (侧边栏头像变色)
     → closeLogin()
     → showToast('已登录')

退出登录:
  → doLogout()
     → currentUser = null
     → localStorage.removeItem('ciia_user')
     → updateLoginUI()
```

### E. Toast

```
showToast(msg)
  → 底部居中显示
  → 2.8s 后自动消失
  → 多次调用清除前一个 timer
```

---

## 侧边栏导航

```
┌─────────────────┐
│ 🏛 信息协会      │  ← 品牌标识
│    CIIA Showroom│
│                 │
│ ◉ 产品展厅       │  ← navShowroom → switchView('showroom')
│ ○ 我的 Session   │  ← navSessions → switchView('sessions')
│   [N]           │  ← 未读/总数 badge（SESSIONS.length）
│                 │
│ ─────────────── │
│ 👤 访客   [登录] │  ← 登录态切换
└─────────────────┘
```

**导航行为**：
- 点击「产品展厅」→ `switchView('showroom')` → Hero 首页
- 点击「我的 Session」→ `switchView('sessions')` → Session 列表
- 「产品展厅」在 Hero / Browse / Session 详情时高亮
- 「我的 Session」在 Session 列表时高亮

---

## 完整用户旅程

### Journey 1: 客户搜索 → 联系企业 → Session

```
Hero (输入需求)
  → Browse (查看匹配产品)
  → 点击「联系企业」
  → 联系确认 Modal (双方身份卡)
  → 点击「进入 Session」
  → Session 详情 (产品名片 + 聊天)
  → 发送消息 → 企业 mock 回复
  → 「返回展厅」→ Browse
  → 「重新开始」→ Hero
```

### Journey 2: 会员录入产品

```
Hero (首页)
  → 点击「会员企业 · 录入产品」卡片
     或 Browse topbar「＋ 录入产品」
  → (未登录 → 登录 Modal → 登录)
  → 录入产品 Modal (填写 6 个字段)
  → 提交
  → Toast「已录入」
  → Browse 自动刷新 (新产品在网格首位)
```

### Journey 3: 查看 Session 历史

```
任意视图
  → 点击侧边栏「我的 Session」
  → Session 列表
  → 点击某个 Session
  → Session 详情 (继续聊天)
  → 「返回 Session 列表」
  → Session 列表
```

---

## 技术架构

```
                    ┌──────────────────────┐
                    │     index.html        │
                    │   (单文件 1049 行)     │
                    │                      │
                    │  CSS: Bento tokens   │
                    │  HTML: 4 视图 + 4    │
                    │        覆盖层 + 侧栏  │
                    │  JS: 全局状态管理     │
                    └──────────────────────┘

视图切换方式: CSS class toggle (.on / .fade)
状态管理:    全局变量 (PRODUCTS / SESSIONS / currentUser / currentView)
持久化:      localStorage (仅 currentUser)
路由:        无 URL 路由，纯 JS 状态驱动
响应式:      3 断点 (860px / 600px / 400px)
```

---

## 关键变量

| 变量 | 类型 | 初始值 | 说明 |
|------|------|--------|------|
| `currentView` | `string` | `'showroom'` | 当前顶层视图 ID |
| `isBrowsing` | `boolean` | `false` | 是否在展厅浏览模式 |
| `activeCat` | `string\|null` | `null` | 当前分类筛选（null=全部） |
| `currentProducts` | `array` | `PRODUCTS` | 当前展示的产品数组 |
| `activeSessionId` | `string\|null` | `null` | 当前打开的 session ID |
| `SESSIONS` | `array` | `[]` | 所有 session 对象 |
| `currentUser` | `object\|null` | `null`/localStorage | 当前登录用户 {name, color} |
| `PRODUCTS` | `array` | 10 条 seed | 所有产品（含会员录入） |
| `ALL_CATS` | `array` | 动态 | 分类列表（产品录入后刷新） |
