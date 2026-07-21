# kanban 协作模型重定义（2026-07-15，用户定，草案待收敛）

**定位**：kanban 从「流程严格管理」重定义为**带认领机制的 excalidraw 式协作**。
优先级：**记录 / 协作 / 流程梳理 ≫ 严格流程管理**。规则上像「加了认领机制的 excalidraw 协作」（**不考虑无冲突合并**，last-write-wins）。

## 用户给的 9 条规则（原文意图）

1. 建板后**任何人可加根节点**；根**不限一个**（多根）。
2. 节点**未认领**时，除「加子」和「认领」外，**不显示任何其他节点属性**。
3. **加子后自动认领**（创建者认领新子）；可**取消认领**（认领键 ↔ 取消认领键切换）。
4. 认领后，**认领人可编辑节点内容**（属性、附件）。
5. 认领后可**删除 = drop**（删节点 + 其整棵子树）。**仅当节点及其所有子节点都由同一人认领**才可删；否则不可删。
6. **任何人可给任何节点加子节点**。
7. **编辑 session 内任何人可分享**。分享链接**一律只读**，不存在「分享后可编辑」。
8. **非编辑 session、不在 session 内**的用户经只读链接进入 → 需有「**申请编辑**」键 → **版主人批准**。可用「编辑 session 内弹批准气泡」实现（是否能自动建「只有版主人的私聊」待确认）。
9. 旧设计有「把板内容经气泡分享回本 session chat」，现没了。其实**分享可选**：分享回会话 / 生成分享链接——**逻辑上都是一个链接**，按点击进入的 user 过滤只读或可编辑。

## 漏洞收敛结果（用户 2026-07-15 拍板）

- **H1** → 加任何节点（根或子）= **创建者自动认领**。未认领态只由「取消认领」产生。
- **H2** → 未认领节点 = **谁都可删**（未认领本就无内容/无属性）。**版主人/admin = wildcard**，可删任何东西。他人已认领的后代仍挡删（保护别人的活）。
- **H3** → **有内容（artifacts/附件）的节点不能取消认领**；但可以**直接整删**（drop）。⟹ 未认领节点恒为空。
- **H4** → **链接本身永不授编辑权**，一律只读。编辑权走**现有 CapBAC 模型**：来自「是编辑 session 成员」或「规则 8 批准」。
- **H5** → **多根数据改动大，先不改**（保持单根 `root_id`）；多根留后续改版。⟹ 近期：空板第一个加的节点=根（自动认领），之后只加子。规则 1「多根」是目标不是本期。
- **H6** → **版主人 = 建板的人**（`Ezagent.ActionSet.Kanban.data_owner/1`）。空板可由编辑成员建（本期单根）。版主人对本板有 admin 级权（删任何节点 + 批准编辑）。
- **H7** → **属性认领后才有**（创建即自动认领 → 一出生就有属性）。取消认领需先清空 → 未认领无属性（规则 2）。重认领 = 全新一份，属性可改。stage 属「认领后才有」的属性。

### 收敛后的自洽模型（一句话版）
**建板人=版主人=本板 admin。空板上编辑成员加节点即自动认领、即有属性/stage。任何编辑成员可在任何节点下加子（各自认领，子树可混主）。认领人编辑自己节点内容；清空后可取消认领（→未认领=空=谁都可删可重认领）。删=drop 子树，需整子树「自己认领或未认领」，否则挡（版主人 wildcard 兜底）。分享链接恒只读；编辑权只来自 session 成员身份或版主人批准（CapBAC）。单根先行，多根后续。**

### 收敛后新问题（2026-07-15 用户已拍板）
- **C1【核心·已定】一切操作 = dispatch + 钥匙**：用户澄清——ezagent 里**数据本身即 agent**（板=kanban-manager agent），**任何 UI 操作本质都是一次 dispatch（传话）到板 agent，成败只看持不持有 operate cap（钥匙）**。人类自己操作 vs 让 assistant 操作**不是区别**，都是「持钥匙者 dispatch」。所以设计只剩一件事：**钥匙（operate cap）发给谁**。落地方向：板 mount 进 session，编辑成员（+需要代操作的 assistant）各持一把该板 `behavior:Kanban` operate cap，随建板/join 发钥匙（复用 #1376 mount infra，granter=版主人 consent）。修复 ⑧（现只铸 `Manage` 不铸 operate）。
- **C2【已定】版主人=本板 admin 的实现**：现 `admin?(ctx)`（kanban/shared.ex:156）只认全局 wildcard。改成 `本板admin? = 全局wildcard or caller==data_owner(board)`，供建根(H1)/删除兜底(H2)统一用。
- **C3【已定】取消认领的「内容」界定**：「内容」= artifacts/附件/metrics，**不含子节点**（有子但无 artifacts 的结构节点可取消认领，变未认领容器可被重认领）。
- **C4【已定】规则 8 批准落地**：批准气泡出在**编辑 session 的 chat**（成员可见），**批准人 = 版主人（board data_owner），不是全局 admin**；不自动建私聊。

**状态：模型定稿，未实施**（用户 2026-07-15：先不实施，进入下一步）。落地是 kanban behavior + world 前端 + cap 发钥匙（#1376）的一次重写，进实施计划时再拆。

## 原始漏洞（压出来的，已收敛见上）

- **H1 根节点谁认领**（规则 1↔3 打架）：加根算不算「加子后自动认领」？建议统一**加任何节点=创建者自动认领**；「未认领」态只由取消认领产生。
- **H2 删除锁死 + 孤儿**（规则 5+6 致命）：规则 6 任何人可在你节点下加子（归他）→ 你的子树永远「非同一人」→ **你永远删不了自己的节点**（他人可恶意/无意锁死）。且「未认领父 + 已认领子」→ 没人能删的孤儿。需定：① 未认领后代在删除判定里怎么算；② **版主人/admin 可删任何东西的兜底**，否则板积垃圾删不掉。
- **H3 取消认领 + 已有内容**（规则 3↔4）：取消认领一个有内容的节点 → 内容留着（隐藏）还是清空？他人重认领继承吗？（excalidraw 直觉：画还在、认领权转移。）
- **H4 链接只读自相矛盾**（规则 7↔9）：正解 = **链接本身永不授编辑权**；编辑权来自「本来就是编辑 session 成员」或「规则 8 批准」。成员点链接能编辑是因为他是成员、不是因为链接。
- **H5 多根 vs 单根数据结构**：现 tree 是 `root_id`（单数，kanban.ex tree），多根要改 forest（`root_ids`/去 root 概念）。数据模型改动。
- **H6 版主人是谁**：多根多主下，批准编辑(8)与删除兜底(H2)的「版主人」= **建板人（board 的 `Ezagent.ActionSet.Kanban.data_owner/1`）**，与节点认领者无关。需明确写死。
- **H7 未认领显示 vs stage**：规则 2 未认领节点不显示属性，但 stage（9 棒接力）是流程视图核心。未认领节点在 stage 分列视图放哪？定 stage = 结构属性（始终显示）还是认领后才有。

## 模型 vs 现有代码的差距（这是一次不小的重写）

现代码与本模型冲突处（`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`）：
- 建根硬门 admin（:265 `admin?(ctx)`）——本模型要「任何人可加根」。
- 无「加节点自动认领」；`claim` 只处理未认领（:449）。
- 无「取消认领」动作（有 `unclaim_node` 声明，语义待对齐规则 3 的 toggle）。
- 删除是 `drop_subtree` 自成一套授权——要重写成规则 5 的「整子树同一认领人 + 版主人兜底」。
- 属性可见性按认领状态门控（规则 2）= 前端 + get_tree 投影改动。
- 单根 → 多根 = tree 结构改动（H5）。
- 授权轴：owner 建板只拿 `Manage` cap 没拿 `Kanban` operate cap（见 layering-debt ⑧）——本模型「任何人操作」要重新想 cap 怎么发（编辑 session 成员都要 board operate cap）。

---

# 去 GitHub 化 + mirror/gh 出插件（同批决策，2026-07-15，用户定；原 `2026-07-15-kanban-degithub-decision.md` 已并入本文）

## 背景
生产部署在 **docker 隔离环境**。板侧边栏现有「登记 mirror token / gh token」两处，都不再需要。最新 main **已把 gh 做成独立 plugin**。

## 决策
1. **删掉板侧边栏的两处 token 登记**（mirror token 登记、gh token 登记）。
2. **mirror token 改成同步时临时填**：不再持久登记；同步到 mirror 时**弹框填名字**（token 在 plugin 里当场填）。
3. **同步 / gh 逻辑不在 kanban plugin 实现**。kanban plugin 只开放**手动填**：仓库地址、issue/pr 的 sha（纯数据链接，就是现存的 `register_pr` / `attach_code_file` 那类纯数据）。
4. **gh 走独立 gh plugin**——**方向确定但尚未落 main**（归 gaga AgentRuntime 域，在 watch；见 Allen note #1417 `docs/superpowers/notes/2026-07-15-demo-provisioning-constraints.md`：GitHub=插件、token 不进 agent 按用户代取、cap-gated、复用外部适配器插件形态）。**我之前判「gh=agent CLI」是错的，纠正：是 plugin。**
5. **本次 kanban 侧做法（用户 2026-07-16 定）**：**只保留 UI 功能、删掉现在的 gh 实现**（删板侧栏 gh token 登记 + 任何残留 gh 连接器逻辑），保留纯数据 repo 地址/issue-pr-sha 的手填与显示（register_pr/attach_code_file 纯数据）。**等 gh plugin 好了，kanban-assistant 再 dispatch 接入**（本次不实现 gh，也不写「检测 gh plugin」逻辑——那是 gh plugin 就绪后的接入活）。
6. 原因：docker 隔离生产环境，凭证/推送集中在专门 gh plugin（gaga 建），kanban 只管板数据 + 纯数据链接展示。
7. **note #1417 另一条与本改版对齐**：kanban cap 必须走治理 + `Ezagent.Cap.issue` 签发、**不直写 caps_json**（否则撞写侧 gate + 无尾 audit 拒）——正是本次发 operate 钥匙的姿势。

## 落地影响（待 rebase 到新 main 后核对）
- kanban plugin：删 mirror/gh token 登记的 UI + 存储；`sync_miro` 的 creds 从「持久登记」改「同步时弹框填名字」。（连接器现状见 `ezagent_plugin_kanban/.../behavior/kanban/connectors.ex`，GitHub 出站连接器此前已删、剩纯数据 link。）
- world 前端：板侧边栏去掉两处 token 输入。
- assistant 编排：新增「检测 gh plugin 在否 → push → dispatch gh plugin」流程（配方/skill 文本，非 kanban 代码）。
