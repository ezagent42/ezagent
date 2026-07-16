# 工程效率分析:session 推断工时(近 8 周基线)

> 2026-07-15/16。方法与聚合结果;度量工具已沉淀为
> `.claude/skills/dev-together/scripts/pr_session_hours.py` 并接线进
> `dev-together review`(每日/周窗口)。

## 为什么需要这个度量

人类+agent 混合开发下,没有人能(也不会)人工估计每个变更的复杂度或投入;
PR lead-time 又混入 review 等待与并发空转,不能当工时
(`docs/together/2026-06-25/stats/cycle-data.md` 已明示 lead_time ≠ hours-of-coding)。
commit 作者时间戳是唯一**零人工配合**的投入信号。

## 方法(git-hours 惯例)

- squash-merge 会抹掉 main 上的分支历史,但 GitHub API `pulls/{n}/commits`
  保留原始 commit 的 author date——按作者聚类这些时间戳;
- 相邻间隔 ≤120 分钟串成一个 session;session 时长 = 组内间隔和 + 每
  session 补 30 分钟(近似首 commit 前的未记录工作);
- 按 sha 去重(stacked PR 重复计一次)。

## 近 8 周聚合结果(2026-05-20 → 2026-07-15,@ eb2b56a88)

| 项 | 值 |
|---|--:|
| 扫描 merged PR | 1053(零失败) |
| 唯一分支 commit | 3248 |
| 活跃小时合计(下界) | 983.1 h |
| 折 160h 工程人月 | 6.14 |
| 月均(全体,人+agent 墙钟) | ≈3.3 人月/月 |
| 其中 agent 身份(按提交邮箱域聚合) | ≈549 h(56%) |
| 其中人类身份 | ≈434 h(44%,≈1.35 人月/月) |

## 读数纪律(引用数字时必须随附)

1. **这是下界**:commit 之间才被计时;思考/设计/review/会议不可见。
   git-hours 类方法对人类的典型低估 2-3×——人类可见 1.35 人月/月对应的
   真实工程投入估计在 2.5-4 人月/月。
2. **agent 行是 agent 墙钟,不是人力成本**;与人类小时不可直接相加解读。
3. 度量范围只有本仓库 merged PR;rebase 改写 author date 会压缩 session。
4. **禁止用于个人绩效**——本度量只服务聚合层面的效率与产能口径校准。

## 近 8 周工程投入结构(commit 主题分类,条数占比 ≠ 工时)

| 类别 | 估计占比 | 说明 |
|---|--:|---|
| 产品化(通用能力/模板/自助/UI/测试自动化) | ~45%(区间 40-65%) | feat+test 非 demo 部分;近期切片(deploy-seed、skill 分发、DeliveryQueue、socialware 卸载等)全为多客户可复用 |
| 稳定性/维护/返工 | ~27% | fix 231 + refactor 63 等;三次部署失败催生 reflow_rehearsal CI 闸 |
| 流程/文档留痕 | ~25% | dev-together 每日 plan/handoff/return/review |
| demo/站点专用 | ~3-5% | website/官网 hello |

## 持续采集

- 每日 `dev-together review` 第 2 步跑当日窗口,周五加跑周窗口
  (见 `commands/review.md`);
- 用法:`uv run python .claude/skills/dev-together/scripts/pr_session_hours.py <owner/repo> "<merged: 窗口>"`,
  输出 JSON(总小时/人月折算/明细),`--paginate` 自动处理,窗口撞 1000 上限会告警。
