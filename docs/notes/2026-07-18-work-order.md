# 2026-07-18 开工单 —— kanban 协作改版收官（D1-D6 已拍板）

> 分支 feat/kanban-collab-round2（本体 PR **#1446** OPEN）。基线 origin/main `d533a5d73`。
> 决策输入：用户拍板 D1-D6 全按 Allen 建议方向（D1 caller-side helper / D2 选c现状追认 / D3 方案a tab恒显 / D4 只读放开+先验租户隔离 / D5 保持 / D6 缓）。
> 上游文档：`2026-07-18-q4-verdict.md`（终审）/ `2026-07-17-xy-review.md`（任务单）/ `2026-07-18-attachment-x-model.md`（㊲ 模型定案）/ `docs/together/2026-07-16/handoffs/allen-decisions.md`（D1-D6 原文）。

---

## 一、PR 总表

| # | PR | 内容 | 预期效果 | 遗留/边界 |
|---|---|---|---|---|
| A | **#1446 本体续**（本分支） | 已落 9+2 项之外的收尾：㊳㊴㊶ 前端三小、㊵ 人本位 receive 重做（含 MountRow person-scope infra 前置）、㊲ kanban 侧点击现签+操作物化消息（~20 行）、㊷ create_session deadline 小修、D2/D4 追认落点、证据收敛 | 协作模型 9 条规则的人本位闭环：分享=钥匙给点击者本人、tab=持钥板集合、附件上传者即时可开 | ㊲ grantee 绑定等 PR-C；规则8/㉙-dispatch 留 PR-E |
| B | **join 补发 + D3 tab 恒显**（独立，domain_session+kanban） | D1 shared caller-side confirmed grant helper（todo.md #161 A2 deferral 合流）+ join 按 MountRow `:operate` 行补 person keys + member view caps；D3 方案a：`applies_to?` 恒 true + render-cap 按 plugin 基线经同一 helper 发放 | 新成员进会话即见 tab、即持本会话已挂板的钥匙；㉜/㉟ 深层坑消失 | `:socialware_member_views` rule 名请 Allen 补 Decision Log；永久形态仍归 #1394 |
| C | **uploads person-token + 读面对齐**（独立，core+web，**过 Allen**） | `DownloadToken` payload 加可选 `grantee`（+`host_uri` hint）；`UploadsController` person-bound 分支（caller==grantee 放行）；chat 侧现签补 `Membership.authorize/3` | 附件授权从「chat 发过言」泛化为「消息参与者 ∪ 宿主钥匙持有者」；防泄漏更强（换人无效） | 内部会话页读史零判定（observer 全可读）另立项不阻塞；`resolver.ex:238-241` stale 注释顺手修 |
| D | **⑪ socialware.import RPC**（独立小 PR） | D5 保持 boot-scan prod-only → `socialware.import` 走分布式 RPC 在运行节点内执行 | dev 改 manifest 有正路车道；替掉 `.iex.exs` 手工 workaround（本次已删；其做法=seed! + 临时目录 scan_dir!，RPC 版收编） | 无 |
| E | **分享闭环二期**（独立，排 A/B/C 后） | ㉙ 分享到会话 dispatch + 规则8 `request_edit`（read→operate 升级）+ D4 开关落定 | 会话内分享/申请编辑闭环 | 依赖 X1 推送环（kanban `:emit` 半已落，membership `:notify` 半在 A 或 zyli 基建） |
| 外1 | **gaga #1452 / #1453**（OPEN，催合） | headless-MCP+CLI 身份 env / 凭证供给面+补物化 | assistant 有「手」可 dispatch；⑩ 静默 skip 有供给面 | 见 §三 sw 侧核对 |
| 外2 | **zyli #1443 实施**（handoff 已 MERGED，实施 0 进展，催） | 推送基建/⑰㉒-②⑫⑩㉑㉛⑬ + ㉟向导命名 + ㊱删session UI | world 非-kanban 前端面 | ⑭ 机制半已由 #1440 覆盖，剩旅程 e2e |

**顺序依赖**：A 先行（无前置）→ B（D1 已拍即可动工，可与 A 并行但 D3 恒显以 B 的发钥匙面为前提）→ C（过 Allen 论证段已备好，attachment-x-model §三；A 的「点击现签」可先落、grantee 传参在 C 合后补一行）→ D 随时 → E 最后（依赖 A 的 receive 重做 + C）。外部两条独立推进，#1452 是 sw 侧手检的最低闸门。

---

## 二、D1-D6 落任务（决策 → 任务）

| 决策 | 拍板 | 落成任务 | 归属 PR | 验收 | 红线 |
|---|---|---|---|---|---|
| D1 | caller-side helper | 实现 shared caller-side confirmed grant helper（唯一补发供给点）；第一步盘出 ~8 add-site 清单（已点名 4：World LV / orchestrator participants / anon admission / SessionCreator）；join 路径接入：member-cap 后补 view caps + mount `:operate` person keys（幂等，`:read` 行不扩散） | **B** | 新成员 join 后零刷新见 tab+板钥匙；helper 单测 + join e2e | **死锁约束：join handler 内禁 sync grant（5s timeout 实证），补发必须 caller-side**；不另起 grant 真相源（I12）；rule tag `{:rule, :socialware_member_views, member}` 报 Allen 进 Decision Log |
| D2 | 选c 现状追认 | 零代码：`BoardProvision.create_board` 一次性 rule-authority（只放行 passive data-host）保持现状；PR-A 里在模块 doc 引用决策；请 Allen 补 Decision Log 条目 | A（doc 一行） | Decision Log 有号 | 边界不放宽：建板人须本 session 成员 + 只造 `passive: true` recipe |
| D3 | 方案a tab 恒显 | `BoardView.applies_to?` 恒 true（kanban 自己的文件）+ `kanban_render` cap 按 plugin 基线给全体登录成员发（走 D1 同一 helper 供给点） | **B**（两半同 PR，避免恒 true 先落而 gate 拒的空窗） | 任意会话（未装 kanban sw 亦然）见 kanban tab；无钥匙时 tab 内容按人本位口径为空板集合 | **不动 `authorize_view` T2-2b 契约**；恒 true 与发 cap 必须同 PR 落 |
| D4 | 只读放开 + 先验租户隔离 | receive 重做时在 ShareReceive 收单一 ws policy 函数：**只读分享（H4 read keys）跨 ws 放开**；`forward_board` 的 `same_workspace` 守卫与 operate 类钥匙保持租户隔离不变量 | A（守卫点）+ E（forward 定位复裁） | 跨 ws 链接点击 → 板出现在点击者 tab（只读）；跨 ws operate 仍 `:cross_workspace_denied` | **先验租户隔离不变量：operate/写类钥匙永不跨 ws；放开的只有 read** |
| D5 | 保持 | boot-scan 口径不动（prod-only）；⑪ RPC 路作为 dev 正路 | **D** | dev 改 manifest → RPC import → 即生效 | 不改 config.exs:33 |
| D6 | 缓 | 不实施。债②残余（Kanban.tsx 出 world bundle / @pages 手写条目 / conversation 特判）+ mount 折 CompositionBinding 挂 #1394 永久线 | 无 | — | 本轮任何 PR 不动 plugin-UI 注册机制 |

---

## 三、sw 侧功能面核对（agent 线断至今从未手检）

| 功能面 | 代码在? | e2e 曾覆盖? | 依赖 | 手检前置 |
|---|---|---|---|---|
| @assistant chat 交互 | ✅ manifest roles + cc bridge + persona/skill（#1434 已修 R1/R2） | ✅ 曾有（07-14 t6 s20/s21 assistant 回复，证据本次已清、记录在案） | 凭证（chat 回复不需 MCP） | dev 栈 + kanban sw 发布 + cc 凭证 |
| assistant 经 chat 操作板 | ✅ skill `kanban-cli.sh`/`kanban_dispatch.exs`（CLI 手）+ operates 边 + ⑳ mount 钥匙 | ❌ 从未（gap3） | **#1452**（MCP 手 + CLI 身份 env 都在其内）+ 凭证 | #1452 合并；核 `kanban-cli.sh` cookie 路径硬编码 `/home/yaosh/.ezagent/...`（同 gaga 红线：部署位派生，勿指 worktree） |
| relay-back `__done__` 路由 | ✅ manifest rule + `relay-signal-check.sh` + `kanban_manifest_test.exs` 三点锁字面 | ❌ 真链路从未（路由层有单测） | #1452 + 凭证（dev-together 也是 cc-headless） | 双 agent 会话 + dev-together 真发 `__done__` |
| dev-together 协作流 | ✅ skills_seed/dev-together + relay overlay | ❌ 从未 | #1452 + 凭证 + 容器内 gh/git + GH_TOKEN（gh 是 CLI 行为非 plugin） | 上述全部 + GitHub 测试仓 |
| chat 建板（T4a） | ✅ `BoardProvision.create_board`（⑥ rule-authority 已落） | ❌ chat 路从未（world UI 建板路已覆盖） | #1452（assistant 发起需「手」） | 同上 |

**X/Y 判定**：「sw 没法测」的 X = assistant 无「手」（工具/身份）。**#1452 合并把「手」全解**（MCP 与 CLI 身份 env 两条路都在 #1452 内），五个功能面全部达到「可手检」。但**不全解**：⑩ 凭证静默 skip（#1453）未合时，fresh 环境 install 会跳过 assistant——dev 现网凭证已配可绕过，手检可行但有手工前置；#1453 = 去掉手工前置的产品化。dev-together 流另需 gh/GH_TOKEN 容器前置（两 PR 都不覆盖，属环境准备）。**结论：#1452 合并 = sw 手检最低闸门，合并后即安排一轮 sw 全功能面手检（五面 × 每步截图）。**

---

## 四、r3 手检问题（㉟-㊷）现状核对（2026-07-18 现读代码）

| # | 现状 | 证据（今日现读） | 归属 |
|---|---|---|---|
| ㉟ builtin 命名/向导 | 待做（外部）；深层随 D3 落地消失 | X 已挖透（双层根因，layering-debt:101） | zyli 向导 + Allen 命名；深层=PR-B |
| ㊱ 删 session UI | 待做 | 纯 UI 缺口 | zyli #1443 |
| ㊲ 附件 forbidden | **方案已定**（person-bound token + 点击现签 + 物化消息补充项） | X 挖透至模型层（attachment-x-model §一-§五 全链查验） | PR-C（通用层，过 Allen）+ PR-A（kanban 侧） |
| ㊳ 链接拼 localhost | 待做 | `Kanban.tsx:541` `<a href={a.url}>` 仍裸 | PR-A |
| ㊴ 双 prompt 弹窗 | 待做（㉖ 就地改名已修，:329 注释证） | `Kanban.tsx:380-382` 双 `window.prompt` 仍在 | PR-A |
| ㊵ 人本位重做 | **方案已定**（xy-review §1 三层任务单） | `share_receive.ex:48,:79` 仍 assistant-grantee | PR-A（infra 前置半件 + 删 assistant 段 + world:dispatch） |
| ㊶ tab 不自适配 | 待做 | `Kanban.tsx:234` `h-[560px]` 固定高仍在 | PR-A |
| ㊷ create_session 5s 超时 | 待做；**补挖完成**：`Provisioning.maybe_put_deadline_ms`（provisioning.ex:66-81）透传管道现成，world caller 没传——修 = `do_create_session`（conversation_actions.ex:349）ctx 加 `deadline_ms: 30_000`（样板 mount.ex:169-170 的 ⑨ 修）；顺手 grep world 其余 provisioning caller | 今日 grep：world 侧零 `deadline_ms` | PR-A 小修 |

---

## 五、遗留问题表（不在本轮任何 PR）

| 项 | 内容 | 挂哪 |
|---|---|---|
| 内部会话页读史零判定 | observer 全可读，与外部面 held-cap 倒挂（attachment-x-model §5.3） | 另立项报 Allen |
| `resolver.ex:238-241` stale 注释 | 「per-message 铸 receive cap」是 A2.2 前旧说法 | PR-C 顺手 |
| D6 永久线 | plugin-UI 注册 + mount 折 CompositionBinding | #1394 |
| 规则8 完整闭环 | request_edit 批准流 UI | PR-E 内，若量大再拆 |
| zyli 面 ⑰㉒-②⑫⑩㉑㉛⑬㉟㊱ | world 非-kanban 前端 | 外2 催 |
| ⑩ 静默 skip 供给面 | 凭证绑定 + 补物化 + skip 可观测 | gaga #1453 |
| kanban-cli.sh cookie 路径硬编码 | 部署位派生（sw 手检时核） | #1452 手检轮 |

---

## 六、分支卫生记录（2026-07-18 执行）

- **删除 57 个过时 e2e 证据**（PR 收口收敛证据规矩）：`docs/e2e/2026-07-14/kanban-t6/`（13）、`docs/e2e/2026-07-14-v2/`（22）、`docs/e2e/2026-07-15/kanban-final/`（22）——均为本分支新增的中间轮证据，被 07-16（r2）/07-17（r3 修复）两轮取代；main 自有的同日目录未动。保留 `docs/e2e/2026-07-16`、`2026-07-17` 为现行证据（收官时按规矩再换成最终全功能轮）。
- **删除未提交 `.iex.exs`**（自标 "TEMP do not commit" 的 e2e workaround：静态 bundle 指向 + kanban 临时目录 seed/scan 一次性发布）；其正路 = PR-D 的 import RPC。
- **保留（权威）**：`2026-07-15-kanban-collab-model.md` / `2026-07-15-kanban-degithub-decision.md` / `2026-07-15-kanban-layering-debt.md`（活清单）/ `2026-07-16-kanban-fix-plan.md`（归属原则+§四深扫清单仍被 handoff 三份引用，未整体被 xy-review 取代，只回填变更）/ `2026-07-17-r3-findings.md` / `2026-07-17-xy-review.md` / `2026-07-18-attachment-x-model.md` / `2026-07-18-q4-verdict.md` / 本开工单 / `docs/together/2026-07-17/returns/kanban-collab-round2.md`。
- **无需处理**：`docs/together/2026-07-16/handoffs/` 三份与 origin/main 同路径同内容（是 main 文件非分支副本）。

## 修正(2026-07-18 用户纠偏):切分原则=kanban 全包一个,infra 一个问题一个
- D3(tab 恒显)与分享二期(㉙+规则8)均为 kanban 侧 → **并入本体 PR-A**(D3 先做,join 补发范围随之缩小)。
- B 缩为**纯 join 补发 helper 单问题 PR**(domain_session,8 add-site,死锁红线)。
- C/D 不变(uploads person-token 过 Allen / dev import RPC)。
- ㊷ X 泛化(provisioning 全线默认 deadline)不开 PR,记 Allen 线。
最终:A(kanban 全包)+B(join)+C(uploads)+D(dev import)=1+3。

## 补充(2026-07-18):「操作物化消息」升格为 PR-A 一等任务(完整版)
不止 attach——**所有 kanban 写操作**成功后以操作者身份物化 `visibility: :internal, hops: 0` 消息进当前会话(不显示于 chat,只留痕/立「一切操作皆对话」心智模型)。实现点=act/act_board 成功路径(与 kanban_changed 广播同点,+一条 session.send);attach 的消息带附件引用(同会话成员经消息参与可下载)。

---

## v2 终版(2026-07-18 按实际代码落点 file 级重切;取代上方 PR 总表的切分口径)

> 铁律:① kanban PR(下称 **PR-K**)=纯应用层,代码只落 `apps/ezagent_plugin_kanban/` 或 `apps/ezagent_web/priv/socialware_seed/kanban/`,加下述「kanban 专属文件例外清单」;② 每个 infra 问题一个 handoff PR 给 Allen(D1-D6 已拍的也补记录型 handoff);③ 确定性 infra 先行,PR-K 同步动。
> handoff 全集:`docs/together/2026-07-18/handoffs/`(9 份,见下表)。

### 边界判定:Kanban.tsx 归属(现读定论)

**结论:`Kanban.tsx` / `KanbanCanvas.tsx` 改动算 kanban 应用层,进 PR-K。** 判定标准是**文件专属性**,不是物理目录:

- D6 已拍「缓」——plugin-UI 注册机制(债②)本轮不动,**D6 落地前这些文件是 kanban view 的唯一物理落点**。铁律说「kanban 自己的 view 属 kanban PR」,view 的实体就是这几个文件,判给 infra 等于 PR-K 交不出任何前端修复,自相矛盾。
- **例外清单(约定俗成,PR-K 描述里显式列出=债②的活账,#1394 收编时整体搬走)**——内容 100% kanban 专属、只是物理住错楼的文件:
  1. `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx` / `KanbanCanvas.tsx`(kanban 前端组件)
  2. `apps/ezagent_plugin_world/assets/src/components/unfurl.tsx` 的 **kanban 气泡条目**(:33-40;非 kanban 条目不动)
  3. `apps/ezagent_web/lib/ezagent_web/controllers/socialware/kanban_share_controller.ex`(kanban 专属 web 薄壳,P13 合规:verify→调 plugin→redirect)
  4. `apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex` 的 **`@kanban_actions` 字面行**(:29,加动作名=kanban 注册数据;注册**机制**本身不动)
- **反面(碰了就是 infra,PR-K 拒收)**:`WorldLive` / `conversation_actions.ex` / `world_data`(world 侧) / `PluginPageRegistry` 机制 / 任何 domain/core/web 共享文件。

### PR-K 任务清单(file 级)

| 任务 | 文件(现读锚点) | 依赖 |
|---|---|---|
| ㊳ 链接归一化 | 保存侧补 scheme:`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`(attach_artifact 存储路);渲染兜底:`Kanban.tsx:541` | 无 |
| ㊴ 双 prompt 改小表单 | `Kanban.tsx:380-382` | 无 |
| ㊶ tab 自适配 | `Kanban.tsx:234`(`h-[560px]` 固定高)+ KanbanCanvas 容器 | 无 |
| 操作物化消息(一等任务) | `world_actions.ex` act/act_board 成功路径(:190,:215,:405-436 与 kanban_changed 广播同点)+session.send `:internal/hops:0`;attach 消息带附件引用(顺带给同会话成员打通 chat 复查面下载,㊲ 的救济半件) | 无 |
| ㊲ kanban 半:点击现签 | `world_actions.ex` +`kanban.download_artifact`(fresh href);`world_data.ex:406` 渲染预签改现签;`plugin_page_registry.ex:29` +1 字面 | grantee 传参等 infra-C 合后补一行 |
| ㊵ plugin 半:人本位 receive | `share_receive.ex`:grantee=点击者本人、删 assistant 解析整段(:95-154+`@assistant_role`)、ws policy 单守卫函数(D4:read 放开);`world_data.ex:111-128` 枚举改 ws∪cap 派生;`world_actions.ex` +`kanban.receive_shared`+caps assign 刷新;`unfurl.tsx:33-40` 气泡改 world:dispatch;`kanban_share_controller.ex` redirect 改 `/plugins/kanban` 深链;`plugin_page_registry.ex:29` +1 字面 | **infra mount-person-scope 合并**(person-scoped MountRow) |
| D3 kanban 半:tab 恒显 | `board_view.ex:51-61` `applies_to?` 恒 true | **infra D3-cap 半件先合**(顺序红线,见下) |
| 分享二期(㉙+规则8) | `world_actions.ex` +`kanban.share_to_session`(㉙ dispatch+消息发送)+`kanban.request_edit`(调 `Mount.mount` read→operate 重挂升级,plugin→domain 允许箭头);批准流 UI(Kanban.tsx/unfurl.tsx);manifest `routing_rules`;`plugin_page_registry.ex:29` +2 字面 | ㊵ 合并;X1 推送 membership `:notify` 半(zyli 外部线)未落则通知面降级 |
| D2 追认 | PR-K 侧零代码(BoardProvision doc 行在 domain 文件,归 D2 handoff 捎带) | 无 |

### infra 问题清单(9 份 handoff,一问题一 PR)

| handoff | 型 | 问题(现象→落点) | 对应原 PR |
|---|---|---|---|
| `D1-join-replay-helper.md` | 记录型(已拍)+plan | 新成员 join 后无 tab/无板钥匙;shared caller-side confirmed grant helper(todo.md #161 A2)+~8 add-site+join 按 MountRow `:operate` 补 person keys+member view caps;落 domain_session(+world LV/identity add-site) | B |
| `D3-render-cap-baseline.md` | 记录型(已拍)+plan | render-cap 发放半件:`kanban_render` 按 plugin 基线给全体登录成员,走 D1 同一 helper 供给点;落 domain_session installation/join 路 | B(同车) |
| `mount-person-scope.md` | **过 Allen** | MountRow 自然键含 session(mount_row.ex:42-46)无 person-scoped 行位置;定 scope 约定(哨值或 scope 列),零 kanban 字面;禁绕表裸 mint(⑲ unmount_all_for_target SoT) | ㊵ 前置 |
| `uploads-person-token.md` | **过 Allen** | 附件 forbidden:serve-time 授权 chat-message 参与本位(uploads_controller.ex:110-157)+TTL300s 预签;DownloadToken 加可选 grantee/host_uri(core)+person-bound 分支(web)+chat 侧现签 `Membership.authorize/3`+resolver.ex:238-241 stale 注释 | C |
| `provision-deadline.md` | 小 infra | ㊷ create_session 5s 超时:world `conversation_actions.ex:349` `do_create_session` ctx 补 `deadline_ms: 30_000`(caller 一行,world 共享框架文件=infra);provisioning 全线默认 deadline 泛化=提案记 Allen 线,不开工 | A 移出 |
| `D5-socialware-import-rpc.md` | 记录型(已拍)+plan | dev 改 manifest 无正路;`socialware.import` 分布式 RPC 在运行节点执行;不动 config.exs:33 | D |
| `D2-create-board-rule-authority.md` | 记录型(已拍) | 零代码追认:create_board 一次性 rule-authority 保持;BoardProvision doc 引用行捎带;请 Allen 补 Decision Log | — |
| `D4-cross-ws-read-policy.md` | 记录型(已拍) | 只读跨 ws 放开+operate 永不跨 ws 不变量;守卫点实现在 PR-K ShareReceive 单函数,infra 侧 forward_board `same_workspace` 不动 | — |
| `D6-plugin-ui-registry-deferred.md` | 记录型(已拍) | 缓;例外文件清单=债②活账,挂 #1394 | — |

### 顺序表

1. **即刻(确定性,handoff 发出即开工)**:D1-join + D3-cap(同车,infra PR-B)∥ D5 import RPC(infra PR-D)。
2. **过 Allen 后开工**:mount-person-scope(小,㊵ 唯一前置)→ uploads-person-token(PR-C)。
3. **PR-K 同步开工**,内部顺序:㊳㊴㊶+物化消息+㊲现签(零依赖,即刻)→ ㊵ plugin 半(等 mount-person-scope)→ `applies_to?` 翻转(等 D3-cap 合)→ 分享二期(最后)。
4. **记 Allen 不开工**:deadline 泛化提案、D2 Decision Log 条目、D6 备案。

**D3 顺序红线重解释**:原红线「恒 true 与发 cap 必须同 PR」防的是"恒 true 先落而 cap gate 拒"的空窗;切分后改为**顺序约束**——cap 发放(infra)先合(先发无害,tab 未恒显=现状),`applies_to?` 翻转(PR-K)后合,空窗方向安全,红线语义保持。
