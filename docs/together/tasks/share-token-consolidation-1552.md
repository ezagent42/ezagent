# #1552 签名-token 分享收敛（clarify_first 设计提案）

- **id**: `share-token-consolidation-1552`
- **owner**: Allen 轨道（设计）→ jjkysy（实现，待确认后）
- **status**: planned
- **历史**: started 2026-07-28 · est_done 2026-07-29 · actual —
- **关联**: #1552

## 目标
`DownloadToken` 从 uploads-only 泛化到任意 target URI，消掉 kanban 侧平行造的分享实现
（与 Group-A URI 通用分享 `group-a-uri-share` 是相关但不同的两条分享线——那条是新造
URI-share 机制，这条是把既有 `DownloadToken` 泛化；两者收敛关系待本任务的 DoD 厘清）。

## 验收
- [ ] 写 DoD 回答 5 个设计问题：
  1. target scheme — 泛化后 token 的 target 用什么 URI scheme 表达（是否复用
     `group-a-uri-share` 同一套，还是独立命名空间）
  2. mint 授权口径 — 谁能对什么 target mint 一个分享 token（对齐 M1：token 必须绑定
     issuer 且验证 issuer 持有可委托权限，同 group-a-uri-share 的 codex 发现）
  3. `kanban.share_board` 归宿 — kanban 现有的平行分享实现是废弃、迁移、还是保留
     兼容层
  4. person-binding 语义 — 分享是绑定到具体人（claim 后归属谁）还是匿名可转让
  5. message-share 是否纳入本批
- [ ] DoD 确认后交给 jjkysy 实现

## Handoff prompt

> `clarify_first` 设计任务（不是 build 任务）：这是一个 discuss-first 触发的场景——
> 现状是 `DownloadToken` 只服务 uploads 场景，kanban 又平行造了一套自己的分享实现
> （`kanban.share_board`），两者语义重叠但不统一；同时 `group-a-uri-share` 任务正在
> 造一套新的 URI-share 机制（bearer token + claim + caps_toward + CompositionConsent
> 超集）。在动手泛化 `DownloadToken` 之前，必须先写清楚 DoD，否则会造出第三套平行
> 实现。
>
> 产出一份 DoD 文档，逐条回答：
> 1. **target scheme**：`DownloadToken` 泛化后指向任意 target 时，URI 用什么 scheme？
>    是否就是 `group-a-uri-share` 已经在造的那套（`entity://`/`kind://` 风格 URI +
>    通用 claim 端点），还是独立的 download 专用 scheme？如果是前者，`DownloadToken`
>    这条线可能应该收编进 `group-a-uri-share`，而不是并行泛化——这是本任务要下的第一
>    个判断。
> 2. **mint 授权口径**：谁能对一个 target 创建分享 token？必须比照 `group-a-uri-share`
>    的 M1 教训（token 只认签名不认 issuer 是否持有权限 = CRITICAL 漏洞）：新设计从
>    第一天就要把 issuer 身份和授权校验做进去，不能先上线再补。
> 3. **`kanban.share_board` 归宿**：明确裁定废弃 / 迁移到统一实现 / 保留为兼容层三选一，
>    并给出理由。
> 4. **person-binding 语义**：分享链接 claim 后是否绑定到具体接收人（不可转让）还是
>    匿名可转让给任何拿到链接的人？对齐 `group-a-uri-share` D2（anon claim 统一走
>    read-only anon entity 物化）的既有设计决策。
> 5. **message-share 是否纳入**：本批是否顺带处理消息级别的分享，还是限定在
>    文件/资源级别，留到下一批。
>
> DoD 写完后不要自己实现——找 Allen 确认（他是设计 owner），确认后再交给 jjkysy 落地。
