# Demo 移植手册：从 CIIA → 下一个机构

> 当另一个机构（软件协会、医疗联盟、产业园区…）找我们做 demo 时，
> 以 CIIA demo 为起点，按本文档操作即可。

---

## 1. 核心原则

**CIIA demo 是 ezagent 的 demo 模板，不是 CIIA 的定制项目。**

整个 demo 的架构设计就是为了可移植：socialware 框架、Session 引擎、Hello Builder 对话框、Bento 设计系统 —— 这些都是 ezagent 通用的。CIIA 的部分只有内容、品牌、和业务逻辑。

---

## 2. 移植清单：改什么 / 不改什么

### 2.1 完全不改（ezagent 平台层）

| 模块 | 文件位置 | 说明 |
|:--|:--|:--|
| **Session 引擎** | `openSessionView()` / `createAndEnterSession()` / `sendSessionMsg()` | 所有对话创建、投递、展示 |
| **Hello Builder 对话框** | `.hello-bar` + `toggleHello()` / `sendHelloMsg()` | 每个 socialware 的底部 Agent 对话 |
| **搜索匹配引擎** | `matchProducts()` / `handleQuery()` | 产品搜索和评分逻辑 |
| **Bento 设计系统** | `:root` tokens + `.pg-card` / `.sw-view` / `.sidebar` | 圆角/阴影/间距/配色 |
| **View-switching 架构** | `switchView()` + CSS class toggle | 所有视图切换逻辑 |
| **登录框架** | `currentUser` / `updateLoginUI()` / localStorage | 身份和持久化 |
| **Toast / Modal** | `showToast()` / overlay 组件 | 全局反馈 |

### 2.2 内容替换（逐项改）

| 替换项 | CIIA 当前值 | 新机构要改成 | 涉及文件 |
|:--|:--|:--|:--|
| **品牌名称** | 信息协会 / CIIA | 新机构名称 + 缩写 | `index.html` 全局搜索替换 |
| **Logo** | 协会 SVG icon | 新机构 Logo | `.sb-icon` SVG |
| **域名** | `ciia.ezagent.chat` | 新机构二级域名 | 部署配置 |
| **Hero 标题** | 会员产品展厅 · Product Showroom | 新机构展厅名称 | `<h1>` |
| **副标题** | 描述您的需求… | 适配新机构话术 | `.sub` |
| **产品数据 (seed)** | `PRODUCTS` 数组（10 条 mock） | 新机构的真实/模拟产品 | JS 中 `PRODUCTS` |
| **产品分类** | 医疗健康/数据智能/AI安全治理/智能办公/智能制造/行业研究 | 新机构的行业分类 | `cat` 字段 + `ALL_CATS` |
| **会员名录** | ~50 家企业名称 | 新机构的会员名单 | 从爬取数据替换 |
| **关于协会内容** | CIIA 定位/宗旨/使命/组织架构 | 新机构的介绍 | `#aboutView` HTML |
| **入会条件/权益** | CIIA 的入会文案 | 新机构的入会规则 | `#joinView` HTML |
| **行业报告列表** | CIIA 的报告标题 | 新机构的内容资产 | `#researchView` HTML |
| **合作需求卡片** | AI医疗数据/金融渠道/数据中台/IoT | 新机构的合作场景 | `#partnerView` HTML |
| **管理后台数据** | 会员数/产品数/Session数 | 新机构实际数据 | `#adminView` HTML |
| **成果数据** | 20+PB / 5000+企业 / 1000+培训… | 新机构的数据 | `.sw-stat-grid` |
| **联系方式** | 潘老师/周老师 电话 | 新机构联系人 | 关于协会 + footer |
| **友情链接** | 发改委/国家数据局/工信部 | 新机构的关联方 | footer |

### 2.3 结构保留/调整

| 结构项 | 是否保留 | 说明 |
|:--|:--|:--|
| 侧边导航分组（公开/会员/管理/个人） | ✅ 保留 | 分组框架通用 |
| 产品展厅 | ✅ 保留 | B2B 展厅是通用场景 |
| 关于协会 | ✅ 保留 | 每个机构都有"关于" |
| 入会申请 | ⚠️ 按需 | 如果新机构不需要入会流程，可替换为其他 socialware |
| 行业研究院 | ⚠️ 按需 | 如果新机构没有内容资产，可替换 |
| 合作对接 | ⚠️ 按需 | 通用 B2B 场景，通常保留 |
| 会员专区 | ✅ 保留 | 登录后的个人面板通用 |
| 管理后台 | ⚠️ 按需 | 仅当新机构有内部管理需求 |
| 我的 Session | ✅ 保留 | 平台级原语，所有机构都需要 |

### 2.4 可新增的 socialware

根据新机构的业务特点，可在侧边栏新增 socialware：

| 常见场景 | 示例 | 复用模板 |
|:--|:--|:--|
| 活动/峰会报名 | 年度行业峰会注册 | 参考 `#joinView` 表单模式 |
| 项目申报 | 科技项目在线申报 | 参考 `#joinView` 表单 + Agent 引导 |
| 人才招聘 | 会员企业招聘广场 | 参考 `#partnerView` 卡片模式 |
| 在线课程 | 行业培训课程库 | 参考 `#researchView` 列表模式 |
| 融资对接 | 创投撮合 | 参考 `#partnerView` + Session |

---

## 3. 操作步骤（按顺序）

### Step 1: 爬取新机构网站

```bash
# 用 web-crawler skill 爬取，产物放到 docs/rh/<org>/resources/
# 爬完后写 ciia-content-analysis.md 的对等文档
```

### Step 2: 复制 CIIA demo 作为起点

```bash
cp -r docs/rh/ciia-demo/demo docs/rh/<new-org>/demo
```

### Step 3: 全局替换品牌名

```bash
# 在 index.html 中
查找: 信息协会     → 替换为 新机构名
查找: CIIA        → 替换为 新缩写
查找: ciia        → 替换为 新缩写（小写，用于 localStorage key）
查找: 数据智能专业委员会 → 新机构的完整名称
```

### Step 4: 替换内容（按 §2.2 清单逐项）

1. 替换 `PRODUCTS` 数组 → 从新机构网站/会员名录提取
2. 替换 `ALL_CATS` → 新机构的行业分类
3. 替换 `#aboutView` HTML → 新机构的定位/宗旨/组织
4. 替换 `#joinView` HTML → 新机构的入会条件/权益
5. 替换 `#researchView` HTML → 新机构的报告/白皮书
6. 替换 `#partnerView` HTML → 新机构的合作场景
7. 替换 `#memberView` / `#adminView` → 按需调整
8. 替换成果数据 → 从新机构网站提取（如有）
9. 替换联系方式

### Step 5: 调整 Socialware 配置

- 每个 socialware 的 Hello Builder Agent `helloGreetings` + mock `replies` 改成新机构的话术
- 调整侧边栏分组（增删 socialware 导航项）

### Step 6: 联调 + 部署

```bash
cd docs/rh/<new-org>/demo
python3 -m http.server 8888
# 浏览器验证所有页面、所有 hello builder 对话框、Session 流程
```

---

## 4. 预估工时

| 步骤 | 内容 | 预估 |
|:--|:--|:--|
| Step 1 | 爬取 + 内容分析 | 30 min |
| Step 2-3 | 复制 + 全局替换 | 10 min |
| Step 4 | 内容替换（取决于复杂度） | 1-2 h |
| Step 5 | Socialware 调整 | 30 min |
| Step 6 | 联调 + 部署 | 20 min |
| **合计** | | **2.5-3.5 h** |

> CIIA 从零到完整 demo 花了 ~2 天。下一个机构用这套模板，**半天内可以出一个完整的定制 demo**。

---

## 5. 移植时不变的东西（写死在这里，防止误改）

| 不改的 | 原因 |
|:--|:--|
| Session 创建/投递逻辑 | ezagent 平台原语 |
| `matchProducts()` 搜索评分 | 跨机构通用 |
| Hello Builder 对话框的 CSS/JS 框架 | 跨 socialware 通用 |
| Bento design tokens (`:root` 变量) | ezagent 品牌 |
| View-switching 架构 | 框架层面 |
| `currentView` / `switchView()` | 框架层面 |
| 侧边栏布局（sidebar + main-content） | 框架层面 |
| Toast / Modal 组件 | 框架层面 |
| `escapeHtml()` / `sleep()` | 工具函数 |
