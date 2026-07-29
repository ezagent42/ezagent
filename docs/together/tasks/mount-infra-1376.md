# #1376 通用挂载 infra（被 entity-caps 取代 · 保留）

- **id**: `mount-infra-1376`
- **owner**: jjkysy
- **status**: wip(draft · 保留)
- **历史**: started 2026-07-24 · est_done 2026-07-29 · actual —
- **关联**: PR #1376(draft)

## 目标
挂载表 + Mount API + reconcile（契约留用）。

## 验收
- [ ] 被 entity-caps 去中心化模型取代、转 draft；API/测试/kanban 契约留用（显式保留）

## Handoff prompt

> 本任务**已被 entity-caps 去中心化权限模型取代**——不是要继续主动开发这套通用挂载
> infra（挂载表 + Mount API + reconcile）本体。
>
> SCOPE 仅限「保留」，不是「推进」：
> 1. 确认 PR #1376 保持 draft 状态（不合入 main 作为正式实现）。
> 2. 其中已经写出的 API 签名、测试用例、kanban 契约（下游代码对这套挂载 infra 的调用
>    约定）**显式保留**，不删除、不因为「被取代」就清理掉——因为下游 kanban 代码目前
>    还在依赖这些契约，entity-caps 模型接管后需要一个平滑过渡，契约留用是过渡期的
>    安全网。
> 3. 如果 entity-caps 模型的推进过程中发现契约本身有过时/冲突之处，标注出来但不要
>    单方面改契约——升级路径由 entity-caps 主线（Allen 轨道）统筹。
>
> 换句话说：本卡是「维护性保留」而非「继续构建」，做的是确认+标注，不是新功能开发。
