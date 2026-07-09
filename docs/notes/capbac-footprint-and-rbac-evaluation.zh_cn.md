# CapBAC 占比与 RBAC 评估

**日期:** 2026-07-09 · **状态:** 设计研究(不落地实现) · **面向:** Allen
**待检验的假设(Allen 提出):** 当前 CapBAC 模型过于复杂;当下反复出现的问题是它造成的;
对**本系统**而言,经典 RBAC(角色→权限)是否更简单/更好?

> 英文原本:[`capbac-footprint-and-rbac-evaluation.md`](./capbac-footprint-and-rbac-evaluation.md)。
> 方法:先量化(数字,以 CI gate 为准),再基于证据(MEMORY + forensic notes,不看 commit 标题)
> 归因当下的 bug,再针对系统**真实需求**评估 RBAC,最后区分偶然复杂度与本质复杂度。这个模型是
> 深思熟虑的选择(Decision #154);先理解 WHY,再评判。

---

## 结论速览(headline)

1. **占比很小且高度集中,而非蔓延。** 紧核心的 cap **机制**约占 **prod LOC 的 ~2.1%**
   (~2,650 / 127,813);完整 CapBAC **面**(机制 + `required_caps` 声明 + identity 域授权 +
   全部 check/grant 站点)约 **7%** —— 而这个 7% 是 Allen 自己 ROI 研究的数字,不是新估。授权
   决策落在**正好两个 grep-gated 的 chokepoint**(dispatch step 5.5 做 check;
   `Ezagent.Identity.Grant.prepare/4` 做 grant),各由一条 CI gate 强制。权限是**集中的**,不是弥散的。

2. **当下反复出现的 bug 大多不是 cap 造成的。** 8 类问题里,**5 类与授权模型无关**
   (sync-dispatch / deploy-seed / read-model),**1 类是真实需求且 CapBAC 是解不是因**
   (#161 credential isolation),**2 类是真正的 cap 人体工学摩擦**(admin?/1、self-read #56)——
   而这两类都是**有界的过度应用**,且已在裁剪。**~2/8(~25%)由 cap 引起,且都不在 per-instance
   核心里。假设对运营 bug 流基本被证伪,对粗粒度授权人体工学部分成立。**

3. **RBAC 恰恰会在 #154/#161 刚买到的东西上倒退。** RBAC 的"admin 角色拥有全部权限"正是团队刻意
   拒绝的 god-boolean;per-tenant per-instance 作用域会逼 RBAC 退化成 per-object ACL(= 重新发明
   cap);delegation lineage(`granted_by`)在 RBAC 里没有对应物。**建议:保留 cap 核心,把粗粒度层
   显式做成角色(HYBRID —— 系统已经 ~85% 到位),继续 #154 的裁剪。不要迁移到 RBAC。**

---

## Part 1 — 量化

### 1.1 分母

| 指标 | 值 | 来源 |
|---|---|---|
| Prod LOC(`apps/*/lib/**/*.ex`,不含 test/deps) | **127,813** | `find … \| xargs wc -l` |
| Prod `.ex` 文件 | 562 | — |
| Umbrella apps | 23(`ezagent_core` + 9 domain + 12 plugin + web/cli) | — |
| Test LOC | ~123 K(≈ 1:1) | ROI note 2026-06-20 |

### 1.2 CapBAC 占比 —— 给出带边界的区间

诚实的数字是一个**区间**,因为 "CapBAC" 既可指原语机制,也可指整个授权面。两者都报,让 headline
经得起"你到底数了什么"的追问。

| 层 | 文件 | LOC | 占 prod | 是什么 |
|---|---|---|---|---|
| **紧核心机制** | 13 | **~2,650** | **~2.1%** | `capability.ex`(590)+ `capability/{match,normalize,parser,scope,unauthorized}.ex` + `capability_registry{,/defaults,/subjects}.ex`(`capability/` 簇 1,791)+ `system_principal{,.ex,/catalog.ex}`(~570)+ `identity/grant.ex`(296) |
| **+ 声明** | +32 | +~34 条 `required_caps/0` 单行 | | 与 Behavior 同址 —— 是模型**按设计运转**,不是散落 |
| **+ identity 域授权逻辑** | +~6 | (`behavior/identity.ex`、`admin_authority.ex`、`identity.ex`、membership grant) | | "授权"这个关切 |
| **完整 CapBAC 面** | — | — | **~7%** | **Allen ROI 研究(2026-06-20):"Authorization(CapBAC)~7% —— 薄但弥漫的横切关切"** |

**边界已命名:** 紧原语 ~2.1%;加上同址声明 + identity 域授权逻辑 + 全部 check/grant 站点,到达
Allen 的 ~7%。无论哪种口径,在 12.8 万行代码里 CapBAC 都是**薄薄一层** —— 对比:自建的
Kind/Behavior **运行时**约 30%,业务逻辑约 46%。

### 1.3 检查点集中度 —— 集中(以 gate 为准)

这是"是否过度复杂"的核心,且由 CI gate 判定,而非靠数数。

**授权 CHECK 在唯一 chokepoint。** `Ezagent.Kind.Runtime.handle_dispatch/4` 的 **step 5.5**
(cap check)+ **step 5.6**(workspace check)是 dispatch 被授权的唯一处。gate
`apps/ezagent_core/test/invariants/cap_check_only_at_chokepoint_test.exs` 跑 **12+ 条正则探针**
(`Capability.matches?`、`list_caps_for`、`grant_cap`、手写 cap 谓词、ambient `caller:/caps:`
ctx、手动 workspace 比较……),每条带一份**收窄的路径 allowlist**。chokepoint 之外命中即 CI 失败。于是:

| 信号 | prod 调用点 | 解读 |
|---|---|---|
| `Capability.matches?/2` | 21 | 1 处是 chokepoint 授权;其余是**核心原语本身** + **只读**的 preflight/展示/过滤(external_mirror gates、orchestrator 工具展示、credential resolver、CLI)—— 均被 allowlist 标为"合法实现或有据豁免"。**没有一处是散落在业务逻辑里的授权。** |
| `holds_cap` | 36 | 经 `Kind.holds_cap?/3`,由 chokepoint 消费 |
| `required_caps/0` **声明** | 34(32 文件) | **声明式**同址单行 —— 是声明"需要的 action",不是命令式检查 |

**Grant 构造在唯一 chokepoint。** `Ezagent.Identity.Grant.prepare/4` 是唯一构造
`grant_cap`/`revoke_cap` dispatch 的地方。gate `grant_dispatch_chokepoint_test.exs` 把
`@allowlist_size` 钉在 1(literal + 变量 action + 旧 URI 形态全扫)。**那 80 处 `grant_cap`
引用是对这唯一 chokepoint 的 wrapper 调用,不是 80 个构造点。**

**结论:权限是集中的**,落在两个 grep-gated chokepoint。`cap_check_only_at_chokepoint` 不是愿景,
而是一条带枚举豁免表的、通过中的 CI gate。这与"散落在业务逻辑里"正好相反。

### 1.4 计数与分布

| 维度 | 数 | 备注 |
|---|---|---|
| Behavior 数 | ~53 | `use Ezagent.Lifecycle`/`Behavior` |
| 声明的 action 数 | ~26 | `action:` 轴 |
| system principals | 15(+ genesis) | **封闭** Catalog,棘轮收敛至 genesis-only |
| unowned-authority minters | **0** | PR #824 达成(#154 原始目标已完成) |
| grant 站点 | 80 wrapper 调用 | 1 个构造 chokepoint |
| check 站点 | 1 授权 chokepoint | + 只读豁免 |

**`Capability` 引用分布(771 引用 / 158 文件):**

| app / 层 | 引用 | 占比 | tier |
|---|---:|---:|---|
| `ezagent_core` | 440 | 57% | core(机制) |
| `ezagent_domain_identity` | 248 | 32% | domain(授权 owner) |
| `ezagent_domain_session` | 168 | 22% | domain(membership/join) |
| `ezagent_domain_workspace` | 68 | | domain |
| `ezagent_domain_external_mirror` | 54 | | domain |
| `ezagent_domain_agent` | 51 | | domain |
| 各 **plugin**(cc/world/feishu/email/np/…) | 各 5–24 | **合计 ~5%** | plugin |

**关键发现:** cap 重量落在 **core + 三个持权域**(identity/session/workspace)。业务逻辑所在的
plugin 几乎不碰(各 5–24 引用)。**模型没有渗入 plugin 业务逻辑。** 这是三层边界在生效。

---

## Part 2 — 归因当下的问题(基于证据,诚实)

归因来自 Allen 自己的 forensic 记录(MEMORY + `docs/notes/`),不看 commit 标题。类别:
**(a)** 由 CapBAC 复杂度造成 · **(b)** cap 模型为满足**真实需求**带来的摩擦 · **(c)** 与授权模型无关
(sync-dispatch / deploy-shape / migration / read-model)。

| # | 问题类 | 类别 | 根因(证据) |
|---|---|:--:|---|
| 1 | **create_session 超时** | **(c)** | `np` recipe 的 numpy/sympy 冷启 `uv` provision(**实测冷启 9.6s**)+ 创建关键路径上的**同步 `ReadyGate.await(5_000)`**(`template_spawn.ex:640`,`mode: :call`)。与授权无关。改 `mode: :call → :cast`(PR #1202)修复。 |
| 2 | **skill packaging** | **(c)** | Deploy/seed 形态 —— `SkillRegistry` + seed 车道 + materialization(#1266)。分发问题,非授权。 |
| 3 | **seed three-state** | **(c)** | Migration/read-model —— `ConfigStore` 三态 seed 契约 + CI reflow gate(#1242);按唯一 `source_turn_id` 幂等升级。非授权。 |
| 4 | **cold-boot listing** | **(c)** | Read-model/projection —— durable session 列表(#1257)+ **cold-agent flavor 墙**(flavor 只从 spawn 时填充的内存 ETS 解析,冷 agent 读到 `:none`)。是水合/投影,非授权。 |
| 5 | **environment-shape 家族** | **(c)** | Deploy 形态 —— `create_session_via_class` 的 2 元 `instantiate` 形态、确定性默认模板名解析(#1244)。非授权。 |
| 6 | **#161 credential isolation** | **(b)** | 一个**真实**的多租户需求:同租户 B 能否把 A 的带凭据 agent 拉进 B 的 session 并消耗 A 的凭据?**CapBAC 是解,不是因**:member-cap 落在 `ctx.caller` 上 + 唯一 `handle_join` chokepoint 的**准入门**(R1.1 roster⟂authz ⇒ 无 member-cap ⇒ 无 `:receive` ⇒ 不消耗凭据),+ 向 manage-cap 持有者级联通知(PR #1178)。残余(socialware 模板 URI 直写 → **间接** pull)是**数据建模**问题 → 实为 (c),由 role-slot 模型解决,不动授权原语。 |
| 7 | **admin?/1 混乱** | 部分 **(a)** | `Identity.AdminAuthority.admin?/2` 是**4 谓词并集**(bootstrap-wildcard ∪ cross-workspace-admin-cap ∪ `home_is_system?` ∪ `member_of_system?`);codex **两次**指出其摆放问题(r3 层次违规、r4 policy-on-Behavior)。这是真实摩擦 —— cap 模型套在一个**粗粒度**的"该 caller 是不是 operator-admin?"问题上。**但这正是粗粒度层想变成 ROLE 的证据**,即它支持 hybrid,而非反对 cap 本身。 |
| 8 | **self-read 变通(#56)** | **(a)** 已裁剪 | Kind 读自己/兄弟 slice 本要一个 cap-check 原语(`authorize_in_process`)。Allen 裁定 **decision B**:Kind 内兄弟读**结构性授权 —— 不做运行时 cap 检查**,改由**静态 gate**(`sensitive_slice_read_test.exs`)。原语**从未落地**。过度应用被发现并**在不换模型的前提下移除**。 |

### 结论(Part 2)

- **5/8(63%)是 (c)** —— 与授权模型无关(sync-dispatch、deploy-seed、read-model)。运营 bug 流不是
  CapBAC 问题。
- **1/8 是 (b)** —— #161,CapBAC 是*堵住漏洞的机制*,不是因。credential-isolation 需求恰恰需要
  per-instance member 权限 + delegation。
- **2/8(25%)是 (a)** —— admin?/1 与 self-read #56。都是对本身健全的模型的**有界过度应用**,且
  **都已在裁剪**(#56 已完成;admin?/1 正是 hybrid 要形式化的粗粒度层)。都不触及 per-instance 核心。

**Allen 的假设:对当下反复出现的 bug 基本被证伪(它们是 deploy/sync/read-model,不是授权),对粗粒度
授权人体工学部分成立** —— 而这恰是 hybrid 建议针对的接缝。

---

## Part 3 — 针对本系统真实需求的 CapBAC vs RBAC

系统:多租户、spawn **持凭据的 agent**、需要 **per-instance** 权限(这个 cap 在**这个** session/agent
上)、**delegation 链**(`granted_by` lineage、#161 no-unowned)、**workspace** 作用域、以及 **#154
消除 god-mode system principal 的目标**。

### CapBAC 买到而 RBAC 无法干净表达的

| 能力 | CapBAC 怎么做 | RBAC 等价物 |
|---|---|---|
| **per-instance 作用域** | `instance:` 轴 = 具体 `%URI{}` 或 scope tuple `{:within_session, uri}` / `{:spawned_by, uri}` | 无 —— 角色是 subject 全局的;per-object 需要 per-object ACL |
| **owner-delegation lineage** | `granted_by`(entity)、#153 manager-delegation、#154 no-unowned | 无 —— RBAC 没有"谁授的、他是否可问责" |
| **action 轴** | `action:` 轴,配 `:any` 通配 | role→permission 可近似,但做不到 per-instance |
| **credential-isolation 向量(#161)** | member-cap 落 `ctx.caller` + 按持有 cap 判定的准入门 | 角色无法编码"对**这个具体** agent 实例的持有权限" |

### RBAC 会简化的

**粗粒度**场景。admin 讨论刚得出"**admin = 配置角色,business = member**" —— 这是*角色形*。
bootstrap/operator/config 权限、以及 operator 列表的 `admin?/1` 问题,天然是角色,不是 per-instance cap。
RBAC 会让这些在一处可读。

### RBAC 会倒退的

1. **"admin 角色拥有全部权限"正是团队刚拒绝的 god-boolean。** #154 整个计划就是*消除* god-mode
   system principal(`no_wildcard_system_principals` gate,minters → 0)。一个笼统 admin 角色把它原样请回。
2. **Per-tenant per-instance 作用域会逼 RBAC 退化成 per-object ACL —— 即重新发明 cap。**
   *(这是判别性问题。)* RBAC 说不出"这个权限在**这个** session 上",除非把权限挂到对象上;每对象都挂,
   你就用更差的名字重建了 cap 的 `instance:` 轴。
3. **delegation 链在 RBAC 里没有对应物。** `granted_by` lineage、manager-delegation、
   "谁管理 X → 级联通知"(#161 B)都依赖每次 grant 有个可问责实体。角色是成员关系,不是 grant,无处记录 granter。

### 诚实的 HYBRID —— 且系统已经 ~85% 到位

粗粒度 **role** 管 config/bootstrap/operator 权限 **+ cap 只用在真正需要 per-instance 或 delegation
之处**(session 参与、agent manage-cap、credential 准入)。系统已在这么走的证据:

- `User.default_caps/1` 现返回 **`[]`** —— 无常驻宽 cap;参与权在 **join 时按 session 由 owner 授**。
- `ActionSet.Manage` + `CreatorGrant.manage_cap` —— 创建者在 create 时得
  `cap(:<kind>, Manage, :any, instance)`(owner-of-instance = 角色形权限,实例作用域 cap)。
- Catalog 是**封闭、收缩**的 allowlist(15 → genesis-only),minters 已 0。

**数字支持的唯一具体动作**:把 `admin?/1` 4 谓词并集退成一个**显式命名的 admin role**,在权限本就粗
的地方拿到 RBAC 的可读性 —— 同时为 RBAC 表达不了的 instance/delegation 核心保留 cap。

---

## Part 4 — 偶然复杂度 vs 本质复杂度

抛开 RBAC 问题:哪些 cap 复杂度是**偶然的**(过度应用),可在**不换模型**下裁剪?

| 偶然复杂度 | 状态 | 量化 |
|---|---|---|
| **self-read #56** | **已裁剪** | Kind 内兄弟读结构性授权(decision B);`authorize_in_process` 原语从未落地;改为一条静态 gate。 |
| **宽 `default_caps` baseline** | **已裁剪** | 原为每用户一条宽 `session:any` cap;现 `[]` —— 与 per-session membership grant 冗余。 |
| **`:vm_internal` 受信路径** | 标记已存在 | `default_holds_cap?(:vm_internal, _) → true`(**33 处 `:vm_internal`**);VM 内受信路径上任何残留显式 cap-check 都被 #154 标记覆盖、可裁。 |
| **membership 已足时的 cap 冗余** | 有先例 | `SocialwarePublisherRead :snapshot/:history` **cap-EXEMPT** —— 活 membership 是唯一权威。可循此扩展到"持有 cap 只是重复 membership 检查"的地方。 |
| **system-principal Catalog** | 进行中 | 15 → genesis-only(`system_principal_elimination_test @remaining → []`);minters 已 0。每次移除是重新归属,不是删除。 |
| **admin?/1 4 谓词并集** | 候选 | 把 4 处散落谓词合并成一个命名 role 谓词。 |

**量化结论:** **本质**核心是 ~2.1%(紧)/ 7%(全)。**偶然**过度应用是一个**有界、可枚举的集合** ——
其中大部分(#56、default_caps)**已移除**,其余(`:vm_internal` 覆盖、Catalog 收敛)**正在 #154 计划下
推进**。过度复杂*不是*模型本身,而是团队已在削的、收缩中的过度应用尾巴。

---

## 建议

**保留 capability 核心。把粗粒度层显式做成 role(HYBRID)。继续 #154 裁剪。不要迁移到 RBAC。**

基于数字与 #154 理据:

1. **占比不足以支撑重写。** CapBAC 在 12.8 万行里仅 ~2.1% 紧 / ~7% 全,集中于两个 CI-gated
   chokepoint。对一个小而收敛、**围栏良好**的面做换模型,是高风险大改。

2. **当下 bug 不是 cap 造成的。** 5/8 是 deploy/sync/read-model(c);1 是 #161,CapBAC 是解(b);
   仅 2/8 是 cap 人体工学(a),且都有界、都在裁剪。换掉 CapBAC 修不了运营 bug 流的 ~0 个。

3. **RBAC 恰在 #154/#161 刚买到的东西上倒退。** per-instance 作用域 → per-object ACL(重造 cap);
   delegation lineage → 无对应物;笼统 admin role → #154 花整个计划消除的 god-boolean。

4. **系统已经 ~85% 是诚实的 hybrid。** `default_caps → []`、join 时按 session 授、`ActionSet.Manage`
   创建者权限、收缩中的 Catalog。要做的是让它**更**如此:(i) 把 `admin?/1` 4 谓词并集退成命名 admin
   **role**(在权限本粗处拿 RBAC 可读性);(ii) 完成 Catalog → genesis 收敛;(iii) 审计 33 处
   `:vm_internal`,确保没有受信 VM 内路径背着冗余 cap-check。三者都是 cap 模型**裁剪**,不是换模型。

---

### 来源

- Skill ref `.claude/skills/ezagent-developer/references/capbac.md`(端到端模型)
- `docs/notes/2026-06-16-capbac-system-principal-audit.md`(Decision #154,15 principal A/B 审计)
- `docs/notes/2026-06-19-fanout-principal-elimination-design.md`
- `docs/notes/2026-06-20-bespoke-core-framework-roi-decision.md`(~7% 授权数字)
- `docs/superpowers/specs/2026-06-14-cap-in-process-op-design.md`(#56 decision B)
- `GLOSSARY.md` Decision #153/#154 · `apps/ezagent_core/test/invariants/{cap_check_only_at_chokepoint,grant_dispatch_chokepoint,no_unowned_system_principal_grant}_test.exs`
- MEMORY:`project_agent_credential_isolation_audit`、`project_afk_goal_eliminate_sysprincipals`、`project_golive_prod_magiclink`、`reference_cold_agent_ui_verify_flavor_ets`
