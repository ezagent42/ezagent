# MFU 版本目录与多角色 Demo 设计

## 目标

本轮完成两项相互依赖的工作：

1. 按完整游戏版本整理 `mfu-demo`，把常青文档、待决策问题和独立功能性 Demo 分开；
2. 从组织牧场 v0.2 派生 v0.3，在同一套游戏架构中加入四份角色档案、共享世界和游戏外角色控制器。

目录整理必须先完成，v0.3 不得继续在当前混合目录中堆叠文件。

## 总体原则

- 完整游戏 Demo 仅按版本号归档；
- 不再区分 `classic` 和 `organization-pasture` 产品线；
- Card Array 是独立的功能性教学 Demo，不纳入完整游戏版本；
- `living-docs` 只保存跨版本持续维护的单一事实源；
- 待决策问题单独保存，不得混入 living docs；
- 旧版本只调整位置和失效引用，不修改其机制内容；
- v0.2 是当前组织牧场快照；
- v0.3 是多角色共享世界版本；
- 核心游戏功能只有一份实现，角色差异由数据档案提供。

## 目标目录

```text
mfu-demo/
├── README.md
├── index.html
│
├── living-docs/
│   ├── platform-concept-model.md
│   └── skill-tree.md
│
├── pending-decisions/
│   ├── README.md
│   ├── 组织、多重成员关系与跨组织调度.md
│   └── MFU-v0.2-迁移待决策.md
│
├── concept-demos/
│   └── card-array/
│       ├── README.md
│       ├── demo/
│       │   └── MFU-协作阵列-v0.1-可玩原型.html
│       ├── docs/
│       │   ├── core-gameplay-card-array.md
│       │   └── student-opc-lifecycle-roadmap.md
│       └── tests/
│           ├── test-card-array-v01.mjs
│           └── card-array-v01.browser.cjs
│
└── versions/
    ├── v0.1/
    │   ├── demo/
    │   │   └── MFU-MVO孵化总览-v0.1-可玩原型.html
    │   └── tests/
    │       ├── test-mvo-incubator-v01.mjs
    │       └── mvo-incubator-v01.browser.cjs
    │
    ├── v0.2/
    │   ├── demo/
    │   │   └── MFU-MVO组织牧场-v0.2-可玩原型.html
    │   ├── docs/
    │   │   └── MFU-v0.15到组织牧场-v0.2-迁移清单.md
    │   └── tests/
    │       ├── test-mvo-pasture-v02.mjs
    │       └── mvo-pasture-v02.browser.cjs
    │
    ├── v0.13/
    │   ├── demo/
    │   │   └── MFU-v0.13-可试玩原型.html
    │   └── docs/
    │       ├── MFU-策划案-GDD-v0.13.md
    │       ├── flywheel-audit-v0.13.md
    │       ├── gap-analysis-v0.13.md
    │       └── happy-paths-v0.13.md
    │
    ├── v0.14/
    │   ├── demo/
    │   │   └── MFU-v0.14-可试玩原型.html
    │   └── docs/
    │       └── MFU-策划案-GDD-v0.14.md
    │
    ├── v0.15/
    │   ├── demo/
    │   │   └── MFU-v0.15-可试玩原型.html
    │   ├── docs/
    │   │   └── MFU-策划案-GDD-v0.15.md
    │   ├── infographics/
    │   └── role-pages/
    │
    └── v0.3/
        ├── demo/
        │   └── MFU-多角色组织世界-v0.3.html
        ├── role-profiles/
        │   ├── incubator.js
        │   ├── school.js
        │   ├── enterprise.js
        │   └── student.js
        ├── docs/
        │   └── multi-role-design.md
        └── tests/
            ├── test-multi-role-v03.mjs
            └── multi-role-v03.browser.cjs
```

## 文件迁移规则

### 常青文档

```text
doc/platform-concept-model.md
→ living-docs/platform-concept-model.md

doc/skill-tree.md
→ living-docs/skill-tree.md
```

`platform-concept-model.md` 在搬迁后基于 v0.2 更新。已确认内容写入概念模型，组织与多重成员关系只记录为待决策链接。

### 待决策问题

```text
doc/pending-decisions/*
→ pending-decisions/*
```

待决策文件不属于特定版本，也不属于 living docs。

### Card Array 功能性 Demo

```text
MFU-协作阵列-v0.1-可玩原型.html
doc/core-gameplay-card-array.md
doc/student-opc-lifecycle-roadmap.md
test-card-array-v01.mjs
card-array-v01.browser.cjs
→ concept-demos/card-array/
```

`student-opc-lifecycle-roadmap.md` 在这里作为 Card Array 教学机制的演进背景保存，不再作为平台常青路线图。

### 完整游戏版本

所有带完整版本号的游戏 Demo、GDD、信息图、角色页面和对应测试进入 `versions/<version>/`。

`role-pages` 属于 v0.15 的订单全生命周期解释页面，进入 `versions/v0.15/role-pages/`。

### 根目录入口

根目录只保留：

- `README.md`：解释目录、版本和打开方式；
- `index.html`：列出最新版本、历史版本、Card Array 教学 Demo 和常青文档。

旧的 `gdd.html` 根据内容归入其对应版本；如果只是旧入口，则由新版 `index.html` 替代。

## 链接兼容

目录迁移会改变 Tailscale 和本地文件路径，不保留重复 HTML 副本。

通过以下方式降低影响：

- 根 `index.html` 提供所有新入口；
- 更新 Markdown、HTML 和测试中的相对引用；
- PR 和群消息统一改发根入口；
- 迁移清单记录旧路径与新路径；
- 所有 HTML 必须能通过 `file://` 和现有静态服务器直接打开。

## Living docs 更新边界

### 平台概念模型

更新 `living-docs/platform-concept-model.md`，反映 v0.2 已实现的概念：

- 我的工作台；
- 世界；
- 市场订单；
- 已承接订单；
- 订单生命周期；
- MVO 与组织图；
- 节点级执行；
- 节点外包订单；
- 人才、Agent、工具/IP、算力、资金；
- 待处理；
- 组织交付、结算与成长；
- 多角色使用相同游戏结构；
- 共享世界与角色独立工作台。

尚未确认的以下内容不得写成正式规则：

- 长期组织与 MVO 的最终关系；
- 多重成员关系；
- 跨组织调度权；
- 成员授权额度；
- 跨组织成果和收入归属。

概念模型只链接到 `pending-decisions/组织、多重成员关系与跨组织调度.md`。

### 技能树

`living-docs/skill-tree.md` 保留为成长体系的单一事实源。增加一段范围说明：

- 技能树描述能力成长；
- 不负责定义全部订单、市场和组织机制；
- 组织牧场与多角色世界通过引用使用它；
- 未经新决策，不重写既有已批准框架。

## v0.3 多角色架构

### 一套游戏架构

v0.3 从 v0.2 复制产生，但复制后只有一份核心页面和交互逻辑。

四个角色不是四份 HTML，而是四份数据档案：

```text
ROLE_PROFILES
├── incubator
├── school
├── enterprise
└── student
```

每份档案提供：

- 身份名称和副标题；
- 声望、资金、算力；
- 订单板；
- MVO；
- 人才、Agent、工具/IP；
- 待处理；
- 办公室内容；
- 世界推荐行业；
- 初始故事状态。

### 四个角色

#### 孵化器运营者

核心目标：把学生、创业团队、教练和 Agent 孵化成能够持续接单的 MVO。

#### 学校创新创业课程负责人

核心目标：让跨专业学生通过课余真实任务形成创业能力和学生 MVO。

具体教师作为任务发布者、评价者或指导资源出现。

#### 企业创新负责人

核心目标：把员工、专家、Agent、数据和 IP 组合成高效的项目 MVO。

#### 学生创业者

核心目标：从完成局部任务开始，积累能力、伙伴和组织资产，逐渐成长为 OPC。

身份显示为：

```text
学生创业者
正在成长为 OPC
```

## 共享世界

四个角色共享：

- 市场订单；
- 世界动态；
- 新闻与公告；
- 公开组织状态；
- 跨角色发布与承接记录。

每个角色独立保存：

- 订单板；
- MVO；
- 资源；
- 资金、算力和声望；
- 待处理；
- 履约和成长记录。

跨角色示例：

```text
企业发布订单
→ 学校或孵化器承接
→ 学生完成其中一个节点
→ 孵化器提供 Agent 或教练
→ 企业验收和付款
```

## 世界筛选

第一项固定为`推荐`，不是`适合我的`。

筛选按行业领域和任务性质，不按发布者角色分类：

```text
推荐
全部
教育与校园
消费与零售
内容与品牌
软件与 AI
社会创新
节点外包
我发布的
```

`节点外包`和`我发布的`是任务状态快捷筛选，不代表平台给用户分类。

每张订单包含：

- 行业领域；
- 任务标签；
- 所需能力；
- 难度；
- 预算与截止；
- 推荐角色或资源条件；
- 发布组织；
- 来源节点（如果存在）。

推荐首版使用固定规则排序，不实现复杂匹配算法。用户始终可以切换到`全部`。

## Demo 角色控制器

角色控制器位于游戏画面之外，使用中性灰色视觉，与游戏羊皮纸 UI 明显区分。

显示：

```text
DEMO 视角：[孵化器运营者 ▼]  重置当前角色
```

并明确说明：

```text
仅用于演示不同用户视角。正式产品根据登录身份进入对应工作台。
```

支持：

- 孵化器运营者；
- 学校课程负责人；
- 企业创新负责人；
- 学生创业者；
- 重置当前角色；
- 重置全部演示，二次确认。

切换角色时：

1. 保存当前角色；
2. 保留共享世界；
3. 加载目标角色；
4. 替换身份、订单、组织、资源、待处理和办公室；
5. 保持当前位于“我的工作台”或“世界”；
6. 显示当前演示视角提示。

## URL 与本地存档

独立分享链接：

```text
?role=incubator
?role=school
?role=enterprise
?role=student
```

无参数时默认 `incubator`。

存档键：

```text
mfu-v03-world
mfu-v03-role-incubator
mfu-v03-role-school
mfu-v03-role-enterprise
mfu-v03-role-student
mfu-v03-active-role
```

URL 参数决定首次进入视角。页面内切换角色后更新 URL，但不刷新页面。

## 组织概念的暂缓范围

v0.3 可以展示：

- 相同的人可能出现在多个角色视角中；
- 学生可以参与多个 MVO；
- 学校、孵化器和企业可以共同参与一次交付；
- 学生能看到自己的工作台和共享世界。

v0.3 暂不实现：

- 长期组织的完整管理页面；
- 多组织成员邀请和退出；
- 跨组织排期授权；
- 学生时间额度；
- 学校与孵化器共同调度冲突；
- 跨组织权限和隐私；
- 收入、作品和 IP 的复杂分配。

这些问题统一由 `pending-decisions/组织、多重成员关系与跨组织调度.md` 承接。

## 验收标准

### 目录

- `mfu-demo` 根目录不再散落版本 HTML 和测试；
- 完整游戏按版本号归档；
- Card Array 独立可打开；
- living docs 只有平台概念模型和技能树；
- 待决策文件独立；
- 所有内部链接有效；
- 根入口可以访问全部主要产物。

### 多角色

- 四个角色使用同一份游戏实现；
- 四份角色档案内容明显不同；
- 角色切换不刷新页面；
- 各角色工作台存档互不污染；
- 共享世界在角色切换后保持一致；
- 企业发布的订单可被其他角色看到和承接；
- 世界支持推荐与行业筛选；
- 四种 `?role=` 链接可直接打开；
- 重置当前角色不会清空共享世界；
- 重置全部演示需要确认；
- v0.2 原有订单、MVO、节点外包、结算和成长流程仍可完成；
- 页面保持满屏自适应，底部栏固定，角色切换不产生布局漂移。
