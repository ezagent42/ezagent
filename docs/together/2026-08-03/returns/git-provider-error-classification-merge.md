# return(merge 记录)— Git provider 错误分类:PR #1668 已合 main

> **Task:** domain-git 错误 union 拆分 ——「读不懂的应答」与「provider 不可用」分类
> **PR:** [#1668](https://github.com/ezagent42/ezagent/pull/1668)(接替 #1661 —— base 分支随 #1653 合入被删、force-push 后 GitHub 拒重开;四轮 codex 对抗 review 记录在 #1661)
> **Dev:** gaga
> **merged_at:** 2026-08-03 09:31 +0800 · **merge SHA:** `4359f4a6e3a3278d5515fdcc567743a024069230`(已核在 `origin/main` 上)

## 合入内容

- **拆分 `:provider_response_unrecognized`(terminal,不重试)与 `:provider_unavailable`(retryable 残余桶)**。此前两者同装一个原子:provider 真挂(5xx/超时)该重试,而 provider 答了 2xx 但 body 解析不了(未知枚举/字段缺失或改名/形状不对)重试一万次结果一样 —— `Blocker` 统一判 retryable,导致 schema 漂移一路重试到 deadline、以 `:observation_incomplete` 误诊呈现。一个原子,不是三个:未知值/缺字段/形状不对导向同一动作。搬家面:GitHub adapter 16 处 + installation lookup 1 处;Forgejo normalize 10 处 + adapter 4 处 + 3 处 `@spec`。`:provider_unavailable` 保留给未分类 HTTP 状态、传输失败、dispatch 超时、分页上限(自身限制)。
- **停止编造"具体但错"的诊断**:base-sha-mismatch / head-ref-conflict / 缺失 `merged` 字段被当作 not-merged —— 这类情况现在诚实上报为 unreadable(terminal),不再给一个看似可操作、实则误导的结论。
- **关掉 Forgejo 在 PR-list 不可读时的重复建 PR**:列表应答读不懂 → 三态分类后不再落到"当不存在、重建一个"的路径。
- **修了三道形同虚设的防漂移 gate**(各自靠变异验证抓出):① `blocker_test` 的 union 完整性检查用字面复制的清单枚举(新成员直接飘过)→ 改读 typespec 严格提取 + 未知形状 `flunk`;② `Blocker.@type code` 与 `codes/0` 无人比对 → 补集合相等断言;③ Forgejo `map_error/3` 重写一切不认识的 marker、把 callee 已做好的分类丢弃 → 修掉(它曾让本次 adapter 迁移一度完全无效而全套测试仍绿);另补了此前零测试的分页上限。
- **文档**:冻结 union 的架构测试是更新不是绕过;V1-A / V1-B 规范原文不改,加指向 dated amendment 的前向指针(`docs/superpowers/specs/2026-07-31-git-provider-error-union-unreadable-response-amendment.md`)。

## 合并验证(机器闸)

- merge commit `4359f4a6e` 在 `origin/main`(本 return 写前已核 ancestry)。
- 终审验证(八轮对抗 review 收尾):`ezagent_domain_git` **170/0**、`ezagent_plugin_github` **170/0**、`ezagent_plugin_forgejo` **244/0**、`ezagent_plugin_git_workflow` **407/0**、`mix ci.fast` **697/0**,格式通过。
- 每处修复均做变异验证(改回去对应测试转红);三次变异未转红各暴露一个通过理由不对的测试,已分别修正(详见 #1661 讨论)。

## Follow-ups(已开 issue 跟踪,不阻塞)

- **#1662** —— 确定性 4xx(422 + 未分类状态)仍被判 retryable:「看懂了并拒绝」≠「读不懂」,未折进本原子,另案处理。
- **#1679** —— 剩余的类型可读性守卫:GitHub 四处 Git-data 应答的 `sha` 类型、installation lookup 的 `id` 类型、Forgejo 的 `full_name` 与 blob sha;同一条规则、不同站点,一起做更连贯。

## 不再引用

- 送审过程中提出的「PR 地址可推导、因而不携带 provenance 是设计缺口」的 X/Y 分析 —— 被 spec §6.2 文本推翻(head+base 即设计声明的 PR identity;provenance 要求只属于 ref),已在终审评论作废,未写入设计记录。
