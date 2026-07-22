# Carousel + Demo 合并计划

## 源文件

| 文件 | 角色 |
|:--|:--|
| `carousel-socialware.html` (392 行) | 新骨架：carousel 卡片 + header 区 + bottom sheet |
| `demo/index.html` (1430 行) | 完整内容：7 个 socialware 的内容 + Session + 登录 + 产品录入 |

## 合并原则

**Carousel 只替换导航和对话框，不改内容。**

- carousel 卡片 = 原来的侧边栏导航项（6 个 socialware）
- bottom sheet = 原来的 hello builder 对话框（合并为一个通用组件）
- header zone = 原来每个 socialware 的内容区（关于文本/表单/报告列表/合作卡片/产品网格）
- 去掉：侧边栏、sidebar login、topbar、各 socialware 独立的 `.hello-bar`

---

## 一、Socialware × 区域映射

| # | Socialware | Header 区（内容） | Bottom Sheet（对话框） | 特殊交互 |
|:--|:--|:--|:--|:--|
| 1 | **产品展厅** | Hero 搜索（split-panel）→ Browse 产品网格 | 展厅顾问 Agent | 搜索→产品网格替换 header；联系企业→sheet 变 Session |
| 2 | **关于协会** | 统计卡片 + 定位/宗旨/使命/组织架构 文本 | 协会咨询 Agent | — |
| 3 | **入会申请** | 条件/权益卡片 + 4 字段表单 | 入会引导 Agent | — |
| 4 | **行业研究院** | 4 篇报告列表 | 行业洞察 Agent | — |
| 5 | **合作对接** | 4 张合作需求卡片 | 合作匹配 Agent | — |
| 6 | **会员专区** | 3 tab（产品/Session/资料）| 会员助手 Agent | 需登录；tab 切换在 header 区内 |
| 7 | **管理后台** | 统计卡片 + 审核列表 | 运营助手 Agent | 需管理员角色 |
| — | **Session 详情** | 产品名片（左）+ 对话（右）| 替换 sheet，撑满下半屏 | 从展厅"联系企业"触发 |
| — | **Session 列表** | 所有 Session 的卡片列表 | — | 从某处入口进入 |

---

## 二、需要解决的设计问题

### Q1: 产品展厅是两步流程（搜索→浏览），carousel 怎么承载？

**方案**：产品展厅的 header 区有三态——

```
状态 A（初始）: Hero — split-panel 搜索
状态 B（搜索后）: Browse — 产品网格 + 分类 tab
状态 C（Session）: sheet 变为 Session 聊天
```

状态 A→B：用户发送搜索 → header 替换为产品网格。sheet 保持打开（Agent 可继续对话）。
状态 B→C：用户点"联系企业"→ sheet 从 Agent 对话切换为 Session 聊天。

### Q2: Session 聊天放哪里？

**方案**：Session 聊天替换 bottom sheet 的内容。

- 正常态：sheet = socialware 的 Agent 对话
- Session 态：sheet = 双方聊天（产品名片缩略图 + 消息列表 + 输入）
- sheet 高度在 Session 态时变大（从 46% → 65%），或者全屏

### Q3: 登录入口在哪里？

**方案**：右上角增加一个登录 icon/按钮。点击弹 login modal（复用 demo 的 `#loginOverlay`）。

登录后：会员专区卡片可用；右上角显示头像和用户名。

### Q4: "我的 Session" 入口在哪里？

原来侧边栏的个人区有"我的 Session"。现在有两个选项：
- **A**: 右上角 login 旁边放一个 "💬 Session (N)" 按钮
- **B**: 会员专区的 tab 里保留"客户 Session"列表

建议 **A + B 共存**：右上角有全局入口（所有 Session），会员专区 tab 里也有（该会员的 Session）。

### Q5: 管理后台如何进入？

会员和管理员共用一个"会员专区"卡片，还是分开？建议：**共用一个卡片**。登录后卡片变为"会员专区"；如果是管理员，card 上多一个 "⚙️ 管理" 小入口。

---

## 三、合并后的 HTML 结构

```
body
├── header-zone          ← 动态渲染当前 socialware 的内容
│   ├── (产品展厅: hero split-panel / browse grid)
│   ├── (关于协会: 文本卡片)
│   ├── (入会申请: 表单)
│   ├── ...
│   └── (每切换 socialware，innerHTML 刷新)
│
├── top-right-controls    ← 新增：登录 + Session 入口
│   ├── login-btn
│   └── session-badge
│
├── carousel-zone         ← 底部卡片轮播
│   └── carousel-track > sw-card × 7
│
├── sheet                 ← 通用对话框
│   ├── sheet-header (Agent 名称 + icon + close)
│   ├── sheet-messages
│   └── sheet-composer
│
├── scroll-handle         ← 右侧滚动指示器
│
├── login modal           ← 复用 demo 的 #loginOverlay
├── product-detail modal  ← 复用 demo 的 #overlay
├── add-product modal     ← 复用 demo 的 #addProductOverlay
└── toast                 ← 复用
```

---

## 四、需要从 demo 复用的 JS 模块

| 模块 | 说明 |
|:--|:--|
| `PRODUCTS` 数组 + `ALL_CATS` | 产品数据 |
| `matchProducts()` / `renderProducts()` / `renderGrid()` / `glyph()` | 产品搜索和渲染 |
| `SESSIONS` 数组 + `createAndEnterSession()` | Session 管理 |
| `openSessionView()` / `sendSessionMsg()` | Session 聊天（适配到 sheet 内） |
| `currentUser` + `updateLoginUI()` + `doLogin()` / `doLogout()` | 登录 |
| `openAddProduct()` / `submitProduct()` | 产品录入 |
| `showToast()` | Toast 通知 |
| `escapeHtml()` / `sleep()` | 工具函数 |
| Hello Builder 的 `helloGreetings` + `replies` | Agent 对话内容 |
| `showDetail()` / `contactCompany()` | 产品详情 + 联系企业 |

## 五、不需要从 demo 复用的

| 模块 | 原因 |
|:--|:--|
| `switchView()` | 被 carousel scroll + sheet open/close 取代 |
| 侧边栏 CSS/HTML | 被 carousel 取代 |
| 各 socialware 独立的 `.hello-bar` | 统一为一个 `.sheet` |
| `toggleHello()` / `sendHelloMsg()` | 改为 sheet 的 open/close + send |
| 各 socialware view div（`#aboutView` 等）| 内容按需渲染进 `header-zone` |
| `updateSessBadge()` / `navSessBadge` | 改为右上角 badge |

---

## 六、实施步骤

| Step | 内容 | 预计 |
|:--|:--|:--|
| 1 | 复制 carousel-socialware.html → visual-tests/carousel-socialware.html | — |
| 2 | 把 demo 的 CSS（表单/报告列表/合作卡片/统计卡片/member-tabs/admin）合并进来 | 30 min |
| 3 | 把 header-zone 改成动态渲染：每个 socialware 的 `renderContent(swId)` 函数 | 30 min |
| 4 | 把 bottom sheet 改成通用组件：支持 Agent 模式 + Session 模式 | 30 min |
| 5 | 产品展厅特殊流程：Hero → Browse → Session | 30 min |
| 6 | 加入登录 + Session badge（右上角） | 15 min |
| 7 | 加入所有 modal（login / product-detail / add-product）和 toast | 15 min |
| 8 | 联调：所有 socialware 内容 + 所有交互 | 20 min |

---

## 七、待确认

1. **Session 聊天放 sheet 里（撑大）还是单独全屏？** → 建议 sheet 撑大到 65-70%，产品名片缩略图放在 sheet header 下方
2. **管理后台是否独立一张卡？** → 建议与会员专区合并，管理员看到额外入口
3. **产品展厅的 Hero 搜索在 carousel 模式下怎么触发 sheet？** → 建议：展厅卡片被选中时自动打开 sheet（搜索 Agent 主动问候），用户可直接在 sheet 里输入搜索需求
