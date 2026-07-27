# kanban 示范 plugin 重构(PR #1474)—— 最终设计与决策账

> **日期**:2026-07-27 · **性质**:权威收口文档,综合 2026-07-15 ~ 2026-07-25 期间的 kanban 剥离过程文档(清单与并入索引见文末附录)。本 PR 新增的 11 份过程稿由本文取代删除;另 3 份 main 已有的 kanban note(`layering-debt` / `reflux-deploy-verify` / `e2e-sandbox`)保留原件,本文只提炼其要点。
> **读法**:本文反映 PR #1474 收口时的**最终实现状态**,不是开发流水账。过程中被推翻的方案只在「决策账」(§3)里各留一句话,防止后人重走弯路或把已定决策当 bug「修」掉。

**导航**:

- §1 目标 + X/Y 判定方法 + 通用 seam 清单
- §2 最终架构:数据宿主模型(2.1)/ 协作模型(2.2)/ 钥匙三件套(2.3)/ **七条权限范式(2.4)** / github·miro(2.5)/ sw 纯声明(2.6)/ UI 归位(2.7)/ config 化(2.8)/ 目标布局(2.9)
- §3 剥离决策账(D1-D4 / ㊵ / 分享二期 / round2)+ **被推翻方案速查表(3.1)**
- §4 rebase 到 #1579 拆库后 main 的适配
- §5 已知遗留(不阻塞 merge)
- §6 证据索引 · 附录 = 13 份源文档并入索引

---

## 1. 目标

kanban 是这个系统里**第一个可变数据资产 kind**。功能追逐期,它的代码散布进了三个不属于它的层:

- **domain_session**:建板/分享/找 assistant 的策略层(`board_provision.ex`)带着 `board`、`kanban-assistant` 字面住在域层;
- **ezagent_web**:share controller 里做业务(解析接收者、挂载),违反「Phoenix 是 transport 不是 fullstack」(P13);
- **world**:kanban 的 UI/数据/动作内置在宿主前端,plugin 只剩渲染投影。

这不是谁写错了——当年 plugin 够不到域 API、world 是唯一 UI 宿主、HTTP 只能落 controller,**平台没给 plugin 干净的路,业务只能塞进够得到 API 的层**(分层债的共同根因)。

#1474 一直不合,就是在等各路通用 infra ready 之后做一次干净重构。目标三件事:

1. **plugin 自包含**:kanban 的全部代码(行为层、建/删/分享策略、React 组件、样式、前端测试、skill seed)住 `apps/ezagent_plugin_kanban/`,对 infra 只经**声明**(manifest / `pages/0`)和**调用通用 seam** 连接。零 infra 层 kanban 字面、零对 world 的编译依赖。
2. **socialware 退化为纯声明**:注册 seed + 配置 agent + skill + 一份 manifest 声明 `uses: [kanban]`,零代码(Decision #156)。
3. **作教学锚点**:开源贡献者看 kanban 就知道「一个 plugin/sw 该怎么组织」——包括 §2.4 的七条权限开发范式,照抄清单即可。

**贯穿方法(X/Y 判定)**:每处 kanban 侵入 infra 的字面,先问是 **X(根源:infra 缺 seam,该补 infra)还是 Y(表象:seam 已存在,我们没用/用错)**。2026-07-25 审计逐项对照通用 seam 清单:

| 通用机制 | 是什么 | kanban 怎么用 |
|---|---|---|
| `CompositionCaps.mint_cap/4` | 运行时发钥匙唯一非绕过入口,granter 恒 = data_owner | 给人/assistant 发 board operate 钥匙 |
| `Cap.revoke_all_to/2` | cap-epoch 撤销:目标 mailbox generation bump,一次作废 | 删板撤钥匙 |
| `Cap.issue/3` | cap 铸造唯一收口(I7 gate) | 建板授权族全部铸 cap |
| `UiSurfaceProvider` + `pages/0` | 插件 UI 自声明,`PluginPageRegistry` 运行时反射 | kanban 前端整包声明进 world 壳 |
| 通用 unfurl(#1569) | 消息链接 unfurl 气泡注册表 | 分享/申请编辑气泡 |
| `SessionReads` + person-bound `DownloadToken` | 会话读授权闸 + 附件人本位下载 | 附件走通用 uploads |
| `SessionView` + `BoardView` | 插件声明只读投影 view | board 只读渲染 |
| deploy-seed / `ManifestSeed` | socialware 声明化上线,唯一 late scan | kanban sw = manifest |
| `MemberBackfill` | 入会补发(七处加人入口全接) | 新成员钥匙/view cap 补发 |

**审计结论:通用机制全部已在 main,没有一个是 kanban 专属,残留几乎全是 Y**。所以重构 = 把代码搬回该在的层 + 改用现有 seam,不是造新机制。

**达成度(收口时)**:sw 声明化 🟢 · plugin 自包含 🟢 · infra 去 kanban 🟢(board_provision 归位 + Mount 整删后,infra 层残留只剩 §5 列出的 transport 落点与 dormant 字面,均已定归属)。

---

## 2. 最终架构

### 2.1 数据宿主模型:板 = agent,数据跟人走

- **板不是表、不是 session 附属物,是一个数据宿主 agent**(role `kanban-manager` × flavor `native`,passive:不 join 会话、无自主行为)。board 数据 = 该 agent 的 `:kanban` snapshot slice。
- **一切操作 = dispatch + 钥匙**(2026-07-15 用户拍板,模型的第一性原理):任何 UI/chat 操作本质都是一次 **dispatch 到板 agent**,成败只看持不持有 operate cap。人类亲手点 UI 和让 assistant 代操作**不是两种权限模型**——都是「持钥匙者 dispatch」。于是整个设计只剩一件事:**钥匙发给谁**。
- **board 跟人走,不焊 session**:归属由 `data_owner`(via AgentLineage)决定;**版主人 = 建板人**,对本板持 admin 级权(删任何节点 + 批准编辑),与全局 admin 无关。
- **kanban 与会话正交**(㊵ 模型钉死):kanban tab 的内容 = 「该用户持钥匙的板集合」,不是「该会话挂了哪些板」。a 在会话 A 建的板,b 分享给 c,c 点开后板出现在 **c 自己的 kanban tab**(只读),不跳任何会话;同会话分享同理,点击 = 原地切 tab 定位该板。

### 2.2 板内协作模型(excalidraw 式 + 认领)

kanban 的产品定位从「严格流程管理」改为**带认领机制的协作**:记录/协作/流程梳理 ≫ 严格流程管理;last-write-wins,不做无冲突合并。用户 9 条规则经一轮漏洞收敛(H1-H7)+ 四条追加拍板(C1-C4)后定稿:

- **加任何节点 = 创建者自动认领**,一出生就有属性(含 stage);「未认领」态只由「取消认领」产生。
- **有内容的节点不能取消认领**(「内容」= artifacts/附件/metrics,**不含子节点**——有子但无内容的结构节点可退领,变成可被重认领的空容器);要弃就整删。⟹ 系统不变式:**未认领节点恒为空**,谁都可删、可重认领。
- **任何编辑成员可在任何节点下加子**(各自认领,子树可混主);认领人编辑自己节点的内容/属性。
- **删除 = drop 整棵子树**:需整子树「自己认领或未认领」,他人已认领的后代挡删(保护别人的活);**版主人 wildcard 兜底**(`board_admin?` = board data_owner 或全局 wildcard;早期「建根必须全局 admin」的硬门按此移除),否则板会积垃圾没人删得掉。
- **drop ≠ 删除**(㉕ 重定义,中途推翻过一版「合并成一个功能」):drop 是**非破坏跟踪标记**——节点挂的北极星指标不达标时标 drop:不删数据,节点及子树渲染红框,记 `%{id, reason, at, by}` 历史;权限归**节点认领人**(非整树校验)。删除保持上一条授权不变。
- **分享链接恒只读**(H4,模型自洽的关键):链接本身**永不授编辑权**——成员点链接能编辑是因为他是成员,不是因为链接。编辑权只有两个来源:编辑 session 成员身份,或规则 8 批准(read→operate 升级;批准人 = **版主人**而非全局 admin,批准气泡出在编辑 session 的 chat,不自动建私聊)。
- **单根先行**(保持 `root_id`):多根改 forest 是数据结构级改动,留后续改版;空板第一个节点 = 根(自动认领)。

**一句话版**:建板人=版主人=本板 admin。编辑成员加节点即自动认领、即有属性。任何成员可在任何节点下加子。认领人编辑自己的节点;清空后可退领(未认领=空=谁都可删可重认领)。删=整子树校验+版主人兜底;drop=标红跟踪不删。链接恒只读;编辑权只来自成员身份或版主人批准。

**漏洞收敛账(H1-H7,规则打架处的裁决)**:

| # | 漏洞 | 裁决 |
|---|---|---|
| H1 | 加根算不算「加子自动认领」 | 加**任何**节点 = 创建者自动认领,未认领态只由退领产生 |
| H2 | 他人在你子树下加子 → 你永远删不掉 | 未认领节点谁都可删;版主人 wildcard 兜底;他人已认领的后代仍挡删 |
| H3 | 退领有内容的节点,内容归谁 | 有内容不能退领(只能整删)⟹ 未认领恒为空,重认领 = 全新一份 |
| H4 | 「链接只读」vs「成员点链接可编辑」矛盾 | 链接永不授权;成员能编辑是因为他是成员,不是因为链接 |
| H5 | 多根要改数据结构 | 单根先行,多根后续改版 |
| H6 | 多主子树下「版主人」是谁 | 版主人 = 建板人(board data_owner),与节点认领者无关 |
| H7 | 未认领节点在 stage 视图放哪 | 属性(含 stage)认领后才有;未认领不显示属性(规则 2) |

### 2.3 发钥匙 / 撤销 / 可见性(Mount 整删后的三件套)

早期实现有一张 `socialware_mounts` 挂载表(`Socialware.Mount` + `MountRow`),记录「哪块板挂在哪个 session/person 上」,发钥匙、入会补发、tab 枚举都读它。**最终态把 Mount + MountRow 整删**——理由:

- 挂载表是 cap 之外的**第二份授权真相源**,「第 N 个 grant 点 = 第 N 个不同步真相源」正是这条线反复撞的坑(ShareReceive 撞过;reconcile 只能重发已记录 grantee,天然覆盖不了新成员)。
- cap 本身已是完整账本:铸造有唯一收口、撤销有 cap-epoch、枚举可从 caller_caps 派生——挂载表提供的每个能力都有 cap 原生等价物。

三个关切各归一条纯 cap 机制:

| 关切 | 最终机制 | 要点 |
|---|---|---|
| **发钥匙** | `CompositionCaps.mint_cap/4` | 唯一不可绕过入口,granter 恒 = data_owner;不自建账本(I7:`Cap.issue` 唯一铸造收口,永不直写 caps_json——直写撞写侧 gate + 无尾 audit 拒) |
| **撤销** | `Cap.revoke_all_to/2` | 目标 mailbox generation bump(cap-epoch),指向它的所有 cap **一次性作废**——删板撤钥匙不遍历、不逐张回收 |
| **可见性** | cap 派生(`union_cap_boards`) | 「我能看哪些板」= 从 caller_caps 求并集;kanban tab 内容 = ws∪cap 派生枚举(人本位),与授权真相源天然一致、不可能不同步 |

围绕三件套的落地决策:

- **board_provision 归位 plugin**:建/删/转发/找 assistant 的 kanban 策略层从 `ezagent_domain_session` **整体搬进** `ezagent_plugin_kanban`(2026-07-25 审计的最大项——它纯因当年 plugin 够不到 `Workspace.create_agent` 等域 API 而住在 domain 层)。搬回后调的全是上表通用机制;读 session 成员改用 canonical `Kind.read(spawn: :never)` 公共读面。`delete_board` 逻辑在审计时的定性是「机制对(`Cap.revoke_all_to` 正解)、位置错」——逻辑原样保留,随迁移换层。
- **建板授权**(D2 追认):普通成员零 `create_agent` cap 也能建板——`create_board` 内走一次性 rule-authority 兜底(`{:rule, :socialware_runtime_provision, creator}`,transient ctx-cap 不落库)。红线三条:建板人须本 session 成员;只造 `passive: true` recipe 的数据宿主;rule-authority 不外溢到任何非建板路径。留 Allen 的治理尾巴:rule 名进 Decision Log;transient ctx-cap 是首个不落库用例需确认;要不要 workspace 级算力开关。
- **建板钥匙分层**(⑳,方向纠正过一次):建板人钥匙 = **plugin 基线**(建板必发,与装没装 sw 无关——测的是 plugin 不是 sw);assistant 钥匙 = **sw 增强**(解析到 assistant 才附加发一把,解析不到就跳过留待补发)。早期实现把增强做成硬前置(解析不到 assistant 整体 fail-closed)——方向反了,已纠。

**历史根因备案**(为什么钥匙机制值得这么大动干戈):2026-07-16 真机 e2e 连暴四个症状——

1. owner 建完板**看不到看板 tab**(⑤:render view cap 只发给了匿名访客,没发 installer/成员);
2. owner **UI 建不了板**(⑥:全链路没有任何给普通用户的 `create_agent` 授点);
3. owner **建不了根节点**(⑦:建根硬门只认全局 admin wildcard,不认 board data_owner);
4. owner **连后台建好的节点都读不到**(⑧:dispatch 全 unauthorized)。

统一根因是 ⑧:`Workspace.create_agent` 只给建板人铸了 **Manage** cap(管 agent 生命周期:terminate/destroy),没铸 **Kanban operate** cap(用这块板)——behavior 轴对不上,owner 能「销毁」自己的板却不能「使用」它。修法不是四个补丁,是收敛成「建板发全套钥匙 + 安装/入会统一补发」一条链——也就是本节的三件套 + §3 的 D1/D3。

### 2.4 七条 plugin 权限开发范式(后来者照抄的清单)

从「两把钥匙」权限模型讨论(2026-07-20)+ 本次重构沉淀。写任何可变数据资产 plugin 时逐条对照:

1. **资源 = 数据宿主 agent,归 data_owner**——不发明「资源表 + owner 列」,数据就是 agent,归属走 AgentLineage。
2. **发钥匙走 `mint_cap`,不自建账本**(I7)——任何「谁有权」的记录都是 cap 本身,不另立挂载表/成员表当第二真相源。
3. **撤销走 `Cap.revoke_all_to`**——generation bump 一次作废,不遍历、不追签发记录。
4. **可见性 cap 派生**——「你能看到什么」从你持有的 cap 算出来,不查副本表。
5. **授权来自 action-cap(dispatch probe)**——判「能不能做」用真实 dispatch 探测(要么做成、要么 `:unauthorized`),不裸调 `Capability.matches?` 自己拼判定逻辑。
6. **无 self-token 车道**——assistant 不拿用户 token 冒充用户、也不拿自己的钥匙替人越权;代人动手前恒查**判权恒等式**(见下),拒时发 ErrorSignal 结构化错误(不 silent、不散文拼话术)。
7. **无 `get_slice` 裸读**——读别的 Kind 的状态走 `Kind.read` 公共读面;actor-boundary ledger 里 kanban 的 get_slice 条目已随之归零(消灭需要声明的用法,而不是多声明一条)。

**第 6 条的背景(两把钥匙模型)**:对同一份数据,一个人手里其实有两把钥匙——

- **直接钥匙 = 数据 cap**:亲手点 UI/敲 CLI 时系统查的那把,有完整的铸造/签名/校验体系。
- **间接钥匙 = 驱使 assistant 的权**:@assistant 让它代做时行使的权利。现状**完全没有锁孔**——chat/@ 路由只看成员资格 + mention,投递 ctx 不带发送者任何 cap,assistant 又持自己身份的 token 行事。

于是任何 session 成员——哪怕对板一个 cap 都没有——都能 @assistant 借它的钥匙删板。上半场 e2e 里 admin 代跑掩盖了这个洞。补法是**判权恒等式**(全模型只有这一条规则):

> assistant 替人动手前,恒查「**提要求者本人**对目标数据的 cap」。有则做;无则拒并回话。

三个场景一条规则:(a) kanban 单用——非板主成员叫 assistant 删板,查**他本人**的板 cap,无则拒并回话;(b) 组合 sw(官网 = hello + kanban)——组合胶水以真实用户身份判权(`{:held_by, sender}` issue 模式,hello 样板已跑通);(c) 新建 agent 的 sw——下级 worker agent 借 assistant 之手动板,同样查 **worker 本人**的 cap,**sender 是人是 agent 不影响判法**,想让 worker 动板就走正路发 cap,不给 assistant 开后门。

三个边界:① **不改 core 一行**——verifier 保持单主体、cap 签给出示者本人(Decision #137 不做 delegation),判权全部在 grant/issue 侧完成;② **不做用户 token 代持**——判权靠「以 sender 为主体重新 issue」,不靠身份冒用;③ 粗闸方案(把驱使权也铸成 cap)评估后不做——侵入面大(要在 domain 扇出处新开锁孔)、粒度天花板低(判不了自然语言里的意图是删还是读),细粒度终归回落到恒等式。

恒等式的落地件与分工(跨线,备查):**gaga**——cc-headless 桥补 sender 透传(信封上本来就有,唯独 headless 桥丢了这一跳;PTY 桥是已透传的参照);**Allen**——拍「以已认证消息 sender 为判权 caller」的信任规则(是否作为 Decision #137 bounded delegation 的接续条目进 Decision Log);**kanban 线**——plugin 侧动手前判权接线(`{:held_by, sender}` 恒查)+ 官网组合 sw 拆分时胶水迁出 hello;**zyli 线**——拒权 ErrorSignal 的前端渲染路径确认。gaga 的透传是 headless 场景的前置;hello 样板不等它即可先行验证。

### 2.5 github 移出,miro 保留

- **github 整删**:`register_pr` / `attach_code_file` / board 级 `github_repo` 配置全部删除。理由链:生产是 docker 隔离环境,凭证不进 agent、集中在专门 gh plugin(Allen note #1417:GitHub = 插件形态、token 按用户代取、cap-gated);挂代码库/看 PR 该用**独立 github plugin 直接同步**,kanban 连「纯数据链接字段」也不留半吊子——等 gh plugin 就绪,kanban-assistant dispatch 接入即可,kanban 侧不写「检测 gh plugin」逻辑(那是接入活,不是本 plugin 的事)。
- **miro 保留**:出站(树 → Miro 板)与 external_mirror 通用机制重叠,将来可迁;入站双向轮询是 external_mirror 的**真实缺口**(整个审计里少数的 X),归 Allen 线。凭证不持久登记——同步到 Miro 时弹框临时填。
- **遗留债一并记**:MiroSync 定时 tick 以「系统 admin」身份 dispatch 是权限系统落地前的存量做法,用户已定性**不作先例**——正路参照 email inbound 的「映射回真实 principal 当 caller」;将来正式调度机制按「数据属主 cap 判权」方向收敛。

### 2.6 socialware = 纯声明(Decision #156)

kanban socialware 最终形态 = 一份 `manifest.yaml`,零代码:

- `uses: [kanban]`(声明依赖哪个 plugin)
- roles(kanban-assistant 等 recipe 配置)
- views(如 `kanban_render`)
- routing_rules

上线走 deploy-seed / `ManifestSeed` 车道(唯一 late scan);skill seed(kanban-assistant 的脚本/文本)归 plugin priv。

**plugin 与 sw 刻意分离**:plugin 是系统级 OTP app(单 runtime 全 ws 共享代码,不存在「某 ws 没装 kanban plugin」),装了 plugin 所有会话都有 kanban tab;装不装 kanban **sw** 只决定有没有 assistant/团队增强。session 与 sw 也不是一对一绑定:一个 session 可关联多个 sw、可把配置沉淀成 template 再发布成新 sw(组合闭环)。

### 2.7 UI 归位:plugin 自带前端,world 只是壳

- kanban 的 React 组件(Kanban.tsx / KanbanCanvas / unfurl 气泡)、data reader、dispatch 白名单、**样式(styles.css)和前端测试**全部住 `ezagent_plugin_kanban/assets`,经 `UiSurfaceProvider` + `pages/0` 声明(route/nav/unfurl/actions/renderer/data_builder),`PluginPageRegistry` 运行时反射枚举——**plugin 对 world 零编译依赖,world lib 零 kanban 字面**(唯一例外是生成物 `plugin-page-renderers.tsx`,由 `mix world.renderers.manifest` 生成,正确模式)。
- 分享/申请编辑气泡走 world **通用 unfurl 机制**(#1569),kanban 是首个声明消费者;附件走通用 uploads + person-bound `DownloadToken`(不再有 kanban 专属下载路)。
- kanban tab **恒显**(D3 方案 a):`BoardView.applies_to?` 恒 true——tab 的存在表示「系统有此 plugin」,被门控的是内容/钥匙(没钥匙 = 空板集合 + 「点分享链接领板」引导文案)。`authorize_view` 契约原样不动:**发 cap 让 gate 过,不是绕 gate**。这也让「分享链接在任何会话点开」才有意义。
- 协作实时性:写动作成功后广播 `:kanban_changed`,同会话成员画布自刷新(修掉「A 操作 B 看不见、要手动刷新」一族问题)。

### 2.8 运维 config 化

`role_plugins`(原 domain_agent 里焊死 `[:ezagent_plugin_kanban]`)、`socialware_check_reference_apps` 这类「本部署有哪些 plugin」的枚举,从代码字面挪进 `config.exs`(deploy-owned):通用 mix task / 通用授权代码零 plugin 字面,加一个 plugin = 改配置,不改 infra 代码。

### 2.9 目标布局(教学锚点本体)

```
apps/ezagent_plugin_kanban/
  lib/ezagent/behavior/
    kanban.ex                  # board 的 Kanban ActionSet(全动作 + per-node CapBAC)
    kanban/                    # connectors/shared 等辅助
    kanban_render.ex           # BoardView 只读投影(Kind.read_durable 冷读)
  lib/ezagent_plugin_kanban/
    application.ex             # pages/0 声明 + recipes
    world_data.ex / world_actions.ex   # UiSurfaceProvider 的 data/dispatch 面
    board_provision.ex         # ★ 建/删/转发/找 assistant 策略层(从 domain_session 迁入)
    world_share_actions.ex     # 分享/请求编辑(调通用 person-bound token)
  assets/src/                  # 前端 renderer 全在这(组件/气泡/样式/测试)
  priv/
    socialware_seed/kanban/manifest.yaml   # sw 纯声明
    skills_seed/kanban-assistant/          # skill seed 归插件

# infra 层零 kanban 字面:domain_session 只剩通用 CompositionCaps/MemberBackfill;
# world 零 kanban(除生成 manifest);web 只剩 transport 落点(见 §5)。
```

---

## 3. 剥离决策账(每条:决策 + 理由)

按主题沉淀的关键拍板。全部是 Allen/用户已拍的定案,勿重开:

- **D1 · 入会补发(participation + view)**:新成员 join 已挂板的会话后,要零刷新看到 tab、拿到板钥匙。形态锁死:**caller-side confirmed grant + 全平台单一 shared helper 供给点**——join handler 内做 sync grant 会死锁 session 创建(materialization-confined,5s timeout 实证),而 I12 禁止另起 grant 真相源。落地为 `MemberBackfill`(grep 盘出的加人入口全集接入,非手挑)。**删掉了错误的 mount-operate 半**:operate 钥匙不随入会自动扩散(read 行不扩散原则);Mount 整删后补发数据源随之改为 cap 派生,helper 单供给点原则不变。
- **D2 · 建板规则边界**:「普通人无 create_agent cap 也能建板」是**产品口径**(人人可开板),不是漏洞——板是 passive 数据宿主(无 join、无自主行为),风险面 ≠ 通用 create_agent,收紧会打断产品口径。追认现状 + 红线进 Decision Log(建板人 = 触发 session 成员、只造 passive:true、不外溢),防后人当 bug 收紧。
- **D3 · 渲染 cap baseline / tab 恒显**:tab 按 **plugin 级**恒显(推翻早期「按 sw 安装门控 tab」实现——那导致「关联了 sw 却没看板」一族困惑);`kanban_render` view cap 按 plugin 基线发全体登录成员,发放走 D1 同一 helper(不新增独立 grant 文件);顺序红线 = cap 先发、`applies_to?` 后翻(cap 先发无害,空窗方向安全)。
- **D4 · 跨 workspace 口径**:**只读分享跨 ws 放开;operate/写类钥匙永不跨 ws**(先验租户隔离不变量——任何路径:分享/转发/入会补发/规则 8 升级,都不得给跨 ws 主体铸 operate 钥匙);规则 8 read→operate 升级点必须**复查同 ws**,升级不是绕不变量的后门。ws policy 收成 plugin 侧单守卫函数,结束「forward 路有硬守卫、链接路零检查」的两路口径不一。
- **㊵ · 人本位接收**:推翻「服务端解析目标会话 + 整屏重定向」的 receive 设计——点分享链接 = 给**点击者本人**铸 person-scoped 只读钥匙,板出现在点击者自己的 kanban tab,零会话跳转;读/写按点击者与板的关系 gate 判(读成、写 missing_cap 各有 e2e 实证)。这是「kanban 与会话正交」(§2.1)在分享面的落法。
- **分享二期(share_to_session + 规则 8)**:「分享到会话」= 服务端物化 `kanban.share_to_session` dispatch(服务端 access gate 后物化分享消息,`hops: 0` 零路由),不靠前端拼;规则 8 全链落地:`request_edit` → 版主人批准气泡 → `approve_edit` → person 行**原地 read→operate 升级**(自然键仍 1 行);授权反例(:not_board_owner / :no_read_mount / :already_owner / :no_access)全测;错误统一走 ErrorSignal 结构化字典,零散文、零 silent。
- **分享业务口径**:分享逻辑上只有**一个链接**,按点击者身份过滤只读/可写;UI 入口两个——「分享到会话」(气泡)和「复制分享链接」,殊途同归。同 ws 是业务主场景;跨 ws read 机制上已通(core 半件遗留见 §5)。
- **round2 整包**(2026-07-17 return,16 commits):行为层(㉕ drop 非破坏标记 / ⑲ delete_board:版主校验 → retire,不直调 terminate / ⑳ assistant 钥匙降级为增强)+ 分层债可搬半(分享接收业务从 web controller 搬 plugin,controller 瘦成 verify+调用;`kanban_data`/`kanban_actions` 从 world 搬 plugin)+ 前端整包(节点面板按规格重做、分享两选项、剪贴板回退与真实反馈、unfurl 注册机制首消费、深色 token 化、`:kanban_changed` 广播)。这一轮把「kanban 自包含」归属内**能搬的全搬了**,剩下的硬骨头(board_provision 归位、Mount 整删)在后续轮完成。
- **数据回流实证**:被分享/转发的板,接收方读的**永远是活 board actor 的当前 slice**(无 snapshot 拷贝)——源板 mount 后新增的节点,接收方 re-read 必见;stale copy 在结构上不可能。`board_forward_test.exs` 锁死此性质。

### 3.1 被推翻方案速查表(防重走)

| 被推翻的方案 | 最终方案 | 一句理由 |
|---|---|---|
| Mount + MountRow 挂载表(记「板挂在哪」) | mint_cap / revoke_all_to / cap 派生三件套 | 挂载表 = 第二份授权真相源,必然与 cap 不同步(I7/I12) |
| 入会补发时按挂载行扩散 operate 钥匙 | 只补 participation + view;operate 不自动扩散 | 编辑权是授予出来的,不是进门送的 |
| receive = 服务端解析目标会话 + 整屏重定向 | 人本位:给点击者本人铸只读钥匙,进自己的 tab | kanban 与会话正交;板跟人走 |
| kanban tab 按「装没装 sw」门控 | tab 恒显(plugin 级),门控内容/钥匙 | tab 表示系统有此 plugin;分享链接才在任何会话点得开 |
| drop 与删除合并为一个功能 | 分开:drop = 非破坏标红跟踪 | drop 的设计意图是指标不达标的**跟踪**,不是删除 |
| assistant 钥匙作建板硬前置(解析不到即 fail) | 建板人钥匙 = plugin 基线;assistant 钥匙 = sw 增强 | plugin 与 sw 职责分层,增强缺席不该阻断主链 |
| 建根节点硬门全局 admin | `board_admin?` = data_owner 或 wildcard | 版主人 = 建板人,不是全局管理员 |
| github 保留纯数据链接字段(repo/sha 手填) | 整删,等独立 github plugin | 不留半吊子;凭证/同步集中在 gh plugin |
| MiroSync 以系统 admin 身份 dispatch(当先例) | 存量债,不作先例 | 权限系统落地前的做法;正路是映射真实 principal |
| 粗闸路 B(驱使权铸成 cap) | 判权恒等式(路 A)为主干,B 不做 | 侵入面大、粒度天花板低,细粒度终归回落恒等式 |
| board_provision / delete_board 住 domain_session | 整体迁回 plugin,调通用 seam | 逻辑对、位置错;domain 只留通用机制 |
| get_slice 裸读 session 成员 | `Kind.read(spawn: :never)` 公共读面 | actor-boundary 收口后 get_slice 是被 ratchet 盯的旧路 |

---

## 4. rebase 到拆库后 main(#1579 actor extraction)的适配

main 把 actor runtime 抽进 `apps/ezagent_actor` 后,本分支的冲突全部**按 canonical 面解**,不留兼容垫片:

- `kanban_render`(BoardView 只读投影)改走 `Kind.read_durable` **冷读**——view 渲染不该唤起 actor。
- 全部 `get_slice` 裸读迁 `Kind.read` 公共读面;board_provision 读 session 成员回归 `Kind.read(spawn: :never)`——actor-boundary ledger 的 kanban 条目随之**删除**(不是加第 2 条声明,是消灭需要声明的用法)。
- 授权 ctx 显式带 `authenticated_principal`(Z-1 ratchet 收紧的连带适配)。
- `legacy_dynamic_receiver_baseline` 按重构后代码**精确重锚**——行锚 baseline 随 kanban.ex 行号变动必须重锚,原则是代码定型后一次锚准,不追中间态打补丁;baseline 权威值用临时 IO.puts 取、不手算(各 gate 的 sha 算法不同)。

**收口 gate 清单**(过程线各 return 的 DoD 交集,合并前逐项过):

- [ ] arch.scan / doc.scan / uri_query.scan / check_invariants / format 全绿
- [ ] `:ezagent_plugin_check` 全绿——尤其 I12 的 `cap_self_store_paradigm_lock_test` / `cap_check_only_at_chokepoint_test`(任何授权改动必须以**收编**而非**新增** grant 点的姿势过闸)
- [ ] `authorize_view` T2-2b 契约测试零改动(D3 红线)
- [ ] rebase origin/main + CI green on PR head(full-suite e2e shard 以 push main 后的真实 CI run 为准,见 §5)

---

## 5. 已知遗留(不阻塞 merge)

- **通用 socialware 分享机制**:本次分享/接收(person-bound token + 人本位铸钥 + 规则 8 升级)是 kanban 首发,将来任何可变数据资产 plugin 都要分享——泛化设计已出 handoff:`docs/together/2026-07-27/handoffs/socialware-share-generalization.md`,待 Allen。
- **D4 跨 ws read 的 core 半件**:plugin 侧 ws_policy 已放行跨 ws read,但 runtime workspace isolation(step 5.6)仍把跨 ws 合法 read cap 的 dispatch 拦死(`:cross_workspace_denied`)——core 落点待 Allen 拍。同 ws 分享全链绿,业务主场景不受影响。
- **domain_git 的 "kanban-task" 资源字面**:dormant(未接通),属「通用 infra 焊了 plugin 名」一族,泛化归 Allen 架构决策,不影响 kanban 单独开发。
- **web ⑥ 残留(transport 落点)**:
  - `kanban_share_controller`——HTTP 点链接必须有 controller 落点,**transport 必留**,已瘦成 verify + dispatch + 深链;
  - `published_read_adapter`——hello↔kanban 产品 glue(组合 sw 线),非 infra 泄漏,后置;
  - `/plugins/kanban` 路由——可从注册表派生成 `/plugins/:kind` 动态路由,泛化随通用分享机制一并做。
- **e2e 环境约束**(2026-07-24 调查备案):`board_provision_grant` 这类 e2e 需要**完整 boot + seed** 环境才有意义。同期根因定位的 Ecto Sandbox 共享模式 owner-exit race:`async: false` 测试映射到共享模式(pool 全局独占),owner 退出会把在用连接从 worker 手里抢走;新 spawn 的 Kind 无 `$callers` 传播、除共享模式外没有 DB 连接来路;长顺序 seed 链任一步被打断即假红。修法 = `TransientRetry` 把 `DBConnection.OwnershipError` 也归为可重试(test-only 死分支,零 prod 影响)。另记 CI 结构事实:full-suite e2e shard **只在 push main / nightly 跑**,PR checks 永远只有 gate job——「本地多轮全绿」不等于 CI e2e shard 绿,收 release-gate 项以真实 CI run 为准。
- **数据回流的 live-UI 验证**:代码级已证(§3 末条),但接收方 World tab 的实时回流**展示**、以及 Hello 回执快照(delegation 时烤死、不实时刷新)的 UX 决策(自动刷新 vs 显式链去活板),需真部署环境录证——本地 disposable 栈立不起完整 world。
- **实时推送环剩余半件**:批准编辑后对端 socket caps 不自动刷新(要刷页面)、申请气泡只物化进申请人当前会话(版主人不在同会话看不到)——归 X1 推送环/membership `:notify` 线(工单已记降级)。
- **调度机制**(agent 定时自主动作):完全未设计——仓内现状全是 infra 自心跳(`Process.send_after`),无任何 principal 运行时可创建的定时任务。方向已定:触发时以**数据属主的 cap** 判权,不给 agent 另立身份;MiroSync 的 admin 心跳按此收敛,归 Allen 线。
- **周边非 kanban 面的顺手发现**(e2e 时挖出,归各自线):向导装 sw 撞 `write_session_templates`(普通 founder 无此 cap 且 UI 吞错);建板后 socket caps 陈旧导致首写 `:invalid_cap_signature`(要刷新);manifest `routing_rules` 未动(分享消息均 `hops: 0` 零路由,现无路由需求)。

---

## 6. 证据索引(一手证据的位置,勿删)

过程稿删除后,以下是仍然有效的一手证据锚点:

- **`docs/e2e/2026-07-20/final-round/`**——全功能最新收官轮证据(PR 收尾规矩:最后一轮全功能 e2e 取代过程截图)。
- **`docs/e2e/2026-07-17/AUDIT.md`**——round2 逐项(㉞ 项台账)状态对照表;round3 逐项截图已按收口裁剪归档删除,commit 引用仍为一手证据。
- **`docs/e2e/2026-07-19/40-person-receive/`**——人本位接收(s01-s09:读成/写 missing_cap/零跳转)。
- **`docs/e2e/2026-07-19/d3-tab-always/`**——tab 恒显(erpc-proof.txt:cap 门仍如实判 + 空态引导截图)。
- **`docs/e2e/2026-07-19/share-phase2/`**——分享二期(s01-s06:share_to_session 气泡 + request/approve_edit 升级链)。
- **`apps/ezagent_plugin_kanban/test/e2e/board_forward_test.exs`**——数据回流非 stale 的机器可跑证明。
- e2e 方法教训(供后续轮参考):原生 `window.confirm` CDP 截不到图(确认框类 DoD 要在规格里写明自定义 modal 还是原生);依赖 `world:state` 回推的 modal 有秒级延迟,固定 sleep 会漏,应轮询 snapshot 至元素出现。
- **`docs/together/2026-07-16/handoffs/allen-decisions.md`**——D1-D4 拍板原文(本文档 §3 各条的裁决出处),不在本次归并删除清单内,保留。

---

## 附录:13 份源文档并入索引(原件删除后以本表溯源)

| 源文档 | 核心内容 | 并入 |
|---|---|---|
| notes/2026-07-15-kanban-collab-model.md | 9 规则协作模型 + H1-H7/C1-C4 收敛 + 「一切操作=dispatch+钥匙」+ 去 github 决策 | §2.1 / §2.2 / §2.5 |
| notes/2026-07-15-kanban-layering-debt.md | 分层债台账(①②③ 层错位、⑤⑥⑦⑧ 统一根因、㉜ tab plugin 级、㊵ 人本位) | §1 / §2.3 / §2.7 / §3 |
| notes/2026-07-15-kanban-reflux-deploy-verify.md | 数据回流实证(live slice 读,stale 结构性不可能)+ live-UI 待真部署验 | §3 末条 / §5 |
| notes/2026-07-20-permission-model-second-half.md | 两把钥匙、判权恒等式、三场景落法、路 A/B 取舍、MiroSync 定性、调度未设计 | §2.4 / §2.5 / §5 |
| notes/2026-07-24-e2e-sandbox-ownership-investigation.md | Sandbox owner-exit race 机制链 + OwnershipError 重试 + CI/本地 gap 结构事实 | §5 |
| notes/2026-07-25-kanban-exemplary-refactor-audit-design.md | X/Y 审计方法、通用 seam 清单、目标 plugin 布局、#1474 重定义为标杆重构 | §1 / §2.3 / §2.9 / §4 |
| together/2026-07-17/returns/kanban-collab-round2.md | round2 16 commits 整包(drop 标红/delete_board/面板重做/unfurl/搬迁) | §3 round2 / §2.7 |
| together/2026-07-18/handoffs/D1-join-replay-helper.md | 入会补发:caller-side 单 helper 形态 + 死锁实证 + I12 | §3 D1 |
| together/2026-07-18/handoffs/D2-create-board-rule-authority.md | 建板 rule-authority 现状追认 + 三条红线 | §2.3 / §3 D2 |
| together/2026-07-18/handoffs/D3-render-cap-baseline.md | render cap 基线发放半件 + 顺序红线 | §3 D3 |
| together/2026-07-18/handoffs/D4-cross-ws-read-policy.md | 跨 ws 只读放开 + operate 先验租户隔离不变量 | §3 D4 / §5 |
| together/2026-07-19/returns/40-person-receive.md | 人本位 receive 落地(person-scope 铸钥/零跳转)+ core 半件遗留 | §3 ㊵ / §2.1 / §5 |
| together/2026-07-19/returns/d3-tab-always.md | tab 恒显翻转落地(applies_to? 恒 true + 空态引导 + 契约不动) | §2.7 / §3 D3 |
| together/2026-07-19/returns/share-phase2.md | share_to_session 服务端物化 + 规则 8 全链 + ErrorSignal 口径 | §3 分享二期 / §5 |

*本 PR 新增的 11 份过程稿由本文取代删除;3 份 main 已有 note(layering-debt / reflux-deploy-verify / e2e-sandbox)保留原件。删除后一手证据按 §6 索引溯源。*
