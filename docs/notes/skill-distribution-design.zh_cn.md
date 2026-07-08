# 部署态 Agent 的 Skill 分发 — 设计选项

> 设计调研，2026-07-08。分支 `docs/skill-distribution-research`。
> 英文版：[`skill-distribution-design.md`](skill-distribution-design.md)。
> 状态：**调研 / 建议** —— 本分支不含实现。
> Rev 2（codex 对抗审查后）：授权模型显式化并分阶段（§5.3）；socialware 先例对齐到
> 当前的单源 deploy-seed 通道（§2.5、P2）；ConfigObject 理由修正为目录树论证
> （§5.4）；point-fix 确认为 ezagent-deploy `1d5aeca`（§1）；追加实现约束（§7）。

Allen 的方向：*"这个理论上应该由 recipe 去管理"* —— agent 如何拿到 skill 必须由
**recipe** 层治理，而不是临时的文件拷贝。本文梳理现状、权衡三种分发方案、给出一个
带分阶段迁移的推荐。

---

## 1. 事故（为什么这是分发设计缺口，而非打包 bug）

`mix release` **只打包每个 app 的 `priv/`**（Dockerfile.prod 第 71 行）。仓库根的
`.claude/skills/` 树不在任何 app 的 `priv/` 里，因此从 `_build/prod/rel/ezagent`
里被丢掉。prod 运行镜像是 `COPY --from=builder /app/_build/prod/rel/ezagent ./`
（Dockerfile.prod 第 107 行）—— 只有 release。`COPY . .` 带进 *builder* 的源码
`.claude/` 从不进入 *runtime*。

spawn 时，orchestrator agent 需要 `ezagent-session-orchestrator` skill 目录。
`OrchestratorBootstrap.resolve_skill_source/1`
（`apps/ezagent_plugin_cc/lib/ezagent/template/orchestrator_bootstrap.ex:266`）
把 skill ref 解析成源目录的方式，是**从 cc 插件的 `priv_dir` 向上逐级 walk**，
找 `.claude/skills/<ref>/SKILL.md`。在每个 release 镜像里都找不到 →
`{:skill_source_not_found, []}` → `role_degraded` → **每条 deploy channel 上
session create 都死。**

**point-fix（已确认）：ezagent-deploy 提交 `1d5aeca`** 在镜像构建时把
`ezagent-session-orchestrator` 拷进 `apps/ezagent_plugin_cc/priv/.claude/skills/`
—— 于是 `priv_dir` walk 在其第一个候选处就命中
`<priv>/.claude/skills/<ref>/SKILL.md`。与 Dockerfile.prod 66-69 行同族——那几行
已经把 feishu WS sidecar `npm install` **进 `priv/`** 好让 release 打包它。它硬编码
了**单个** skill；阶段 1（§6）退休的正是这个机制。

仓库根 `.claude/skills/` 有 **25 个 skill 目录**（外加一个 `SUPERPOWERS_VERSION.md`
标记文件）。任何未来 recipe 只要引用**第二个** skill 就会同样地崩。修复必须泛化
skill **内容分发**，而不是给一个 ref 打补丁。

---

## 2. 现状图 —— 所有"agent 运行时需要某个 artifact"的路径

### 2.1 recipe 层 —— 声明其实**已经解决**（且已落 `main`）

`Ezagent.Agent.Recipe`（`apps/ezagent_core/lib/ezagent/agent/recipe.ex`）——
flavor 无关的 sandbox 内容 recipe（task #54；`Ezagent.Role` → `Recipe` 改名 #127）。
它的 moduledoc 正是 Allen 引用的论点：

> **sandbox 的内容是 RECIPE；sandbox 如何被加载是 FLAVOR。**

该 struct 已经带一等公民字段 **`skills: [skill_ref :: String.t()]`**（连同
`plugins`、`prompt`、`script`、`behaviors`、`requested_caps`、`contributions`、
`session_template`、`config`）。recipe **作为数据**存储 —— 一个 `ConfigObject`，
`subject = recipe:<name>`、`key = "recipe"`，由 `Ezagent.Agent.RecipeRegistry`
（`apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex`）read-through
解析：

- `lookup/2`：ETS 缓存 → 调用方 workspace 的 `ConfigStore` → **system workspace
  兜底** → 经 `Recipe.new/1` 复水。这就是"workspace 作用域 + 可 fork"：租户在 fork
  出自己的之前，看到的是 system 内建。
- `seed_role_if_absent/2`：经**三态 seed 契约**（见下）把内建 recipe 播种进 system
  workspace，override-safe。

**所以 recipe 已经声明了 agent 需要"哪些"skill。** 缺的不是声明。今天所有播种的
recipe（各插件的 `roles/0`：cc、codex、hello ×3、kanban）总共只引用**一个** skill
—— `OrchestratorRecipe` 写着 `skills: ["ezagent-session-orchestrator"]`
（`orchestrator_recipe.ex:110`）；hello/kanban 的 recipe 不带 skill。

### 2.2 缺口 —— skill ref → skill **内容** 的解析

`Recipe` 用**名字**声明 skill。`OrchestratorBootstrap.install_role_sandbox/2`
消费 `sandbox_content.skills`，对每个 ref 调 `resolve_skill_source/1` 把名字变成
**磁盘上的源目录**，再 `File.cp_r` 进 `<config_dir>/skills/<ref>`。今天的解析
（`:266`）：

1. 配置 override —— `:ezagent_plugin_cc, :role_skill_sources`（`ref => abs_path`
   映射）或 orchestrator 专用的 `:orchestrator_skill_source`。手工、逐 ref、prod
   下未设。
2. 否则**从 cc 插件 `priv_dir` 向上 walk** 找 `.claude/skills/<ref>/SKILL.md`。

**没有任何 skill 目录 / 注册表 / store。** pr6 设计笔记正是标记了这点：
*"通用的 name→source skill registry 不在 PR-6 范围内"*
（`docs/notes/pr6-desired-skills-caps.md:135`）。**这就是缺的那一层。**

`AgentTemplate` 内容上的 `desired_skills` 是**第二个、domain 层**的 skill 名声明——
但它**被接线却从不被消费**（没有任何 flavor 的 `instantiate/3` 读
`"desired_skills"` 数据键）。它缺的是同一个后端：一个在部署态节点上无从解析成字节的
名字。

### 2.3 config_dir 物化 —— skill 字节落进 agent 的地方

`Ezagent.Credential.HomeRuntime`
（`apps/ezagent_core/lib/ezagent/credential/home_runtime.ex`）负责每 agent 的
config_dir 物化：`stage_and_swap/7` 做 `cp_r(reference_dir, staging)` → overlay
凭据 → 写 `CLAUDE.md` → `chmod` → 写 `.ezagent-config-complete` 标记 →
`Materializer.atomic_replace(staging, target)`。靠标记幂等。今天 orchestrator 的
skill 拷贝是 `OrchestratorBootstrap` 里一个**独立的** spawn 后步骤，在这个原子
swap **之外**。

### 2.4 参考模型 A —— np/uv 供给（recipe → spawn 时的 artifact）

`apps/ezagent_plugin_np` 给 np agent 供给 Python 环境：

- **声明与 artifact 同在，打包进 `priv/`**：依赖集是 `priv/python/np_compute_server.py`
  里的 PEP-723 头（numpy/sympy）；release 经 `priv/` 打包脚本。Elixir 只指向文件。
- **共享、内容寻址的供给**：`uv run --script` 供给进 uv 的机器级全局缓存
  （`~/.cache/uv`），非每 agent。首个 agent 付 ~9.6s 冷启动；此后同机每个 np agent
  命中 sub-100ms 热缓存。
- **每 agent = 仅活进程**；脚本源从 `priv/` 只读共享。
- **有意的同步设计。** Domain.Python 的 `init/1` 在真正 `python.ping` 之前阻塞才翻
  ready —— SPEC 明确拒绝了异步 `{:continue, :spawn}`，以避免**假就绪**窗口。（对调研
  简报"倾向 fire-and-forget/async"的更正：np 是*同步换正确性*的先例，而非异步先例。
  见 §5.5。）

**对 skill 的启示：** 把 artifact + 其 manifest 打包进 `priv/`（release 原生默认）；
把昂贵/共享的部分放机器级全局，而非每 agent。

### 2.5 参考模型 B —— socialware deploy-seed 通道（单源，播种一次）

这是"把构建后内容分发到部署态节点、且不重建 release"的最近类比——而且**当前**模型
比双源 overlay 更简单：一个运行时来源，从 release 播种一次。

- **单源。** `Ezagent.Socialware.ManifestSeed.scan_all!/1`
  （`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex`）在
  boot 时跑一次（由最后启动的 app 触发），只扫**恰好一个**目录：
  `system://socialware` = `$EZAGENT_HOME/<profile>/socialware/*/manifest.yaml`，
  经 `Ezagent.System.FsResolver` 解析（绝不裸用 `Ezagent.Home`）。其 moduledoc
  明说：*"部署目录是唯一的 manifest 来源"* —— 曾经的 app-`priv/socialware/` 扫描
  通道已被 deploy-seed 迁移**退休**（autoservice #1231、hello #1233），被
  `socialware_priv_manifest_files` 架构闸门（#1246）**禁止**，其死掉的 boot 扫描
  分支在 #1227 中删除。
- **打包默认是 SEED 源，不是运行时来源。** 出厂旗舰包放在
  `ezagent_web/priv/socialware_seed/<name>/`，由 `Ezagent.Home.SocialwareSeed`
  （`apps/ezagent_core/lib/ezagent/home/socialware_seed.ex`；在 `home.init` +
  boot 兜底时运行）**一次性、幂等地**拷进部署目录。已存在的包目录**不覆盖**——
  尊重运维手改。
- **`$EZAGENT_HOME` 是逃生口**：运行时填充、bind-mount 的目录
  （`EZAGENT_HOME=/data`），**不**属于 release 镜像（`docker/entrypoint.prod.sh`：
  *"release 没有 `mix ezagent.home.init`"* —— entrypoint 自己 `mkdir -p` 骨架，
  因为干净的 home 起始为空）。内容可在构建后增/改 —— 正是 skill 需要的性质。
- **三态（实为四态）seed 契约**（*数据*层）——
  `Ezagent.Socialware.ConfigStore.seed_object_upsert/1`
  （`apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex`），
  经 `ContentHash.of/1`（键排序、字符串化、SHA-256）内容哈希：
  1. **absent** → 播种一次（race-safe）→ `:seeded`
  2. **same**（哈希相同）→ `:exists` 空操作
  3. **outdated + seed-family**（`source_turn_id` 以调用方的 `seed_family_prefix`
     开头）→ 升级：追加新对象 + 重指 → `:seeded`
  4. **outdated + 非 seed-family**（用户/CR override）→ `:exists`，**override 保留**。

**对 skill 的启示：** 把默认放进 `priv/` *seed 源*，一次性拷进唯一的
`$EZAGENT_HOME` 运行时目录，boot 时只扫**一个**目录，用内容哈希 seed-family 契约
reconcile 升级 vs 运维手改。单一运行时来源让解析器保持平凡。

### 2.6 "agent 运行时需要 artifact"的路径枚举

| 路径 | 声明在哪 | 如何解析/分发 | release 安全？ |
|---|---|---|---|
| Orchestrator skill | `Recipe.skills`（代码 recipe） | 从 cc `priv_dir` 向上 walk | **仅靠 point-fix `1d5aeca`**（本事故） |
| `desired_skills`（domain） | `AgentTemplate` 内容 | *从不消费* | N/A（死码） |
| Recipe `plugins` | `Recipe.plugins` | fail-closed（未实现） | N/A |
| Recipe `script`（py-role） | `Recipe.script`（内联数据） | 写进 config_dir | 是（数据，在 recipe 里） |
| np Python 依赖 | `priv/` 脚本里的 PEP-723 | uv 机器级全局缓存 | 是（`priv/` + 缓存） |
| Socialware manifest+包 | 部署目录（`$EZAGENT_HOME`） | `priv/socialware_seed` → 一次性 `Home.SocialwareSeed` 拷贝 → 单目录 `ManifestSeed` 扫描 | 是（seed 一次 + 单源） |
| Recipe 自身 | `ConfigObject`（数据） | RecipeRegistry read-through + seed | 是（数据 + seed） |
| 每 agent 凭据/CLAUDE.md | template config_dir 引用 | HomeRuntime stage_and_swap | 是 |

**唯一飘红的行是 skill。** 其他要么是 recipe 里的数据、要么打包在 `priv`、要么走带
seed 契约的 `$EZAGENT_HOME` deploy-seed 通道。skill 是唯一**没有分发后端**的运行时
artifact —— 它依赖 release 会抹掉的 dev 树文件布局（今天靠一个硬编码的镜像构建期
拷贝打补丁）。

---

## 3. 精确陈述缺口

skill 是一个**多文件目录树**（`SKILL.md` + 脚本/引用），在 recipe 里以**名字**引用。
在一个只有 release 镜像 + `$EZAGENT_HOME` 的部署态节点上，我们需要：

- **不依赖 dev 仓库树**的 name → 源目录解析；且
- 字节的**分发通道**：默认 release 原生，外加一条部署后路径，让运维能在**不重建
  release** 的前提下增/改一个 skill；且
- 把被引用的（非全部）skill **物化**进每个 agent 的 config_dir，**recipe 驱动**、
  带版本、并有**显式的发布授权模型**（§5.3 —— 谁可以把字节放进 recipe 能引用的
  store）。

用 recipe 的语言说：recipe 是**声明权威**（`skills: [ref]`）；我们缺的是 recipe 层
针对 skill 的**内容后端** —— 正是 `RecipeRegistry` 经 `ConfigStore` read-through
recipe *数据* 的对偶。

---

## 4. 方案

三个轴贯穿全文：**可寻址**（解析器能找到任何被引用的 skill）≠ **已打包**（进 release）
≠ **已物化**（拷进某个 agent —— 永远 recipe 驱动，只有被引用的 skill）。保持区分。

### 方案 (a) —— 纯 `$EZAGENT_HOME` skill store，无打包 seed

skill 只放在 `$EZAGENT_HOME/<profile>/skills/<ref>/`，全靠运维填充，boot 时扫进
`SkillRegistry`（索引 = `ref → {source_dir, content_hash}`），spawn 时物化进
config_dir。

- **声明：** `Recipe.skills`（不变）。
- **版本：** 目录闭包上的三/四态内容哈希契约。
- **冷启动：** 无固有成本（拷贝是 KB 文本）；但**干净的 release 镜像 home 为空 →
  没有 skill → 首次 boot 事故重演**，直到运维填充部署目录。
- **租户/授权：** store 是**节点全局**的 —— `<profile>` 是部署轴，不是 workspace，
  且 `System.FsResolver` 按契约**没有每调用方授权轴**（其 R-3）。称之"租户安全"
  会是过度声明（§5.3）。
- **walk-up：** 消亡。
- **结论：** 逃生口正确，**默认错误** —— 对任何未预置的部署重演生产事故。作为唯一
  机制被否决。

### 方案 (b) —— 构建期把被引用闭包打包进 `priv/`

在 `mix release` 前把运行时 skill 子集塞进某 app 的 `priv/`（泛化 point-fix
`1d5aeca` / feishu-node_modules 步骤）；解析器永远直读 `:code.priv_dir`。

- **声明：** `Recipe.skills`（不变）。
- **版本：** 就是 release 版本 —— **skill 改动需要重建 release**；recipe 无法在
  部署后加 skill。
- **冷启动：** 无。
- **租户/授权：** 从 `priv/` 只读共享；隐含 system 审核（CI 构建了什么就是什么）；
  完全没有部署后或每租户创作。
- **walk-up：** 消亡（被 `priv/` 查找取代）。
- **结论：** release 原生且自足，但**僵硬** —— recipe 层无法治理它没随 release 发的
  skill。仅作 *seed 源那一半*可用。

### 方案 (c) —— 打包 seed 源 + 唯一 `$EZAGENT_HOME` store（socialware 通道）✅

照搬当前 socialware deploy-seed 模型，应用到 skill：

1. 运行时 skill 随 release 放在 **`priv/skills_seed/<ref>/`** seed 源里；
2. `Ezagent.Home.SkillSeed` 在 `home.init` + boot 兜底时把它们**一次性、幂等地**
   拷进 **`$EZAGENT_HOME/<profile>/skills/<ref>/`**；
3. boot 扫描这**一个**目录构建 `SkillRegistry` 索引
   （`ref → {source_dir, content_hash}`），经内容哈希三/四态契约 reconcile；
4. 物化经 registry 读 `Recipe.skills`，折进 HomeRuntime 的原子 swap。

- **声明：** `Recipe.skills` —— recipe 是唯一声明权威；`SkillRegistry` 是它的内容
  后端，正如 `RecipeRegistry` 是 `ConfigStore` 上的 read-through。
- **版本：** 索引层三/四态，字节层用 seed-family 判别（release 升级 vs 运维手改 ——
  §5.4）；**且**干净镜像自足（boot seed 从 `priv/` 填充空 home）。
- **冷启动：** 无（KB 文本拷贝，同步 —— §5.5）。
- **租户/授权：** **显式且分阶段** —— 先只有 system 审核的 store；workspace 作用域
  的自定义 skill 是后续阶段，走 `resource://` + CR 治理轨道（§5.3）。
- **walk-up：** 降级为 dev-only，随后移除。
- **解析器简单性：** seed 拷贝之后只有**一个运行时来源** —— 解析时没有 overlay
  优先级逻辑。
- **结论：** 继承 socialware 已用来解决同一问题的那条通道。**推荐。**

---

## 5. 推荐 —— 方案 (c)

### 5.1 论点（判别式，而非模式匹配）

skill 分发设计必须同时满足**两个**互相拉扯的约束：

1. **干净的 release 镜像必须自足** —— orchestrator 必须能在 `$EZAGENT_HOME` 为空时
   首次 boot 就 spawn。这正是事故违反的约束。→ 逼出**随 release 发的 seed 源**
   （排除纯 (a)）。
2. **平台必须能在不重建 release 的前提下增/改 skill** —— 这就是"由 recipe 去管理"
   的运维含义：recipe 点名一个 skill，满足这个引用不应要求发新镜像。→ 逼出
   **`$EZAGENT_HOME` 下的运行时 store**（排除纯 (b)）。

seed-一次-然后-单源的通道同时满足两者 —— 且不是新发明：它逐字就是**当前**的
socialware 形态（`priv/socialware_seed` → `Home.SocialwareSeed` 一次性拷贝 →
单目录 `ManifestSeed` 扫描）。我们是在继承已经解决了这一类问题的通道，套用到 skill
目录树而非 manifest 包上。

### 5.2 形态 —— recipe 治理，而非平行子系统

```
Recipe.skills: [ref]            ← 声明权威（已落 main）
        │  （物化 read-through）
        ▼
SkillRegistry.resolve(ref) → {source_dir, content_hash}
        │  唯一运行时来源: $EZAGENT_HOME/<profile>/skills/<ref>
        │  （home.init/boot 时由 Home.SkillSeed 从 priv/skills_seed/<ref>
        │   一次性填充；运维可在部署后增/改目录）
        ▼
HomeRuntime.stage_and_swap  ← cp_r 被引用 skill 进 config_dir/skills/<ref>，
                              在同一个原子 swap + 幂等标记内
```

`SkillRegistry` 有意做成 `RecipeRegistry` 的**镜像**：同样的 boot-seed 通道、同样
的内容哈希 reconcile、同样的未知 ref fail-loud 语义。recipe 治理*什么*；registry
是 recipe 层针对*字节*的内容后端。它不是贴在 recipe 旁边的东西——它就是同一个
read-through-over-store 设计的 skill 那一半。

### 5.3 授权模型 —— 谁可以向 store 发布（显式、分阶段）

store 目录经 `Ezagent.System.FsResolver` 解析，而该缝**按契约无授权**：system
artifact "没有天然 `<ws>`，也没有每调用方授权轴"（R-3，
`apps/ezagent_core/lib/ezagent/system/fs_resolver.ex`）。`<profile>` 是部署轴，
不是租户边界。所以 `$EZAGENT_HOME/<profile>/skills/` store 是**节点全局**的，
任何 workspace 的 recipe 都能点名其中任何 ref。称之"租户安全"是错的。因此授权模型
显式分两个阶段：

**P1–P3（本设计）：skill store 只有 SYSTEM-workspace 审核内容。**

- 内容是**平台 artifact**：经 `priv/skills_seed` 发布（CI 构建、代码评审过），或由
  **管理员/部署流水线**发布进部署目录。这符合这些 skill 今天的本质 ——
  `ezagent-session-orchestrator` 是平台基础设施，不是租户内容。
- **过渡期不变式：** recipe 只能引用 **system store 里的 ref**；未知/未授权 ref 的
  解析**响亮失败**（`{:skill_source_not_found, ref}` → `role_degraded` + 遥测，
  绝不静默跳过）。**没有运行时可写的发布面** —— store 只由 `home.init`/boot seed
  和有节点访问权的运维写入。

**后续阶段（本文明确不含）：workspace 作用域的自定义 skill。**

- 存储移到**租户授权缝**：`resource://<ws>/skills/<ref>`，经
  `Ezagent.Resource.FsResolver.resolve/2` —— 其每类型授权检查要求调用方已认证的
  `<ws>` 等于 URI 的 `<ws>`。
- 发布走 **CR 治理路径**（`Ezagent.ConfigGovernance.Socialware` 的
  `open_cr → stage → publish` 模式），租户创作的 skill 有暂存、评审、发布与审计
  轨迹 —— 且创作边界的信任守卫可以 fail-closed 地拒绝代码注入内容（skill 目录带
  脚本；这正是 `RecipeRegistry.validate_data_role_recipe/1` 已对 data-role
  fail-close 的 `script` 字段信任问题）。
- 届时解析顺序变为：workspace store → system store 兜底 —— 镜像
  `RecipeRegistry.lookup/2` 的调用方-ws → system-ws 顺序。

### 5.4 版本 —— seed 契约需适配（索引 vs 字节）

`seed_object_upsert/1` 哈希的是单个 `ConfigObject` 的 **body** —— 这对**索引**直接
适用。**字节**还需要一个判别器：

- **索引条目**是一个 `ConfigObject`（`subject = skill:<ref>`、`key = "skill"`、
  body = `{ref, content_hash, shipped_hash}`）—— 这逐字买到四态契约
  （absent / same / outdated-可升级 / override-保留），带 `seed_family_prefix`
  （如 `"skill-seed"`）。
- **为什么索引不携带 skill 字节：** skill 是**目录树** —— 多文件、脚本、可执行位、
  可能的符号链接 —— `ConfigObject` 的 JSON-map body 表达不了。（这是*形状*论证，
  **不是**"Postgres 不放 blob"红线论证：taxonomy 红线针对的是二进制 blob，而 skill
  内容是 KB 级文本，放进 ConfigObject 完全没问题。曾权衡过针对*单文件* skill 的
  ConfigObject 承载变体 —— body = `%{relpath => content}` —— 暂且搁置：在 P1–P3
  按形状拆分 store 毫无收益，因为那时每次 store 写入都已是 system 审核的。到
  workspace 自定义的后续阶段它才有吸引力 —— 搭 ConfigObject 免费获得 CR 治理、
  override-safety 与审计；届时再议。）
- **内容哈希覆盖目录闭包**：排序的 `relpath → file-hash` 对集汇总 —— 改名和删除都
  会改变哈希；每文件哈希输入含可执行位，符号链接哈希其目标路径（IC-1）。
- **字节层的升级 vs 运维手改：** `Home.SocialwareSeed` 的一律不覆盖是保守默认，但
  skill 需要 seed-family 升级：把**出厂哈希**存进索引；boot seed 时，若磁盘目录仍
  哈希到上次出厂哈希、而新 `priv/skills_seed` 不同 → **升级**（替换目录、更新索引）；
  若磁盘目录已偏离上次出厂哈希 → **运维手改，保留**（`:exists`）—— 四态契约应用到
  字节。

### 5.5 冷启动与同步/异步 —— 反驳简报

调研简报说"倾向 fire-and-forget/async（记住 np 5s 教训）"。**对 skill 这不适用，
我们应明说：**

- skill 是 KB 级**文本**（`SKILL.md` + 几个脚本）。`cp_r` 是亚毫秒 —— 没有 9.6s
  np-uv 的等价物要藏。
- np 自身的先例是**有意同步**以避免假就绪窗口；异步是在这条教训上*倒退*，而非应用。
- 因此：**同步物化，折进 HomeRuntime 的 `stage_and_swap`** —— 一个原子 swap、一个
  `.ezagent-config-complete` 标记，绝不暴露半填充的 config_dir。这个统一正是让
  `OrchestratorBootstrap` 里的 walk-up 拷贝干净消亡的前提。
- 只对病态情形加护栏：若某被引用 skill 的闭包异常大，封顶并**尽力而为**降级
  （像 np 的 `activate/2` 留下 DEGRADED-但存活的 agent），而非阻塞 spawn。

### 5.6 什么消亡

- `OrchestratorBootstrap.search_skill_source/1` 的**从 `priv_dir` 向上 walk** →
  prod 中移除；仅保留为 **dev-mode 兜底**（dev 树有仓库根 `.claude/skills/`），
  像 `manifest_boot_scan` 的 `:dev/:prod`-only 开关一样门控，待 `SkillRegistry`
  成为权威后删除。
- 手工的 `:role_skill_sources` / `:orchestrator_skill_source` app-env override →
  被 registry 取代（仅留作测试缝）。
- `OrchestratorBootstrap` 里独立的 spawn 后 skill `cp_r` → 折进
  `HomeRuntime.stage_and_swap`。
- **ezagent-deploy 提交 `1d5aeca`**（把单个 skill 镜像构建期拷进 cc
  `priv/.claude/skills/`）→ 阶段 1 退休。

---

## 6. 分阶段迁移

### 阶段 1 —— release 自足（退休事故 + point-fix `1d5aeca`）

**目标：** 每个 recipe 引用的 skill 都在**每个 release 镜像里可寻址**，经**通用**
解析器；硬编码 point-fix 与 orchestrator-only 特判都消失。

1. 建立 **`priv/skills_seed/<ref>/`** seed 源，把**运行时 skill 子集**签入仓库
   （checked in，不是镜像构建期拷贝）。子集**派生而非手数**（IC-3）：枚举所有
   `roles/0` seed 的 `Recipe.skills` —— 今天恰好得到
   `["ezagent-session-orchestrator"]`（cc + codex 都播种 `OrchestratorRecipe`；
   hello/kanban 的 recipe 不带 skill）—— 外加 `ezagent-socialware`（若/当某
   socialware 创作 recipe 引用它）。其余 ~23 个仓库根 skill 是 **Claude-Code
   dev-harness skill**（brainstorming、TDD、writing-plans……），**绝不能**进 prod
   agent 镜像；它们留在 dev 树里可解析，只在某 recipe 引用时才加入 seed。
2. 把 `resolve_skill_source/1` 的 walk-up 换成**通用**的 seed-源查找（任何 ref、
   无 orchestrator 硬编码）；orchestrator ref 不再特殊。
3. **退休 ezagent-deploy `1d5aeca`** —— 镜像构建期拷贝删除；seed 源原生随
   仓库/release 发布。
4. 不变式测试：一个 `MIX_ENV=prod` 形态的解析（无 dev 树、无配置 override）能解析
   **从播种 recipe 枚举出的每个 ref**，且**若 walk-up 是唯一路径则失败** —— 即能
   捕获本事故的那个测试，与第 1 步同源于 `Recipe.skills` 枚举。

**出口** —— 用 §4 的轴区分（*可寻址* ≠ *已打包* ≠ *已物化*）读"全部 20+ skill 可
寻址"：

- **可寻址：** 解析器是**通用**的 —— 没有 skill 被特判，故*任何* recipe 引用的 ref
  都走同一路径解析（这是解析器的性质，而非发 25 个目录的性质）。
- **prod 镜像里有字节：** **派生的运行时子集**在 seed 源里。dev-harness skill 留在
  dev 树里可解析；它们只在**被某 recipe 引用时**才需要 prod 字节，届时第 1 步的
  派生把它们拉进 seed（第 4 步的不变式测试也随之覆盖它们）。
- 每条 deploy channel 上 session-create 转绿，且 `1d5aeca` 已删除。

### 阶段 2 —— `$EZAGENT_HOME` skill store + `SkillRegistry`（socialware 通道）

**目标：** 部署后不重建 release 就能增/改 skill —— 走 seed-一次-然后-单源通道，
而非双源 overlay。

1. 给 `System.FsResolver` 的闭合 `<type>` 目录加一个 `skills` 条目 + 一个
   `Ezagent.Home` 组件（镜像 `socialware` 当初的加法）→
   `$EZAGENT_HOME/<profile>/skills/`。
2. `Ezagent.Home.SkillSeed`（`Home.SocialwareSeed` 的镜像）：`home.init` + boot
   兜底时一次性幂等拷贝 `priv/skills_seed/<ref>/` →
   `$EZAGENT_HOME/<profile>/skills/<ref>/`，带 §5.4 的出厂哈希判别器（未动过的
   出厂目录升级；运维手改的保留）。
3. boot 扫描这**一个**目录构建 `SkillRegistry` 索引；索引条目经
   `seed_object_upsert/1`（`seed_family_prefix: "skill-seed"`）reconcile。seed
   之后解析器只有**一个运行时来源**。
4. `resolve_skill_source/1` 重指到 registry；entrypoint 播种 `skills/` 骨架目录。
   **授权维持 system 审核**（§5.3）：无运行时可写发布面；未知 ref 响亮失败。

**出口：** 运维放/改 `$EZAGENT_HOME/<profile>/skills/<ref>/`，下次 boot 注册/升级
它；出厂默认在 release 升级时自我升级（除非运维手改过）；recipe 引用未知 ref 时
响亮降级，绝不静默。

### 阶段 3 —— 完全 recipe 驱动的物化；walk-up 移除

1. 物化经 `SkillRegistry` 读 `Recipe.skills`，并**折进 `HomeRuntime.stage_and_swap`**
   （原子、幂等）—— 独立的 `OrchestratorBootstrap` 拷贝删除。这也是 agent 内 skill
   **升级/移除**变得正确的前提（IC-2）。
2. 把死掉的 `desired_skills` domain 声明接到同一后端（或废弃它、改用 recipe
   `skills` —— OQ-2）。
3. **移除 walk-up**（在此之前仅 dev-fallback，此后消失）。
4. 可选：只读共享 skill store（符号链接替代每 agent `cp_r`）以支撑多 agent 密度。

### 后续阶段（明确不在本文范围）—— workspace 作用域的自定义 skill

租户创作的 skill 走 `resource://<ws>/skills/<ref>` +
`Resource.FsResolver.resolve/2` 授权 + CR 治理发布（§5.3），解析兜底顺序
workspace→system，镜像 `RecipeRegistry.lookup/2`。需要创作边界的信任守卫
（skill 带脚本 —— data-role 的 `script` 问题，fail-closed），也是 ConfigObject
承载的单文件变体（§5.4）发挥价值的地方。

---

## 7. 实现约束（来自对抗审查；非阻塞，对实现有约束力）

- **IC-1 —— 目录哈希语义。** 闭包哈希必须对文件**改名**和**删除**都变化（对排序的
  `relpath → hash` *对集*哈希两者皆覆盖）；每文件哈希输入必须含可执行位；符号链接
  哈希其**目标路径**（后续阶段的租户 store 应干脆拒绝符号链接 —— 逃逸向量）。P2
  之前必须定稿；索引契约依赖它。
- **IC-2 —— 升级正确性依赖 P3。** `OrchestratorBootstrap.copy_skill/3` **跳过已
  存在的目标目录**（`orchestrator_bootstrap.ex:356`），所以已物化的 agent 在物化
  移进 `stage_and_swap`（每次物化全新 staging，P3）之前永远拿不到 skill 升级或
  移除。P3 之前，skill 升级需要 config_dir 重生成；运维手册必须写明。
- **IC-3 —— 运行时子集派生而非手工枚举。** P1 的打包清单和 P1 的不变式测试都必须
  **从所有 `roles/0` seed 的 `Recipe.skills` 计算**（今天：
  `orchestrator_recipe.ex:110` → `ezagent-session-orchestrator`）。手工维护的清单
  会在某 recipe 加 ref 的那一刻腐烂 —— 用更多步骤重演本事故。

---

## 8. 开放问题

- **OQ-1（运行时 vs dev 分类）：** IC-3 派生出*必须打包*集，但一个人类可读的标记
  （frontmatter `runtime: true`，或 seed 源目录本身即标记）仍有助于评审；P1 前与
  `skill-gates` worktree 及 deploy 仓库的 skill 审计对齐。
- **OQ-2（`desired_skills` vs `Recipe.skills`）：** 存在两个 skill-名声明
  （domain `AgentTemplate.desired_skills`、recipe `Recipe.skills`）；
  `desired_skills` 当前是死码。收敛为一个 —— recipe 拥有 —— 还是两者并存并定义
  优先级？
- **OQ-3（每 agent 拷贝 vs 只读共享）：** 从每 agent `cp_r` 起步（隔离、匹配
  HomeRuntime）；agent 密度到什么程度才值得只读共享 store + 符号链接？
