# Handoff: D2 — create_board 一次性 rule-authority 现状追认(记录型,零代码)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** Allen(备案+Decision Log)
> **Tracking:** 开工单 v2 终版 infra 清单 #7 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** confirmed(D2 Allen 已拍「选c 现状追认」;本文档=记录型 handoff,唯一动作是 doc 行 + Decision Log 条目)

## 0. Mission
普通成员(零 `create_agent` cap)经 chat/UI 建板,走 `BoardProvision.create_board` 内的**一次性 rule-authority**(只放行 passive data-host 的建宿主)。D2 拍板:现状追认,不改代码;把决策固化进 Decision Log,防后人当 bug「修」掉。

## 1. 现象/原因(备案)
- **现象层**:建板人常无 `create_agent` cap,却能建板(⑥ 已落:`feat(kanban): ⑥ 建板走一次性 rule-authority`,commit acd60dbbc)。
- **机制**:`BoardProvision.create_board/5`(domain_session board_provision.ex:62)cap-gated 建板+挂钥;建宿主用一次性 rule-authority 兜底,边界=建板人须本 session 成员 + 只造 `passive: true` recipe。
- **为什么追认而非收紧**:板是 passive 数据宿主(无 join、无自主行为),风险面≠通用 create_agent;收紧会把「人人可开板」的产品口径打断。

## 2. 动作清单(全部 docs/治理,无功能代码)
- [ ] `board_provision.ex` `create_board` moduledoc 加一行引用本决策(domain 文件的纯注释行,随任一 infra PR 捎带,**不进 PR-K**)
- [ ] Allen 补 GLOSSARY.md Decision Log 条目(编号待分配):「kanban create_board 一次性 rule-authority——只放行 passive data-host,边界:session 成员 + passive:true」
- [ ] doc.scan 过

## 3. 红线(不放宽)
建板人须本 session 成员;只造 `passive: true` recipe;rule-authority 不外溢到任何非-建板路径。

## 4. Required reading
`docs/together/2026-07-16/handoffs/allen-decisions.md` §D2;commit `acd60dbbc`。
