# CIIA 机构真实数据 Seed 导入 · ruihua · 2026-07-23

**分支 / PR:** `docs/ciia-seed-data` → https://github.com/ezagent42/ezagent/pull/1534 · base `main`

## 演示了什么

- 从 CIIA 官网 (https://ciia-dipc.com) 2026-07-22 爬取的 14 个页面中，提取并结构化组织真实机构数据
- 文件位置：`docs/rh/ciia-demo/seed-data.js`（428 行）

## 怎么看

- 直接打开 `docs/rh/ciia-demo/seed-data.js` 阅读结构化数据
- 14 类数据包含：协会信息、42 家会员单位（已去重）、5 大服务（含描述和亮点）、6 份行业报告、4 个培训项目（含课程模块）、7 位专家、10 家评估机构、5 场会展活动、8 条新闻动态、8 款展厅产品 — 全部来自真实网站内容

```
CIIA_SEED
├── association         协会基本信息（定位/宗旨/使命）
├── contact             联系方式（地址/电话/邮箱）
├── departments[5]      组织架构（部门名称 + 职能描述）
├── services[5]         5 大服务（slug/名称/描述/亮点）
├── foundingOrgs[8]     发起单位
├── memberCompanies[42] 会员单位（已去重）
├── reports[6]          行业报告/白皮书/标准
├── trainingPrograms[4] 培训项目（含学时/对象/课程模块）
├── experts[7]          专家库
├── assessmentAgencies[10] 评估机构
├── maturityLevels[5]   评估成熟度等级 L1-L5
├── events[5]           会展/品牌活动
├── news[8]             新闻动态
├── showcaseProducts[8] 展厅产品（从会员优秀产品展厅提取）
└── _meta               数据溯源（爬取方法/时间/去重说明）
```

## 设计理由

- **数据格式选 JS 而非 JSON**：demo HTML 可直接 `<script src>` 引用，无需 fetch/parse；同时支持 Node `require`
- **会员单位 = 展厅占位策略**：42 家会员中仅 8 家在公共服务页有产品名露出，其余以公司名占位，等会员自行录入 — 与 content analysis 洞察 2（"展厅不空 + 倒逼会员录入"）一致
- **分类推断标待确认**：showcaseProducts 的行业分类（cat）基于业务推断，在 `_meta.notes` 中标注待协会确认
- **数据溯源内嵌**：`_meta` 记录了爬取方法（Playwright 无头 Chromium）、时间（2026-07-22）、页面数（14）、去重说明，方便后续追溯数据质量

## 对应本周目标

- 承接 CIIA 展厅 demo #1499（已合入）→ 后续步骤：机构真实 seed 数据导入
- Board card：机构 demo seed 导入（承接 CIIA #1499）

## 关联

- handoff: 无（独立设计交付，承接 #1499 后续步骤）
- 依赖：#1499（已合入）
