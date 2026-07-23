# CIIA 完整 Demo 交付 · ruihua · 2026-07-22

**分支 / PR:** `docs/ciia-demo` → [PR #1499](https://github.com/ezagent42/ezagent/pull/1499) · base `main`

## 演示了什么

从 v3 产品展厅 demo 扩展为包含 **6 个 socialware + Hello Builder 对话框 + Session 收件箱** 的完整 CIIA 平台 demo。

### 文件位置

| 文件 | 说明 |
|:--|:--|
| `docs/rh/ciia-demo/demo/index.html` | 完整 demo（1430 行） |
| `docs/rh/ciia-demo/demo/IMPLEMENTATION_PLAN.md` | 实施计划 |
| `docs/rh/ciia-demo/platform-analysis.md` | 产品架构分析框架 |
| `docs/rh/ciia-demo/ciia-content-analysis.md` | CIIA 网站爬取 + Gap 分析 |
| `docs/rh/ciia-demo/PORTABILITY.md` | 移植手册（下一个机构怎么做） |
| `docs/rh/ciia-demo/resources/` | CIIA 网站爬取原始数据 |

### 怎么看

```bash
cd docs/rh/ciia-demo/demo && python3 -m http.server 8888
# → http://localhost:8888/index.html
```

已部署到 http://100.64.0.17:8888/index.html

## 新增内容

### 架构层面

| 新增 | 说明 |
|:--|:--|
| **Session ≠ Socialware 澄清** | Session 是平台级通信原语，不是某个 socialware 的子页面。放在侧边栏个人区，所有 socialware 的对话收束于此 |
| **Socialware 框架** | 每个页面 = 内容区 + Hello Builder 对话框，6 个 socialware 共享同一套 chat 组件 |
| **分组侧边导航** | 公开 / 会员 / 管理 / 个人 四层，登录态控制显隐 |
| **移植手册** | `PORTABILITY.md`：下一个机构按 6 步操作，半天内出定制 demo |

### 6 个 Socialware

| Socialware | 内容 | Hello Builder Agent |
|:--|:--|:--|
| 产品展厅 | 搜索 + 产品卡片 + 录入（已有） | 展厅顾问 + 匹配助手 |
| 关于协会 | 统计卡片 + 定位/宗旨/使命/组织架构 | 协会咨询 Agent |
| 入会申请 | 条件/权益卡片 + 4 字段表单 | 入会引导 Agent |
| 行业研究院 | 4 篇报告/白皮书列表 | 行业洞察 Agent |
| 合作对接 | 4 张合作需求卡片 | 合作匹配 Agent |
| 会员专区 | 3 tab（产品/Session/资料） | 会员助手 Agent |
| 管理后台 | 统计卡片 + 产品审核 + 入会审核 | 运营助手 Agent |

## 设计理由

- **Session 不放侧边栏 socialware 列表**：Session 是收件箱，不是目的地。放个人区语义更准——用户心理模型是"去了展厅 → 联系企业 → 去我的 Session 看回复"
- **Hello Builder 对话框复用**：6 个 socialware 用同一套 `.hello-bar` CSS/JS，通过 `sw` 参数区分。新增一个 socialware 只需加 greeting + replies，CSS/HTML/JS 零改动
- **内容直接用 CIIA 真实数据**：协会介绍、成果数据、组织架构、报告标题全部来自 ciia-dipc.com 爬取，保证给协会看的是他们自己的内容
- **移植手册独立成文**：`PORTABILITY.md` 写明了 18 项替换清单 + 6 步操作 + 预估 2.5-3.5 小时工时。CIIA 花了 ~2 天从零做，下一个机构半天

## 已知 Gap

- [ ] 侧边栏导航未来改为 hello builder 对话式导航（不做传统 SaaS 左侧栏）
- [ ] CIIA 网站爬取的会员名录（50 家）尚未作为展厅 seed data 导入
- [ ] 移动端未精细优化（基础响应式可用）
- [ ] 无真实后端 / LLM / 认证

## 对应本周目标

- 看板卡：★ 设计信息协会 demo 方案（0/1 → 实质完成）
- 看板卡：企业自助开通产品化 + demo socialware（#1436 #1419 #1388）

## 关联

- handoff: off-plan 设计工作（信息协会 demo 独立设计迭代，PR #1499）
