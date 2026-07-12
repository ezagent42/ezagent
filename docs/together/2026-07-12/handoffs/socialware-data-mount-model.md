# Handoff → Allen：数据跨 session 共享 = 把 agent「挂载」进房间（mount 模型）

> **提出人**：jjkysy（做 kanban/dealscout 时撞出）· **日期**：2026-07-12 · **类型**：架构方向 proposal，需你拍板
> **一句话**：kanban/crawler 这类"管一份数据的 agent"，现在数据焊在自己身上，跨 session 共享要各种打补丁。建议改成——把这个 agent 像 U 盘一样**挂载进房间（session）**，房间里的人就能操作它（过权限）。数据不动（#155 不动），公开复用 hello。一个招式统一"团队操作 / 借给别的团队 / 对外公开"。
> **完整分析 + 弯路**：见 `../analysis/socialware-data-sharing-deep-dive.md`。

---

## 一、为什么提（怎么撞出来的）

做 kanban 时发现：一个 session 里的 AI 助手（cc-assistant）想操作看板 board，**根本没有指向 board 的权限，也没有任何机制给它**。往上追，这是 kanban / dealscout / autoservice / hello 共同的兜底缺口——今天全靠 admin 万能钥匙代跑或手写脚本。

我原来的 #1355 handoff 报的是"缺组合授权车道"，你写成了 #1357 SPEC。但深挖后发现：**#1357 解决不了它自己的招牌案例**——`operates` 只能指同一 Definition 里的成员角色，够不到 kanban board（board 是 workspace 级、不在任何 session 成员里的独立 actor）。#1357 §8 自己也把"workspace-global target"划到了 scope 外，留给"后续 lane"。

再往下挖，发现**复杂度的真正的根**不在授权车道，而在更底层的一个决定。

## 二、根本问题：Decision #155「数据焊 agent」撞上「跨 session 操作同一份数据」

- **kanban-as-a-role（Decision #127）当初是对的简化**：board 做成一个 agent、数据放它 slice，省掉一个独立 Kind。**但那是在"board 只被网页 UI 里的人类操作"的前提下**。当年"数据独立于操作它的 agent"这条路**根本没上过桌**。
- **Decision #155** 把"业务数据 = agent 的 slice = 唯一真相源"立成了原则，制度性地把数据焊死在 agent 上。
- **然后 socialware 来了**，要"另一个 session 的助手操作同一块 board"——撞上这道焊死的墙。我们这几轮折腾（operates → #1357 → data agent 进群 → data-member 车道 → link-token）**全是在给"数据焊 agent"打补丁**，越补越复杂。

## 三、系统里已经有两种相反的数据模型（这是关键证据）

| | kanban board | **upload（现成的更简单样板）** |
|---|---|---|
| 数据存哪 | 焊在 `kanban-manager` agent 的 slice | **独立 workspace 级 Kind** `uploads://<ws>/<id>`，不焊任何 agent/session |
| 跨 session | 撞授权墙（我们这几轮） | **天然复用**：URI 引用 + cap，一份数据多处引用 |
| 公开 | 无 | **签名下载链接，可过期**（"公开链接=签名授权"现成先例） |

**upload 早就是"数据是数据、操作它的是另一回事"的现实了**，只是 kanban/crawler 没走这条路。而且 **upload 本身就是 Decision #155 的一个已存在例外**——所以松动 #155 不是推翻，是扩大它的例外范围。

## 四、建议模型：mount（把 agent 挂载进房间）

**不抽新 Kind、不迁数据、#155 不动。** 就把"操作数据的 agent"像 U 盘/硬盘分区一样挂载进房间：

- kanban/crawler = 管一份数据的 agent，数据在自己 slice（不动）。
- **`mount(agent, room, permission)`**：把 agent 挂进房间。房间里的人就能操作它——**过权限检查**。
- 一个招式统一三件事：
  - **自己团队操作** = 挂进团队房间（permission=operate）。
  - **借给别的团队** = 同一个 agent 也挂进另一个房间（Unix bind-mount：一份数据、多个挂载点）。
  - **对外公开** = 挂进"陌生人也能进"的房间（`web_anon_access:true`）、permission=read → **直接复用 hello 现成的匿名 render cap**。

**好在哪**：复用"房间（session）"这个系统里已有的共享+可见性+成员单元，不重新发明；数据不动；三种共享收成一个概念。比"抽独立 Kind"和"data-member 进群车道"都简单。

## 五、要你拍的三件事

1. **认不认这个方向**（数据焊 agent → 跨 session 靠补丁；改成 mount → 数据不动、房间做共享单元）？这背后是**扩大 Decision #155 的例外**（承认"需要被多方操作的业务数据，其 agent 可被挂载到多个房间"），upload 本身就是 #155 的先例。

2. **★铁律要认**：**mount ≠ 进群聊天**。挂进来的 agent 是"被操作的工具"，不是"聊天成员"。房间要分两轴——**聊天成员** 和 **挂载的工具**。只要 mount 不是"join 聊天路径"，就**永不触发 RF-6**（没人 join 聊天 = 不会白得 receive cap = 无 principal 泄漏）。这条是整个方案能不能成立的命门。

3. **★选择题：房间成员怎么获得"操作挂载 agent"的权限**——
   - **(a) 用时临时查**：授权点（`runtime.ex` step 5.5）加判定"caller 是房间 R 成员 AND 目标挂载在 R 且权限≥所需"。像 Unix 开文件查挂载表。生命周期最干净（卸载=删一条记录，权限立即消失），但**动最核心的授权代码**。
   - **(b) 挂载时发钥匙**：挂进来时 `Cap.issue`+absorb 给房间成员发 cap，卸载 revoke。复用现成 I12 合规机制、不动核心，但要管好发/收同步。
   - 我倾向 (a)（贴合挂载表心智、生命周期干净），但 (a) 碰授权核心，你定。

## 六、附：不阻塞的现状

- **公开那半几乎现成**：hello 的 `visibility_policy` + 匿名 render cap 已经是"公开访问=一种 cap"。board/crawler 把自己的 render view 挂进 `web_anon_access:true` 的房间就能公开，几乎零平台改动（一个待验证：session 的 view 能不能读到挂载在别处的 agent 数据——kanban 的 render 已经跨实例枚举，应该 ~90% 现成）。**操作/借用那半**才需要上面的选择题。
- **相关 PR**：#1355（原 gap handoff）、#1357（你写的 SPEC，operates 车道——仍对，但只覆盖"同 Definition 成员间"，够不到 workspace 级 board，本 handoff 是它够不到的那半）。dealscout #1301 已 rebase 到最新 main、gate 全绿，核心闭环也卡这个机制。
- **约束**：任何新授权都必须走 CapBAC Phase 3 的 `Cap.issue`+absorb（I12），老写法撞 gate。

## 七、我不确定 / 需你判断的

- 松动 Decision #155 是 ARCHITECTURE 层的事，只有你能拍。我只坐实了"upload 已经是 #155 的例外、mount 是把这个例外一般化"，没有替你改 #155。
- 选择题 (a) 碰授权核心（confused-deputy 防护），要不要走 (a)、以及怎么保证挂载授权仍实例精确，是你的地盘。
- "借给别的团队"（cross-room）如果近期没有真实需求，可以先只做"公开"那半 + 把 mount 作为方向写死，操作/借用缓做——这个 YAGNI 取舍也请你定。
