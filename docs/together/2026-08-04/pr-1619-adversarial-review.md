# #1619 匿名分享 — codex adversarial review（REQUEST_CHANGES）

- 运行: 2026-08-04 09:54–10:05（subagent `aeedf90a5926c68a4`, opus 编排 codex）
- 目标: #1619 anon-share 分支 diff vs origin/main（该 PR 已合入 main=129b2facf）
- 结论: **needs-attention / REQUEST_CHANGES** — 1 critical + 3 high + 1 medium
- 方式: 纯静态审查（无 compile/测试执行）
- 处置: 建议 follow-up PR；是否执行 = 协调者定

## Findings

### [critical] read-only 边界可铸造并自动执行 mutating action
`AnonShare.enable/4` 接受任意 action 列表，仅把行标为 `access: :read`（anon_share.ex:100-103）。该标签不约束 authority：`Mount` 明确注释 actions 决定实际 key、`access` 只是审计元数据（mount.ex:48-55）。Admission 铸造每个存储的 action（anon_user.ex:248-257），external_feed 对每个 action 以空参数 dispatch（external_feed.ex:117-127,169-184）。实例如 `CurlAgent.reset_conversation` — 零参数、清空会话状态（curl_agent.ex:91-97,185-190）。把该 action 以 `:read` 分享 → 仅加载/刷新匿名页即变更目标。测试④只改元数据层而保留已知读 action，无法发现此升级。
**建议**: 定义权威 read-action 契约，persist/铸造前拒绝一切非 read action；加判别测试（零参数 mutator），断言 admission 不铸造、projection 永不调用。

### [high] 预占 live session 击败资源→session 派生校验
新行的快速路径仅把提供的 URI 字符串与确定性 hash 派生 URI 比较（anon_share.ex:177-188; share_setting.ex:101-108,177-181）。该路径接受任何已在该 URI 存活的 session，不校验 owner/template/安装集合/派生证明。workspace actor 可预创建该可预测 URI 为另一个 public/official session；资源 owner 稍后 enable 分享时，行把目标绑定到攻击者的 live room，访客被授予目标 key。现有测试（anon_share_test.exs:67-88）只提供另一目标的派生 URI，漏掉同 URI 预占。
**建议**: 移除未验证的 live 快速路径；每次 enable 验证不可变派生记录 + 预期 owner/template/专用安装集；拒绝采纳外来 session；加"另一 owner 预创建精确派生 URI"测试。

### [high] disable/rotation 后已渲染资源数据仍可见
Disable 只更新 DB 行，不发 advisory、不关闭/刷新已连接 feed channel。channel 只在 adapter live-topic 消息后重读 snapshot（session_feed_channel.ex:63-70,138-143）；浏览器保留当前 snapshot，仅在 `unauthorized` 事件或 channel 关闭时清空（viewer_app.js:298-345）。session 保持 `web_anon_access`，disable 不使 channel unauthorized → 资源在已打开页面上可见，直到无关 advisory 或重连。撤销测试手动调 `ExternalFeed.snapshot/2`（external_feed_anon_share_test.exs:101-141），证明的是下一次读取门控而非即时吊销。
**建议**: disable/target rotation 后发布专属 share-policy advisory，feed channel 订阅之并立即推送重验证 snapshot 或清空资源视图；加 channel/client 测试（先渲染数据，断言无其他事件时消失）。

### [high] born-with caps 硬编码 agent kind，破坏通用资源分享
每个 share key 以 `kind: :agent` 构造（anon_user.ex:248-256），与目标 URI 无关。share facade 明确接受任意目标 Kind（share.ex:133-154）；现有通用铸币路径记录 agent-kind cap 指向 `session://`/`resource://` 可验证但永远不匹配 dispatch（composition_caps.ex:146-151,521-544）。故非 agent 资源与 session 产生签名但无授权的 key 与空 projection。所有新 projection fixtures 用 `entity://.../agent` 目标（external_feed_anon_share_test.exs:270-283），掩盖缺陷。
**建议**: 用现有通用 helper 从目标 URI 派生 kind，或 `Cap.issue_for_action/3` 让 live 目标提供精确 cap；加 `resource://`/`session://` 判别测试。

### [medium] 已登录访客从不获得 share key
Ingress 对已登录 principal 直接返回并绕过匿名 admission（anon_ingress.ex:34-40）。唯一新 share-key issuer 在 `AnonUser.mint_for_public_session/1` 内；已登录分支无对应发行。session 的 public policy 仍授权 feed 本身，故已登录非成员收到成功 snapshot 但 `EntityCaps.effective_caps/1` 找不到目标 key → `resources` 静默为空。违反 anyone-with-link 行为与"每个访客通过自己的 identity+key 读取"的声明。
**建议**: 为已登录访客提供同样的 owner-issued、row-gated 读构件（或显式用 session-bound 匿名身份）再发 feed token；加已登录非成员 link_anon 测试（资源可见且保持只读）。

## Next steps（review 原文建议）
- #1619 在 action 级只读强制 + live-client 即时吊销落地前应 block（本 PR 已合，转为 follow-up）
- 用验证过的专属 session 派生替换纯 URI 派生 + 精确 URI 预占测试
- 目标派生 cap kind + `resource://`/`session://` 覆盖
- 真实 ingress 路径覆盖已登录 link 访客
- 保留现有 24 测试，为 4 个未覆盖安全边界各加判别测试
