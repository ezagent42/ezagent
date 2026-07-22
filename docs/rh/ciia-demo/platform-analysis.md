# 信息协会（CIIA）平台 · 产品架构分析框架

> 目标：基于 ezagent 产品能力，为信息协会提供一个获客 + 管理会员 + 转化会员为客户的三合一平台。
> 本文件是**分析框架**——定义需要分析的维度、方法、产物。实际内容待输入数据后填充。

---

## 1. 平台定位

### 一句话

**信息协会通过 ezagent 为会员企业提供 AI 驱动的产品对接平台，同时让会员在使用中自然体验 ezagent 的 Session/Agent 能力，进而转化为 ezagent 客户。**

### 双面定位

| 面 | 对谁说的 | 核心信息 |
|----|---------|---------|
| **对外**（CIIA 品牌） | 会员企业、潜在会员、客户、合作伙伴 | "信息协会为会员企业提供 AI 产品展厅，帮客户找到对的供应商" |
| **对内**（ezagent 品牌） | 平台使用者（尤其是会员企业） | "这个展厅、Session 对接、AI Agent 能力都由 ezagent 提供——您的企业也可以拥有同样的平台" |

### 平台名称（待定）

- `ciia.ezagent.chat` — 建议：二级域名体现"CIIA 的 ezagent 实例"
- 页面标题格式：`信息协会 · CIIA × ezagent`

---

## 2. 用户分层 × 场景矩阵

### 角色定义

| # | 角色 | 说明 | 是否需要登录 |
|---|------|------|------------|
| R1 | **CIIA 内部人士** | 协会工作人员，管理会员、审核产品、查看数据 | ✅ |
| R2 | **会员企业** | 已入会的企业，录入产品、查看客户咨询 | ✅ |
| R3 | **潜在会员** | 想入会的企业，了解协会、提交申请 | — |
| R4 | **客户** | 想找产品/供应商的外部访客 | — |
| R5 | **合作伙伴** | 与协会合作的机构（媒体、展会、投资方） | — |
| R6 | **潜在客户** | 浏览行业内容、关注趋势的访客 | — |

### 场景矩阵

> **填充方式**：角色 × Socialware。每格 = 这个角色在这个 socialware 里做什么 + 用到的 ezagent 能力。

| 角色 →<br>Socialware ↓ | R1 内部 | R2 会员 | R3 潜在会员 | R4 客户 | R5 合作伙伴 | R6 潜在客户 |
|:--|:--|:--|:--|:--|:--|:--|
| **产品展厅** | 审核产品、推荐产品 | 录入产品、回复客户咨询 | 浏览展厅、了解会员企业 | 搜索产品、联系企业 | 浏览展厅 | 浏览展厅、发现供应商 |
| **协会介绍** | — | — | 了解协会、查看权益 | — | 了解协会 | 了解协会 |
| **入会申请** | 审批入会 | — | 提交申请、咨询入会 | — | — | — |
| **会员专区** | 管理会员名录 | 我的产品、客户 Session、续费 | — | — | — | — |
| **合作对接** | 审核合作 | 发布合作需求 | — | — | 发布合作、对接资源 | — |
| **行业研究院** | 发布报告 | 浏览报告、引用数据 | 浏览报告 | 浏览报告 | 浏览报告 | 浏览报告、AI 洞察 |
| **管理后台** | 数据分析、审核流程 | — | — | — | — | — |

### ezagent 能力映射

> 每个 socialware 场景用到的 ezagent 底层能力。

| Socialware | Session | Agent | CapBAC | json-render | Feishu Adapter | ConfigStore |
|:--|:--|:--|:--|:--|:--|:--|
| 产品展厅 | ✅ 客户↔企业对接 | ✅ 搜索匹配 Agent | ✅ 会员录入权限 | ✅ 产品卡片渲染 | ✅ 企业接收通知 | ✅ 产品数据 |
| 协会介绍 | — | ✅ 咨询 Agent | — | ✅ 页面渲染 | — | ✅ 内容配置 |
| 入会申请 | ✅ 申请跟踪 | ✅ 入会引导 Agent | ✅ 审批流权限 | ✅ 表单渲染 | — | ✅ 申请表配置 |
| 会员专区 | ✅ 咨询记录 | — | ✅ 角色隔离 | ✅ 仪表盘渲染 | — | ✅ 会员数据 |
| 合作对接 | ✅ 双方对接 | ✅ 匹配 Agent | ✅ 角色/状态权限 | ✅ 合作卡片渲染 | — | ✅ 合作信息 |
| 行业研究院 | — | ✅ AI 洞察 Agent | — | ✅ 内容页渲染 | — | ✅ 报告 CMS |
| 管理后台 | — | ✅ 审核 Agent | ✅ 管理员权限 | ✅ 后台渲染 | — | ✅ 全平台数据 |

---

## 3. IA（信息架构）：完整页面树

```
CIIA 平台（ciia.ezagent.chat）
│
├── 🏠 首页
│   ├── Hero：搜索 + 快捷入口
│   ├── 行业动态 / 协会资讯
│   ├── 精选产品（展厅入口）
│   └── 底栏：关于协会 · 入会申请 · 联系方式
│
├── 🏛 产品展厅（已做 demo v3）
│   ├── 搜索产品（自然语言 → 匹配）
│   ├── 产品详情 ──→ 💬 Session
│   └── 录入产品（会员，需登录）
│
├── 📋 关于协会
│   ├── 协会简介 / 组织架构 / 会员权益
│   └── 💬 协会咨询 Agent
│
├── ✍️ 入会申请
│   ├── 申请表单
│   └── 💬 入会引导 Agent ──→ 咨询产生 Session
│
├── 📊 行业研究院
│   ├── 报告 / 白皮书 / 标准
│   └── 💬 行业洞察 Agent
│
├── 🤝 合作对接
│   ├── 合作广场（需求列表）
│   └── 💬 合作匹配 Agent ──→ 对接产生 Session
│
├── 👤 会员专区（需登录）
│   ├── 我的产品（增删改查）
│   ├── 企业资料
│   └── 会费/续费
│
├── ⚙️ 管理后台（需管理员权限）
│   ├── 会员管理 / 产品审核 / 内容管理
│   └── 数据分析
│
└── 💬 我的 Session ← 个人区（非 socialware，所有对话的收束点）
    ├── 产品咨询（来自展厅联系企业）
    ├── 合作对接（来自合作广场）
    ├── 入会咨询（来自入会申请）
    └── …（来自任何 socialware 的对话都收束于此）
```

---

## 4. CIIA 定制 vs ezagent 平台能力：边界表

### 核心原则

> **Session、Agent、CapBAC 是 ezagent 的地盘——这些地方必须让用户感知到 ezagent 的存在。CIIA 的 logo 可以放在页面上，但不能盖住 "Powered by ezagent"。**

### Session ≠ Socialware

**Session 是平台级通信原语，不是某个 socialware 的子页面。**

```
产品展厅 ──联系企业──┐
合作对接 ──发起对接──┼──→ 💬 Session（统一收件箱）
入会申请 ──咨询跟进──┘
行业研究院 ──追问报告─┘
```

- **Socialware** = 用户"逛"的场所（展厅、研究院、合作广场）——每个是一个目的地
- **Session** = 用户与他人的**所有对话的收束点**——它是一个全局收件箱，不属于任何一个 socialware
- 用户从任何 socialware 发起联系/对接/咨询后，产生的对话都进入同一个 Session 列表
- Session 入口放在**个人区**（侧边栏底部、登录区上方），与 socialware 列表分离

### 分层边界

| 层 | CIIA 特有（每部署定制） | ezagent 平台（跨客户统一） | 心智归属 |
|:--|:--|:--|:--|
| **品牌** | Logo、协会名称、配色（可选）、域名 `ciia.ezagent.chat` | Bento 设计系统、组件库、字体系统 | ezagent 设计系统为底，CIIA 品牌为面 |
| **内容** | 协会介绍、会员权益、入会条件、行业报告、会员企业数据 | 内容渲染引擎（json-render / Surface） | 内容是 CIIA 的，渲染引擎是 ezagent 的 |
| **数据** | 产品分类体系、会员企业列表、行业报告 CMS | ConfigStore / Recipe seed data / 数据 schema | CIIA 提供数据，ezagent 提供存储和检索 |
| **Socialware** | 每个 socialware 的 Definition（YAML manifest）——页面结构、routing_rules、agent recipe | Socialware 框架、Surface 版本管理、TurnDriver | CIIA 定义业务，ezagent 提供运行时 |
| **交互（核心）** | 业务流程（入会审批规则、产品审核规则、合作匹配规则） | **Session 引擎**（所有对话）<br>**Agent 框架**（所有 AI 协同）<br>**CapBAC**（权限）<br>**Feishu Adapter**（外部渠道） | **ezagent 独占**——用户在这里接触的是 ezagent 核心能力 |
| **渠道** | CIIA 的 Feishu 企业（app_id、渠道配置） | Feishu adapter 框架（渠道绑定、入站出站） | 渠道是 CIIA 的，adapter 框架是 ezagent 的 |

### 边界检查

> 任何时候问自己：如果换一个协会（比如"软件协会"），哪些东西需要改？
> 
> **详见 [PORTABILITY.md](PORTABILITY.md)** —— 移植清单、操作步骤、预估工时。

| 需要改 | 不需要改 |
|--------|---------|
| Logo、名称、域名 | Session 创建/投递/展示 |
| 产品分类（医疗健康 → 软件/信息技术） | 搜索匹配 engine |
| Socialware 的 routing_rules | json-render 渲染引擎 |
| 入会条件文案 | CapBAC 权限模型 |
| 行业报告内容 | Feishu adapter 协议层 |
| 管理后台的审核规则（业务逻辑） | Agent recipe 的执行框架 |

---

## 5. ezagent 心智占领：Touchpoint 清单

> 原则：**接触即认知**——用户每次用到 Session/Agent/CapBAC 时，就要看到 ezagent。

### 5.1 Session 场景

| Touchpoint | 露出内容 | 时机 |
|:--|:--|:--|
| Session 创建 toast | "ezagent Session 已创建" + logo | 客户点击"联系企业"后 |
| Session 系统消息 | "信息协会通过 **ezagent** 为您提供安全对接通道" | 每次进入 Session 的第一条消息 |
| Session 页 footer | "Powered by **ezagent** · Session Engine" + 链接 | 常驻 |
| Session 空状态 | "还没有消息。通过 ezagent Session，双方可以安全地交换信息和文件。" | Session 刚创建时 |
| Session 列表页 | "共 N 个 Session · 由 ezagent 驱动" | 我的 Session 页 subtitle |

### 5.2 Agent 场景

| Touchpoint | 露出内容 | 时机 |
|:--|:--|:--|
| Agent 首次响应 | "我是信息协会的 AI 助手，由 **ezagent Agent 框架** 驱动" | Agent 第一条消息 |
| Agent 切换（展厅顾问→匹配 Agent） | "正在调用 ezagent 匹配引擎…" | Agent 切换时 |
| 入会咨询 Agent | "入会咨询由 ezagent Agent 提供，协会工作人员可随时接管" | 对话中 |

### 5.3 平台级

| Touchpoint | 露出内容 | 时机 |
|:--|:--|:--|
| 登录/注册 | "使用 **ezagent** 身份登录" | 登录 Modal |
| 页脚 | "🏗 本平台由 **ezagent** 提供技术驱动 · 信息协会 × ezagent" | 全局 |
| 错误页 | "ezagent 引擎暂时不可用 · 请稍后重试" | 5xx |
| 产品录入成功 | "产品已发布到 **ezagent** 展厅引擎，3 秒后可搜索" | 录入成功 toast |
| 匹配无结果 | "暂无匹配产品。ezagent 匹配引擎正在学习更多行业数据。" | 空状态 |

### 5.4 不露出 ezagent 的地方

| 场景 | 原因 |
|:--|:--|
| CIIA 协会介绍页 | 这是 CIIA 的品牌主场 |
| 会员权益页 | CIIA 自己的内容 |
| 行业报告正文 | CIIA 的内容资产 |
| 入会申请表单 | 用户正在与 CIIA 建立关系 |

---

## 6. 分析推进计划

### 已完成

| # | 分析项 | 产物 |
|---|--------|------|
| 1 | 分析框架（本文件） | `docs/rh/ciia-demo/platform-analysis.md` |
| 2 | Demo v3（概念验证） | `docs/website-demo/ciia/index.html` · PR #1499 |
| 3 | Page Flow 文档 | `docs/website-demo/ciia/page-flow.md` |
| 4 | Design Brief | `docs/website-demo/ciia/design-brief.md` |

### 待推进

| # | 分析项 | 输入 | 产物 | 优先级 |
|---|--------|------|------|--------|
| 1 | **爬取 CIIA 现有网站** | http://www.ciia.org.cn / 信息协会官网 | `ciia-website-content.md`（页面清单 + 栏目 + 内容摘要） | 🔴 最高 |
| 2 | **内容 Gap 分析** | CIIA 网站内容 + Demo 已做内容 | `ciia-content-gap.md`（缺什么 + 增强什么） | 🔴 高 |
| 3 | **用户-场景矩阵填充** | CIIA 网站内容 + 协会实际运营数据 | 填充 §2 场景矩阵 + 角色定义细化 | 🟡 高 |
| 4 | **IA 定案** | Gap 分析 + 场景矩阵 + Demo 反馈 | `ciia-ia-final.md`（最终 IA 树 + 每页 wireframe 描述） | 🟡 中 |
| 5 | **Socialware Definition 拆分** | IA 定案 | 每个 socialware 的 YAML manifest 草稿 | 🟢 低 |
| 6 | **Feishu 对接方案** | Allen 的 Feishu 接入进展 | `ciia-feishu-integration.md` | 🟢 低 |

---

## 7. 关于 CIIA 现有网站的爬取

### 需要爬取的内容

| 目标 | 用途 | 方法 |
|:--|:--|:--|
| CIIA 官网首页 | 了解协会定位 + 对外话术 | web_fetch / web-crawler |
| 关于协会 / 协会简介 | 填充 IA §关于协会 | web_fetch |
| 会员服务 / 会员权益 | 填充入会申请内容 | web_fetch |
| 会员名录（如有） | 了解现有会员企业数量和分类 | web_fetch / 手动整理 |
| 行业研究 / 报告（如有） | 填充 IA §行业研究院 | web_fetch |
| 新闻动态 | 填充 IA §首页行业动态 | web_fetch |
| 入会流程 / 条件（如有） | 填充 IA §入会申请 | web_fetch |

### 爬取格式

建议输出 `docs/rh/ciia-demo/ciia-website-content.md`，格式：

```markdown
# CIIA 网站内容爬取 · YYYY-MM-DD

## 页面清单
| URL | 标题 | 内容摘要 | 对应 IA 节点 |
|-----|------|---------|------------|
| ... | ... | ... | ... |

## 每页详细内容
### 首页
- 关键信息：...
- 导航结构：...
- 可复用内容：...
```

---

## 附录

### A. 相关文件索引

| 文件 | 说明 |
|:--|:--|
| `docs/website-demo/ciia/index.html` | Demo v3（split-panel + Session + Bento） |
| `docs/website-demo/ciia/page-flow.md` | 页面流 + 状态机 + 用户旅程 |
| `docs/website-demo/ciia/design-brief.md` | 设计简报（IA 映射 + 修改计划 + Gap + Changelog） |
| `docs/website-demo/ciia/split-panel-prototype.html` | Split-panel 交互原型 |
| `docs/rh/ciia-demo/platform-analysis.md` | **本文件** |

### B. 术语对应

| CIIA 语境 | ezagent 术语 | 说明 |
|:--|:--|:--|
| 企业对接 / 咨询 | **Session** | 客户联系企业时自动创建的安全对话通道 |
| AI 助手 / 客服 | **Agent** | 基于 LLM 的 AI 协同实体 |
| 展厅 / 前台 | **Socialware** | 面向特定场景的界面+路由+Agent 的组合 |
| 会员认证 / 权限 | **CapBAC** | 基于能力的访问控制 |
