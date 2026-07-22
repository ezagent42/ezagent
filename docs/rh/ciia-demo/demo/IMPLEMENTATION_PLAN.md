# CIIA 完整 Demo · 实施计划

## 架构决策

### 每个页面 = 一个 Socialware

```
Socialware = 内容区（Content Body）+ 底部对话（Hello Builder Dialog）
```

| Socialware | 内容类型 | Hello Builder Agent | Agent 角色 |
|:--|:--|:--|:--|
| 产品展厅 | 搜索 + 产品卡片网格 | 展厅顾问 + 匹配助手 | 已有（browse chat） |
| 关于协会 | 文本 + 卡片（介绍/组织/成果） | 协会咨询 Agent | 回答协会相关问题 |
| 入会申请 | 表单（企业信息） | 入会引导 Agent | 引导填写、解答入会条件 |
| 行业研究院 | 报告列表 + AI 洞察 | 行业洞察 Agent | 推荐报告、回答行业趋势 |
| 合作对接 | 合作需求卡片 | 合作匹配 Agent | 匹配合作方、发起对接 |
| 会员专区 | Tab 切换（产品/Session/资料） | 会员助手 Agent | 帮助管理产品 |
| 管理后台 | 统计卡片 + 审核列表 | 运营助手 Agent | 辅助审核决策 |

### 侧边导航分组

```
🏛 信息协会

公开
├── 🏛 产品展厅
├── 📋 关于协会
├── ✍️ 入会申请
├── 📊 行业研究院
└── 🤝 合作对接

会员（登录后可见）
└── 👤 会员专区
    ├── 我的产品
    ├── 客户 Session
    └── 企业资料

管理（管理员角色可见）
└── ⚙️ 管理后台
```

### Hello Builder 对话框（通用组件）

每个 socialware 底部有一个统一的 chat dialog：
- **折叠态**：圆角 pill "💬 [Agent 名称]"
- **展开态**：消息区 + 输入框 + 发送按钮
- Agent 首条消息为 greeting
- Agent 回复为预设脚本（mock LLM）

### 技术实现

- **视图切换**：与现有架构一致——所有视图 absolute 定位，通过 CSS class toggle
- **Chat 复用**：每个 socialware 的 chat 用同一个 JS 组件，通过参数区分 agent 名称/greeting/mock 回复
- **消息隔离**：`socialwareMessages = { showroom, about, join, research, partner, member, admin }`
- **内容页**：用内联 HTML 构建（JSON-spec 风格），与 json-render 对齐

## 实施步骤

### Step 1: CSS（~150 行新增）
- [x] 侧边导航分组样式
- [ ] Socialware view 基础样式
- [ ] Hello Builder dialog 样式（折叠/展开/消息/输入）
- [ ] 内容页组件样式（信息卡/表单/列表/统计卡）

### Step 2: HTML（~300 行新增）
- [ ] 分组侧边导航
- [ ] 6 个 socialware view div
- [ ] 每个 view 内的内容区 + Hello Builder dialog

### Step 3: JS（~400 行新增）
- [ ] Socialware 定义表
- [ ] Hello Builder chat 组件（通用）
- [ ] 导航切换逻辑（含分组展开/折叠）
- [ ] 登录-角色联动（会员/管理员可见性）
- [ ] 各 socialware 的 mock 内容和交互

### Step 4: 联调验证
- [ ] 所有导航切换正常
- [ ] 每个 socialware 的 dialog 独立工作
- [ ] 登录态控制导航显隐
- [ ] 从产品展厅到 Session 再返回的链路
