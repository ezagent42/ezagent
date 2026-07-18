# Handoff: D4 — 跨 workspace 口径:只读放开 + operate 先验租户隔离(记录型)

> **Date:** 2026-07-18 · **From:** kanban-collab-round2 线 · **To:** Allen(备案)+ PR-K 实施者
> **Tracking:** 开工单 v2 终版 infra 清单 #8 · **Base:** `origin/main` @ `d533a5d73`
> **Status:** confirmed(D4 Allen 已拍「只读放开+先验租户隔离」;实现落点经 file 级重切**在 PR-K**,infra 侧零改动——本文档备案不变量)

## 0. Mission
统一两条分享路的跨 ws 口径:**只读分享(read keys)跨 workspace 放开;operate/写类钥匙永不跨 workspace**(先验租户隔离不变量)。

## 1. 现状(现读锚点)
- `forward_board` 有 `same_workspace` 硬守卫(domain_session board_provision.ex:267,:292 → `:cross_workspace_denied`)——**保持不动**(它发的是会话转发钥匙,含 operate 语义空间)。
- 链接分享路(ShareReceive)现状零 ws 检查——人本位重做(㊵)时收成**单一 ws policy 函数**,默认放开 read。

## 2. 切分与落点
| 半件 | 落点 | 归属 |
|---|---|---|
| ws policy 单守卫函数(read 放开) | kanban `share_receive.ex`(plugin 文件) | **PR-K**(㊵ 任务内) |
| `forward_board` same_workspace 守卫保持 | domain_session board_provision.ex | infra,**零改动**(不变量备案) |
| forward 定位复裁(分享二期后降为 assistant 增强,去留并裁) | 二期 | PR-K 分享二期项,若触 domain 另提 handoff |

## 3. 不变量(红线,进 Decision Log 候选)
1. **operate/写类钥匙永不跨 ws**——任何路径(mount/forward/join 补发/规则8 升级)都不得给跨 ws 主体铸 operate 钥匙。
2. 放开的只有 read(H4 read keys:`[:get_tree, :export_markmap]` 家族)。
3. 规则8(read→operate 升级)必须在升级点复查同 ws——升级不是绕过不变量的后门。

## 4. 验收(在 PR-K 侧勾,此处登记)
- 跨 ws 链接点击 → 板出现在点击者 tab(只读)——两账号两 ws agent-browser e2e。
- 跨 ws operate 仍 `:cross_workspace_denied`——单测反例。

## 5. Required reading
`docs/together/2026-07-16/handoffs/allen-decisions.md` §D4;`docs/notes/2026-07-17-xy-review.md` §1-③。
