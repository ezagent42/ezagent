# 部署态 Agent 的 Skill 分发 — 设计选项

> 设计调研，2026-07-08。分支 `docs/skill-distribution-research`。
> 英文版：[`skill-distribution-design.md`](skill-distribution-design.md)。
> 状态：**调研 / 建议** —— 本分支不含实现。

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

据称有一个 point-fix，在 `mix release` 前把这一个 skill 塞进某个 `priv/`
（正是 Dockerfile.prod 66-69 行的翻版——那几行已经把 feishu WS sidecar
`npm install` **进 `priv/`** 好让 release 打包它）。*（说明：我在
`esr-ng-deploy/docker/Dockerfile.prod` 及 prod 的 `role_skill_sources` /
`orchestrator_skill_source` app-env 里都**没能定位**到已提交的 point-fix，其确切
形态**待确认**。无论何种形态，它都硬编码了单个 skill。）*

仓库根 `.claude/skills/` 有 **25 个 skill 目录**（外加一个 `SUPERPOWERS_VERSION.md`
标记文件）。任何未来 recipe 只要引用**第二个** skill 就会同样地崩。修复必须泛化 skill
**内容分发**，而不是给一个 ref 打补丁。

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

**所以 recipe 已经声明了 agent 需要"哪些"skill。** 缺的不是声明。
`OrchestratorRecipe.recipe/0` 今天就写着 `skills: [@skill_ref]`。

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
  见 §5.4。）

**对 skill 的启示：** 把 artifact + 其 manifest 打包进 `priv/`（release 原生默认）；
把昂贵/共享的部分放机器级全局，而非每 agent。

### 2.5 参考模型 B —— socialware `$EZAGENT_HOME` seed + 三态契约

这是"把构建后内容分发到部署态节点、且不重建 release"的最近类比。

- **`Ezagent.Socialware.ManifestSeed.scan_all!/1`**
  （`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex`）在 boot
  时跑一次（由最后启动的 app 触发），确定性地扫**两个**来源：
  1. **部署目录** `$EZAGENT_HOME/<profile>/socialware/<name>/manifest.yaml`
     （经 `Ezagent.System.FsResolver` 解析——一个闭合的编译期白名单：
     `credentials|logs|plugins|inbox|socialware`）；然后
  2. 每个已启动 app 打包的 `priv/socialware/`。
- **`$EZAGENT_HOME` 是逃生口**：运行时填充、bind-mount 的目录（`EZAGENT_HOME=/data`），
  **不**属于 release 镜像（`docker/entrypoint.prod.sh`：*"release 没有
  `mix ezagent.home.init`"* —— entrypoint 自己 `mkdir -p` 骨架，因为干净的 home 起始
  为空）。这正是 skill 需要的性质：构建后可增/可改的内容。
- **三态（实为四态）seed 契约** ——
  `Ezagent.Socialware.ConfigStore.seed_object_upsert/1`
  （`apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex`），
  经 `ContentHash.of/1`（键排序、字符串化、SHA-256）内容哈希：
  1. **absent** → 播种一次（race-safe）→ `:seeded`
  2. **same**（哈希相同）→ `:exists` 空操作
  3. **outdated + seed-family**（`source_turn_id` 以调用方的 `seed_family_prefix`
     开头）→ 升级：追加新对象 + 重指 → `:seeded`
  4. **outdated + 非 seed-family**（用户/CR override）→ `:exists`，**override 保留**。

**对 skill 的启示：** 在 `priv/` 打包默认**并**从 `$EZAGENT_HOME` overlay；用同一个
内容哈希三/四态契约 reconcile，使升级可寻址、租户定制在 re-seed 后存活。

### 2.6 "agent 运行时需要 artifact"的路径枚举

| 路径 | 声明在哪 | 如何解析/分发 | release 安全？ |
|---|---|---|---|
| Orchestrator skill | `Recipe.skills`（代码 recipe） | 从 cc `priv_dir` 向上 walk | **否**（本事故） |
| `desired_skills`（domain） | `AgentTemplate` 内容 | *从不消费* | N/A（死码） |
| Recipe `plugins` | `Recipe.plugins` | fail-closed（未实现） | N/A |
| Recipe `script`（py-role） | `Recipe.script`（内联数据） | 写进 config_dir | 是（数据，在 recipe 里） |
| np Python 依赖 | `priv/` 脚本里的 PEP-723 | uv 机器级全局缓存 | 是（`priv/` + 缓存） |
| Socialware manifest | `priv/socialware` + `$HOME` | ManifestSeed 两来源扫描 | 是（打包 + overlay） |
| Recipe 自身 | `ConfigObject`（数据） | RecipeRegistry read-through + seed | 是（数据 + seed） |
| 每 agent 凭据/CLAUDE.md | template config_dir 引用 | HomeRuntime stage_and_swap | 是 |

**唯一飘红的行是 skill。** 其他要么是 recipe 里的数据、要么打包在 `priv`、要么是带
seed 契约的 `$EZAGENT_HOME` overlay。skill 是唯一**没有分发后端**的运行时 artifact
—— 它依赖 release 会抹掉的 dev 树文件布局。

---

## 3. 精确陈述缺口

skill 是一个**多文件目录树**（`SKILL.md` + 脚本/引用），在 recipe 里以**名字**引用。
在一个只有 release 镜像 + `$EZAGENT_HOME` 的部署态节点上，我们需要：

- **不依赖 dev 仓库树**的 name → 源目录解析；且
- 字节的**分发通道**：默认 release 原生，外加一个部署后 overlay，让运维（或 recipe
  fork）能在**不重建 release** 的前提下增/改一个 skill；且
- 把被引用的（非全部）skill **物化**进每个 agent 的 config_dir，**recipe 驱动**、
  带版本、租户安全。

用 recipe 的语言说：recipe 是**声明权威**（`skills: [ref]`）；我们缺的是 recipe 层
针对 skill 的**内容后端** —— 正是 `RecipeRegistry` 经 `ConfigStore` read-through
recipe *数据* 的对偶。

---

## 4. 方案

三个轴贯穿全文：**可寻址**（解析器能找到任何被引用的 skill）≠ **已打包**（进 release）
≠ **已物化**（拷进某个 agent —— 永远 recipe 驱动，只有被引用的 skill）。保持区分。

### 方案 (a) —— 纯 `$EZAGENT_HOME` skill store，像 socialware 一样播种

skill 只放在 `$EZAGENT_HOME/<profile>/skills/<ref>/`，boot 时扫进 `SkillRegistry`
（索引 = `ref → {source_dir, content_hash}`），spawn 时物化进 config_dir。

- **声明：** `Recipe.skills`（不变）。
- **版本：** 目录闭包上的三/四态内容哈希契约；租户 skill override 经
  `seed_family_prefix` 存活。
- **冷启动：** 无固有成本（拷贝是 KB 文本）；但**干净的 release 镜像 home 为空 →
  没有 skill → 首次 boot 事故重演**，直到运维填充部署目录。
- **多租户：** 天然 —— `$EZAGENT_HOME` 已是 workspace/profile 作用域。
- **walk-up：** 消亡。
- **结论：** 后端正确，**默认错误** —— 对任何未预置的部署重演生产事故。作为唯一机制
  被否决。

### 方案 (b) —— 构建期把被引用闭包打包进 `priv/`

在 `mix release` 前把运行时 skill 子集塞进某 app 的 `priv/`（泛化 Dockerfile.prod
的 feishu-node_modules 步骤）；解析器读 `:code.priv_dir`。

- **声明：** `Recipe.skills`（不变）。
- **版本：** 就是 release 版本 —— **skill 改动需要重建 release**；recipe 无法在部署后
  加 skill。
- **冷启动：** 无。
- **多租户：** 从 `priv/` 只读共享；无每租户 skill 创作。
- **walk-up：** 消亡（被 `priv/` 查找取代）。
- **结论：** release 原生且自足，但**僵硬** —— recipe 层无法治理它没随 release 发的
  skill。仅作*默认那一半*可用。

### 方案 (c) —— 混合：打包 `priv/` 默认 + `$EZAGENT_HOME` overlay ✅

一个 `SkillRegistry` 经**两层、overlay 优先**解析 ref：

1. `$EZAGENT_HOME/<profile>/skills/<ref>/`（部署后，运维/recipe 创作）；
2. 打包的 `priv/.../skills/<ref>/`（release 原生默认）。

索引在 boot 时由两来源扫描构建（镜像 `ManifestSeed`），经内容哈希三/四态契约
reconcile；物化折进 HomeRuntime 的原子 swap。

- **声明：** `Recipe.skills` —— recipe 是唯一声明权威；`SkillRegistry` 是它的内容
  后端，正如 `RecipeRegistry` 是 `ConfigStore` 上的 read-through。
- **版本：** 三/四态、override-safe，**且**干净镜像从打包层自足。
- **冷启动：** 无（KB 文本拷贝，同步 —— §5.4）。
- **多租户：** 打包 = 只读共享；overlay = 每 profile/租户创作；每 agent 拷贝做隔离
  （只读共享 store 是后续优化）。
- **walk-up：** 降级为 dev-only，随后移除。
- **结论：** 继承 socialware 已用来解决同一问题的完全相同的模式。**推荐。**

---

## 5. 推荐 —— 方案 (c)

### 5.1 论点（判别式，而非模式匹配）

skill 分发设计必须同时满足**两个**互相拉扯的约束：

1. **干净的 release 镜像必须自足** —— orchestrator 必须能在 `$EZAGENT_HOME` 为空时
   首次 boot 就 spawn。这正是事故违反的约束。→ 逼出**打包默认**（排除纯 (a)）。
2. **recipe 层必须能在不重建 release 的前提下增/改 skill** —— 这就是"由 recipe 去
   管理"的运维含义。→ 逼出 **`$EZAGENT_HOME` overlay**（排除纯 (b)）。

只有**混合**同时满足两者。这不是新发明：它与 socialware 已在跑的形态完全一致——
`priv/socialware`（打包）**和** `$EZAGENT_HOME/.../socialware`（overlay），由一个
seed 契约 reconcile。我们是在继承已经解决了这一类问题的模式，套用到目录形态的
artifact 而非单文档 manifest 上。

### 5.2 形态 —— recipe 治理，而非平行子系统

```
Recipe.skills: [ref]          ← 声明权威（已落地）
        │  （物化 read-through）
        ▼
SkillRegistry.resolve(ws, ref) → {source_dir, content_hash}
        │  overlay 优先:  $EZAGENT_HOME/<profile>/skills/<ref>   （部署后）
        │                 否则 打包 priv/.../skills/<ref>         （release 默认）
        ▼
HomeRuntime.stage_and_swap  ← cp_r 被引用 skill 进 config_dir/skills/<ref>，
                              在同一个原子 swap + 幂等标记内
```

`SkillRegistry` 有意做成 `RecipeRegistry` 的**镜像**：同样的 system-workspace +
租户兜底作用域、同样的 boot-seed 通道、同样的内容哈希 reconcile。recipe 治理
*什么*；registry 是 recipe 层针对*字节*的内容后端。它不是贴在 recipe 旁边的东西——
它就是同一个 read-through-over-store 设计的 skill 那一半。

### 5.3 三/四态契约要适配（并非与 socialware 逐字相同）

`seed_object_upsert/1` 哈希单个 `ConfigObject` **body**。skill 是**目录**，所以：

- **索引/manifest** 是 `ConfigObject`（`subject = skill:<ref>`、`key = "skill"`、
  body = `{ref, content_hash, source_layer}`）—— 这逐字买到完整四态契约
  （absent / same / **outdated-可升级** / **override-保留**）。
- **哈希覆盖目录闭包**（排序 file-relpath → file-hash → 汇总），而非 JSON body。
  对象存**指针 + 哈希**，绝不存 skill 字节（skill 留在 `priv/` / `$EZAGENT_HOME`
  磁盘上）。
- 带上 `seed_family_prefix`（如 `"skill-seed"`），使**租户定制的 skill 在 re-seed
  后存活** —— 与 recipe 拿到的同款 override-safety。

### 5.4 冷启动与同步/异步 —— 反驳简报

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

### 5.5 什么消亡

- `OrchestratorBootstrap.search_skill_source/1` 的**从 `priv_dir` 向上 walk** →
  prod 中移除；仅保留为 **dev-mode 兜底**（dev 树有仓库根 `.claude/skills/`），
  像 `manifest_boot_scan` 的 `:dev/:prod`-only 开关一样门控，待 `SkillRegistry`
  成为权威后删除。
- 手工的 `:role_skill_sources` / `:orchestrator_skill_source` app-env override →
  被 registry 取代（仅留作测试缝）。
- `OrchestratorBootstrap` 里独立的 spawn 后 skill `cp_r` → 折进
  `HomeRuntime.stage_and_swap`。

---

## 6. 分阶段迁移

### 阶段 1 —— release 自足（退休事故 + point-fix）

**目标：** 每个 recipe 引用的 skill 都在**每个 release 镜像里可寻址**，经**通用**
解析器；硬编码 point-fix 与 orchestrator-only 特判都消失。

1. 在 `mix release` 前把**运行时 skill 子集**塞进某 app `priv/`（Dockerfile.prod
   feishu-node_modules 模式，做成一等公民 —— 一个构建步骤或一个签入的
   `priv/skills/` 符号链接目标）。**运行时子集，非全部 ~25 个：** 部署态 agent 的
   skill 是 `ezagent-session-orchestrator`（若 socialware 创作 agent 加载则 +
   `ezagent-socialware`）。其余 ~23 个是 **Claude-Code dev-harness skill**
   （brainstorming、TDD、writing-plans、systematic-debugging……），**绝不能**进
   prod agent 镜像。（`SKILL.md` frontmatter 里一个 `runtime: true` 标记，或一份
   显式打包白名单，划出界线 —— 见 OQ-1。）
2. 把 `resolve_skill_source/1` 的 walk-up 换成**通用**的 `priv/`-根查找（任何 ref、
   无 orchestrator 硬编码）；orchestrator ref 不再特殊。
3. **退休 point-fix** —— 一旦运行时子集原生进 `priv/`，deploy Dockerfile 带的任何
   临时 priv-copy 都删掉。*（先确认其确切现状 —— §1 说明。）*
4. 不变式测试：一个 `MIX_ENV=prod` 形态的解析（无 dev 树、无配置 override）能解析
   orchestrator skill，且**若 walk-up 是唯一路径则失败** —— 即能捕获本事故的那个
   测试。

**出口** —— 用 §4 的轴区分（*可寻址* ≠ *已打包* ≠ *已物化*）读"全部 20+ skill 可
寻址"：

- **可寻址：** 解析器是**通用**的 —— 没有 skill 被特判，故*任何* recipe 引用的 ref
  都走同一路径解析（这就是"全部 skill 可寻址"的含义；它是解析器的性质，而非发 25 个
  目录的性质）。
- **prod 镜像里有字节：** **运行时子集**（~2 个）打包在 `priv/`。dev-harness skill
  今天在 **dev 树**里仍可解析，并经阶段 2 的 `$EZAGENT_HOME` overlay 获得 prod 解析
  路径；它们只在**被某 recipe 引用时**才需要 prod 字节，届时并入打包或 overlay。今天
  没有 recipe 引用它们，故无缺失。
- 每条 deploy channel 上 session-create 转绿且无逐-skill hack；point-fix 与
  orchestrator 特判消失。

### 阶段 2 —— `$EZAGENT_HOME` overlay + `SkillRegistry` seed 通道

**目标：** 部署后不重建 release 就能增/改 skill。

1. 给 `FsResolver` 白名单加一个 `skills` 条目 + 一个 `Ezagent.Home` 组件
   （镜像 `socialware` 当初的加法）→ `$EZAGENT_HOME/<profile>/skills/`。
2. boot 时两来源扫描（先部署目录、后打包 `priv/`），构建 `SkillRegistry` 索引；
   经目录闭包内容哈希三/四态契约（§5.3）reconcile，override-safe。
3. `resolve` 变 overlay 优先：`$EZAGENT_HOME` skill 遮蔽打包默认。
4. entrypoint 播种 `skills/` 骨架目录（像 socialware 骨架）。

**出口：** 运维放 `$EZAGENT_HOME/<profile>/skills/<ref>/`，下次 boot 注册/升级它；
打包默认可被遮蔽；租户定制在 re-seed 后存活。

### 阶段 3 —— 完全 recipe 驱动的物化；walk-up 移除

1. 物化经 `SkillRegistry` 读 `Recipe.skills`，并**折进 `HomeRuntime.stage_and_swap`**
   （原子、幂等）—— 独立的 `OrchestratorBootstrap` 拷贝删除。
2. 把死掉的 `desired_skills` domain 声明接到同一后端（或废弃它、改用 recipe
   `skills` —— OQ-2）。
3. **移除 walk-up**（在此之前仅 dev-fallback，此后消失）。
4. 可选：只读共享 skill store（符号链接替代每 agent `cp_r`）以支撑多 agent 密度；
   workspace 作用域 overlay 里的每租户创作 skill。

---

## 7. 开放问题

- **OQ-1（运行时 vs dev 分类）：** skill 如何被标为"进部署态 agent"？frontmatter
  `runtime: true` 还是显式打包白名单。`skill-gates` worktree 与 deploy 仓库的 skill
  审计（`IMPLEMENTATION_ROADMAP.md` §5）可能已有部分切分 —— 阶段 1 定子集前先对齐。
- **OQ-2（`desired_skills` vs `Recipe.skills`）：** 存在两个 skill-名声明
  （domain `AgentTemplate.desired_skills`、recipe `Recipe.skills`）；`desired_skills`
  当前是死码。收敛为一个 —— recipe 拥有 —— 还是两者并存并定义优先级？
- **OQ-3（每 agent 拷贝 vs 只读共享）：** 从每 agent `cp_r` 起步（隔离、匹配
  HomeRuntime）；agent 密度到什么程度才值得只读共享 store + 符号链接？
- **OQ-4（skill 闭包哈希）：** 确认目录闭包哈希算法（排序 relpath → 内容哈希 →
  汇总），以及 skill 内的可执行位/符号链接是否必须经 seed 保留。
- **OQ-5（point-fix 形态）：** 确认 `esr-ng-deploy` 里已提交的 point-fix（§1 说明），
  好让阶段 1 退休真实的东西。
