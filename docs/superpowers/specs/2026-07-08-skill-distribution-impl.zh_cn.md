# Skill 分发 P1–P3 — 实现 SPEC

> 日期: 2026-07-08 · 英文本: [`2026-07-08-skill-distribution-impl.md`](2026-07-08-skill-distribution-impl.md)。
> **真相源:** [`docs/notes/skill-distribution-design.md`](../../notes/skill-distribution-design.md)
> (已合并 PR #1251,codex 二轮评审,终裁 **SOUND-WITH-NOTES**)。
> 本 SPEC **落实该设计文档的决策**,不重开这些决策。若本 SPEC 与设计文档冲突,以设计
> 文档为准 —— 唯一有据例外见 §2(设计文档对 `roles/0` 插件的枚举早于 `main` 的一次
> 变动,派生*输出*在此重新核对)。命名对齐 GLOSSARY **决策 #161**(声明/内容分层词:
> `Registry`=运行时索引,`Seed`=安装通道,`Materializer`/原子换入=声明→artifact)。
> seed 对账沿用 **#1242** 的三/四态 `seed_object_upsert` 契约。
> Rev 2(本 SPEC 经 codex 对抗评审 NEEDS-CHANGES → 已修):HIGH-1 —— P2
> seed/升级改为**原子**(staging 兄弟目录 + rename,boot 恢复删 `*.staging-*`;
> §4.1.6 + 崩溃恢复 gate);MED-2 —— P2 新增**全新-home 启动顺序 gate**,切换在
> P2 内自证、不推给 P3(§4.2);实现约束:IC-1 mode 归一化为 exec 位 + 空目录
> 说明;IC-4 命名 `mix ezagent.skills.regen_seed`。
> Rev 3(codex 二轮 verify):§4.1.6 升级钉为精确三步 rename 序列
> (`<ref>→.old-<nonce>` → staging→`<ref>` → 删 `.old`)+ **无并发读者 boot 窗口
> 不变量**结构化关掉两次 rename 之间的窗口 + 扩展恢复规则(`<ref>` 缺失时还原
> `.old`;两者都在时删 `.old`)+ codex 逐行测试的**崩溃点表**;§4.2 gate 具名
> (`skill_seed_crash_recovery_test.exs`、`skill_seed_boot_order_test.exs`,观察者
> 钉死、无 retry/sleep);§4.3 出口措辞同步。
> Rev 3.1(codex 三轮,SOUND-WITH-NOTES —— 已接受):ready 前 `resolve/1` 显式
> fail-loud(raise、无目录回退;唯一读者 = 实现要求)+ 崩溃点表新增两个二次崩溃行
> (恢复规则可重入);gate 相应扩展。

---

## 0. Codex 交接前言

**工作分支:** `feat/skill-distribution-p123`(基于 `origin/main`)。这**不是**本 SPEC
落地的分支(`docs/skill-distribution-impl-spec`);SPEC 先合并,codex 再从最新
`main` 切实现分支。

**自驱纪律(遵照我们的 codex 交接约定):**

- **Codex 独占该分支。** 一条分支,**三个有界子步**(P1 → P2 → P3)**顺序**提交。
  每个子步各自的验收 gate(见各阶段)必须**在下一子步开始前全绿** —— P1 未绿不得开 P2。
- **codex 不合并 `main`、不向 main 开 PR。** 由协调者(Allen/Claude)合并。codex 推分支
  并汇报每个子步的 gate 结果。
- **Gate 红 = 在本子步内向前修。** 绝不跳过、绝不 `--exclude`、绝不注释断言凑绿。若 gate
  暴露设计有误,停下并汇报 —— 不得私自偏离本 SPEC。
- **常规约束:**
  - Elixir 用结构化编辑,绝不 `cat >>`/`echo >>` 追加(追加 Elixir → `SyntaxError`)。
  - **不改 `.claude/`。** 仓库根 `.claude/skills/` 是 dev-harness 内容;P1 *读*它(dev 兜底),
    P2/P3 停止依赖它,但本工作绝不改动它。
  - **用 `uv run`,绝不 `python`/`python3`。**
  - `mise` 钉 OTP/Elixir;按各 alias 定义经 `mix` 跑 gate。
- **协调者所有、不在 codex 范围内:** 退役部署仓 point-fix(**ezagent-deploy `1d5aeca`**)
  在本分支合并**之后**由协调者做。P1 必须让该 point-fix 在**过渡期无害**(§3.4)。

---

## 1. 目标(一段话)

orchestrator(或任何 recipe 引用的 skill)必须能在**已部署节点**上仅凭 release 镜像 +
`$EZAGENT_HOME` 完成解析与物化 —— 无 dev 仓库树。现状:`resolve_skill_source/1` 从 cc
插件 `priv_dir` **向上走**找 `.claude/skills/<ref>/SKILL.md`;`mix release` 只打包各 app 的
`priv/`,release 镜像里走到头也找不到 → `{:skill_source_not_found}` → `role_degraded` →
**每个渠道 session-create 死**(现由一条硬编码 skill 拷贝 ezagent-deploy `1d5aeca` 打补丁)。
本 SPEC 用 **socialware 部署-seed 车道套到 skills** 替换这条 dev-tree 依赖:release 随包的
`priv/skills_seed` 种源 → 一次性幂等拷入**单一** `$EZAGENT_HOME/<profile>/skills/` 运行时
源 → `SkillRegistry` read-through 索引 → 物化折进 `HomeRuntime.stage_and_swap`。recipe 层仍是
**声明权威**(`Recipe.skills`);`SkillRegistry` 是它的**内容后端**,正如 `RecipeRegistry`
是 `ConfigStore` 之上的 read-through。

---

## 2. P1 派生规则(IC-3)—— 对 `main` 已核实

**规则。** 运行时 skill 集**派生,绝不手列。** 它是**每个插件 `roles/0` 种子**的
`Recipe.skills` 之并集 —— 与 `Ezagent.Plugin.RoleSeedHook.seed_roles/2` 在
`apps/ezagent_core/lib/ezagent/plugin.ex:482` 已驱动的同一枚举(每个启动插件的
`plugin_module.roles()`)。**P1 种子清单**与 **P1 不变量测试**都从这**一份枚举**计算(IC-3)
—— 手维护清单会在某 recipe 加 ref 的瞬间腐化,复现事故。

**已核实的当前输出(对 `origin/main`,2026-07-08)。** 枚举全 umbrella 每个 `roles/0`:

| 插件 | `roles/0` recipes | 声明 `skills:`? |
|---|---|---|
| cc | `OrchestratorRecipe.recipe()` | **是** → `["ezagent-session-orchestrator"]`(`orchestrator_recipe.ex:110`,`@skill_ref` `:41`) |
| codex | `OrchestratorRecipe.recipe()`(同 recipe) | 是(同 ref) |
| kb | `kb_recipe()` | 否(默认 `skills: []`) |
| py | `np_role_recipe()` | 否 |
| kanban | `kanban_manager_recipe()` | 否 |
| hello | `hello_front_desk` / `hello_builder` / `hello_concierge` / `hello_llm`(**4** 个,非文档的"×3") | 否 |

→ **今日派生输出 = `["ezagent-session-orchestrator"]`**(一个 ref)。设计文档虽漏了 `kb`、
少数了 hello,示意计数仍正确 —— 因为那些 recipe 都不带 skill。本 SPEC 重新核实而非照抄
(advisor blocker),并断言派生**面**(`roles/0` recipes)与 P1 不变量测试的**面**是**同一集**,
故"已 seed 但未打包"的 ref 绝不漏过。

**防腐说明。** 仓库根 `.claude/skills/` 其余 `~23` 个目录是 Claude-Code **dev-harness** skills
(brainstorming、TDD、writing-plans…),**不得**进 prod agent 镜像。它们保持 dev-tree 可解析,
**仅当某 recipe 引用**时才进 seed —— 届时同一派生自动纳入、不变量测试自动覆盖。

---

## 3. P1 —— 通用 resolver + 打包运行时集

**目标:** 每个 recipe 引用的 skill 在**每个 release 镜像**里都可**寻址**,经**通用** resolver
读 release 随包源;walk-up 降为 dev-only 兜底;orchestrator ref 不再特殊。

### 3.1 工作项

1. **种源目录(入库、release 原生)。** 建 `apps/ezagent_web/priv/skills_seed/<ref>/`,把
   **派生运行时集**(§2)在库内落进去 —— 今日恰为
   `apps/ezagent_web/priv/skills_seed/ezagent-session-orchestrator/`(仓库根
   `.claude/skills/ezagent-session-orchestrator/` 闭包的拷贝)。种源 **app 钉 `ezagent_web`**
   (部署/装配顶层 app),对齐 `socialware_seed`:`mix release` 只打包各 app `priv/`,故字节必须
   在某 app `priv/` 下,`ezagent_web` 即 socialware 所选同一 app。目录名 `skills_seed`(≠ `skills`)
   使其不被将来的 `skills` 运行时扫描二次扫到。此落地是派生**产出**的源内容,非手列 —— codex
   经专用 **`mix ezagent.skills.regen_seed`** 任务(IC-4)重生成:跑派生(遍历 `roles/0`)
   并拷每个派生 ref 的 dev-tree 闭包。
2. **`Ezagent.SkillRegistry`**(`Registry` 层,GLOSSARY #161)—— `ref → {source_dir,
   content_hash}` 索引。**P1 里直接读打包源**:枚举每个已加载 app 的 `priv/skills_seed/<ref>/`
   (通用扫描,`SocialwareSeed.source_dirs/0` 手法 —— 无硬编码 app ref),对每个目录闭包做 hash
   (§6 IC-1),暴露 `resolve/1 :: {:ok, {source_dir, hash}} | {:error, {:skill_source_not_found,
   ref}}`。**放置:** cc 插件与 `HomeRuntime`(P3)都能调、无跨 app 环 —— `ezagent_core` 是自然家
   (它已拥 `Home`、`HomeRuntime`、`System.FsResolver`)。
3. **重接 `resolve_skill_source/1`**(`orchestrator_bootstrap.ex:266`)到 `SkillRegistry.resolve/1`
   —— **任意 ref 通用**,无 orchestrator 硬编码。现有 config override
   (`:orchestrator_skill_source`、`:role_skill_sources`)**仅留作测试 seam**(若设仍先查)。
   **walk-up(`search_skill_source/1` + `walk_for_skill/2`)降为 dev-only 兜底**:仅当
   `SkillRegistry.resolve/1` 未命中**且**环境为 `:dev`(compile-env gate,`manifest_boot_scan`
   `:dev/:prod` 开关手法)时可达。`:prod` 未命中即硬 `{:skill_source_not_found, ref}` —— 大声的
   过渡期权威不变量(设计 §5.3)。
4. **保 `1d5aeca` 过渡无害。** 合并后、协调者退役 point-fix 前,构建镜像里两源可并存:ezagent-deploy
   拷贝在 `apps/ezagent_plugin_cc/priv/.claude/skills/…` **及**新的 `ezagent_web/priv/skills_seed/…`。
   不得冲突,SPEC 说明**为何**:(a) `SkillRegistry` 从**自己的源**(`priv/skills_seed` 扫描)解析,
   cc-`priv` 拷贝根本不被新路径查;(b) 会命中 cc-`priv` 拷贝的 walk-up 现已 `:dev`-gate、`:prod`
   不可达;(c) 即便拷贝在,也是不同位置的逐字节相同种内容 —— **幂等相同**,无分叉。codex **不**删
   `1d5aeca`(范围外;协调者、合并后)。

### 3.2 P1 验收 gate

- **`test/.../skill_registry_test.exs`**(新):`resolve/1` 对
  `"ezagent-session-orchestrator"` 返回 `{:ok, {dir, hash}}`;未知 ref 返回 `{:error,
  {:skill_source_not_found, ref}}`;`roles/0` 派生集全部可解析。
- **`test/.../skill_distribution_prod_shape_test.exs`**(新,**先红**):模拟 prod 形态解析
  —— **无 dev 树、无 config override、walk-up 禁用** —— 断言**从已 seed `Recipe.skills` 枚举出的
  每个 ref 都经 `SkillRegistry` 解析成功**,且**若 walk-up 是唯一路径则解析失败**。这是本可捕获
  事故的测试;先写红(重接前),再驱绿。其期望通过集与种子清单(§2)从**同一** `roles/0` 枚举计算,
  断言二者相同。
- 现有 `orchestrator_bootstrap` 测试保持绿(override 仍作测试 seam)。
- **常规 gate**(所有子步):`mix format` 干净;`mix compile --warnings-as-errors --force` 干净;
  `mix ezagent.check_invariants` 绿;`mix ezagent.arch.scan` 绿;`mix ezagent.doc.scan` ratchet
  不退(每个新公开 fn 带**代码核实**的 `@doc` —— 声明与代码相符,不从名字臆测)。

### 3.3 P1 出口

resolver **通用**(无 skill 特殊);派生运行时子集字节在 release 随包种源;prod 形态路径下
walk-up 禁用而 session-create 绿;`1d5aeca` 无害冗余,待协调者退役。

---

## 4. P2 —— seed 车道(`$EZAGENT_HOME` store + 单一运行时源)

**目标:** **不重建 release** 即可**部署后**增/升级 skill,经 seed-once-then-single-source 车道
—— **不是**双源 overlay。

### 4.1 工作项

1. **`skills` 加进 `System.FsResolver` + `Home`。** 在闭 `@catalog`(`fs_resolver.ex:65`)加
   `"skills" => "skills"`、`Home.skeleton_dirs`(`home.ex:73`)加 `:skills` —— 完全照 `socialware`
   的加法 → 解析到 `$EZAGENT_HOME/<profile>/skills/`。entrypoint/`home.init` `mkdir -p` 该
   `skills/` 骨架(干净 home 起始为空)。
2. **`Ezagent.Home.SkillSeed`** —— **直接镜像 `Home.SocialwareSeed`**
   (`apps/ezagent_core/lib/ezagent/home/socialware_seed.ex`):枚举每个已加载 app 的
   `priv/skills_seed/<ref>/`,幂等拷入 `$EZAGENT_HOME/<profile>/skills/`,dest 经受祝福的
   `System.FsResolver` seam(**非**裸 `Home`)解析,使 seed-dest == scan-dir。触发**`home.init`** +
   **boot 兜底**(store 扫描前),同 socialware 的两点手法。与 `SocialwareSeed` 一刀切 never-overwrite
   的差别:**字节层 shipped-hash 三态对账**(下)。
3. **把 `SkillRegistry` 重指向单一运行时源。** P2 后,registry 的后端源是
   **`$EZAGENT_HOME/<profile>/skills/`**,非 `priv/skills_seed`(现仅作 `SkillSeed` 的*源*)。这是
   codex 必须干净实现的 **P1→P2 过渡**:P1 registry 直读 `priv/skills_seed`;P2 让 seed 灌满部署目录、
   registry 扫**那一个目录**。seed 后**唯一运行时源** —— 解析时无 overlay 优先级。
4. **索引 vs 字节分离(设计 §5.4)—— 保持区分:**
   - **索引** = 每 skill 一个 `ConfigObject`(`subject = skill:<ref>`,`key = "skill"`,
     body `= %{ref, content_hash, shipped_hash}`),经
     `Ezagent.Socialware.ConfigStore.seed_object_upsert/1`(`seed_family_prefix:
     "skill-seed"`)对账 → **四态**契约照搬(absent→`:seeded`;same→`:exists`;
     outdated+seed-family→升级;outdated+非-seed-family override→`:exists` 保留)。
   - **字节** = 磁盘 skill 目录,经 `SkillSeed` 的 **shipped-hash 三态判别**(下)对账。索引**不**
     承载字节(skill 是目录树 —— 脚本、exec 位、symlink —— ConfigObject 的 JSON body 无法表达;这是
     *形状*论证,非 no-blobs —— 设计 §5.4)。
5. **shipped-hash 三态对账(字节)。** `SkillSeed` 在索引里存最后 **shipped_hash**(它上次 seed 的
   `priv/skills_seed` 目录 hash)。seed 时对每个 `<ref>`,比较**磁盘**目录 hash、**存储 shipped_hash**、
   **新 priv** hash:

   | 磁盘 vs shipped_hash | 新 priv vs shipped_hash | 动作 |
   |---|---|---|
   | 相等(未改) | 相等 | **no-op** |
   | 相等(未改) | 不同 | **升级** —— 换目录,bump `shipped_hash` + 索引 |
   | **不同(运维改过)** | 相等 | 保留(反正无 release 变) |
   | **不同(运维改过)** | **不同** | **保留运维改** + **大声信号** ↓ |

   **两侧都变**格(运维改过**且** release 变)即 codex 二轮 note:**保留运维改**,但发**大声、可 grep 的
   `Logger.warning`**(如 `"skill-seed: SKIPPED release upgrade for <ref> — operator-edited on disk
   (on_disk=<hash8> shipped=<hash8> release=<hash8>); operator edit preserved, release change NOT
   applied"`)**加 telemetry 事件**(如 `:telemetry.execute([:ezagent, :skill_seed, :upgrade_skipped],
   %{count: 1}, %{ref: ref, on_disk_hash: …, shipped_hash: …, release_hash: …})`),让被跳过的升级在
   日志与指标里**可见**。**Runbook 行**(加入 ops runbook / 本 SPEC §7):*"若 `skill-seed: SKIPPED
   release upgrade` 触发,说明因部署目录副本被运维改过而扣留了一次 release skill 升级。要取 release 版:
   备份并删 `$EZAGENT_HOME/<profile>/skills/<ref>/`,再跑 boot seed(或 `mix ezagent.home.init`)——
   它从 `priv/skills_seed` 重种并 bump 索引。"*
6. **原子目录物化 —— 崩溃安全的 seed/升级(codex 评审 HIGH-1)。** §4.1.5 矩阵只覆盖
   **完整**目录;拷贝/升级中途崩溃绝不能让 `$EZAGENT_HOME/<profile>/skills/<ref>/` 半填充
   —— P2 已把 registry 重指该单一源,半成品目录会被 hash 并**误判为运维改过**(永久保留)
   或干脆坏掉。中断以结构化方式处理,用与 **`HomeRuntime.stage_and_swap` 相同的全新-staging
   手法**(`home_runtime.ex:279` / `Materializer.atomic_replace`):
   - **写临时兄弟目录,rename 入位。** 每次 seed 与升级先拷进
     `<deploy_dir>/<ref>.staging-<nonce>`(同文件系统 → 同设备 rename)。**首次 seed**
     (无既有 `<ref>`):一次原子 `rename(<ref>.staging-<nonce> → <ref>)`。**升级 ——
     精确三步序列,具名中间态,按此顺序:**
     1. `rename(<ref> → <ref>.old-<nonce>)` —— 原子;旧闭包全程**在某路径上保持完整**;
     2. `rename(<ref>.staging-<nonce> → <ref>)` —— 原子;新闭包完整出现;
     3. `delete <ref>.old-<nonce>`。
   - **无并发读者不变量(结构化、非概率地关掉两次 rename 之间的窗口)。** 升级步 1 与步 2
     之间路径 `<ref>` 短暂**缺席**。这**按构造**无害,SPEC 钉明原因:seed/升级物化**只在
     boot 期运行,严格早于 registry 首次扫描** —— registry 扫描是部署目录的**唯一读者**,
     supervisor 把 `SkillSeed`(boot 恢复 + seed/升级)接线在 registry scan/ready **之前**,
     故窗口单线程、不存在任何能观察到缺席路径的读者。P2 无运行中升级(store 仅由 boot
     seed 与运维写,§4.1.7);运维投放在**下次 boot** 生效,落在同一单线程窗口内。
   - **ready 前准入(fail-loud,let-it-crash)。** 在 registry boot 扫描**完成之前**到达的
     `SkillRegistry.resolve/1` 调用是 supervisor 接线 bug,不是可恢复的运行时状态:它
     **raise**(registry-not-ready,消息点名所需接线顺序)—— 绝不阻塞、绝不返回半答案、
     **绝不回退为直接读 skills 目录**。由此唯一读者规则成为**实现要求而非仅论证**:除
     registry boot 扫描外,任何组件不得读 `$EZAGENT_HOME/<profile>/skills` —— 所有消费者
     一律经 `resolve/1`,而 `resolve/1` 在扫描完成前拒绝作答。
   - **boot 恢复规则 —— 修复每一种崩溃残留,在 seeding 前运行:**
     1. **总是**删除所有 `*.staging-*` 目录;
     2. 若 `<ref>` **缺失**且 `<ref>.old-<nonce>` 在 →
        `rename(<ref>.old-<nonce> → <ref>)` —— 还原旧完整闭包(被中断的升级在本次 boot
        的 seed run 里**重新应用**);
     3. 若 `<ref>` 与 `<ref>.old-*` **都在** → 删 `<ref>.old-*`(rename 入位已完成;补完
        被中断的步 3)。
   - **崩溃点表** —— 每个崩溃点都落在恢复可证修复的状态;codex 每行写一个测试用例:

     | 崩溃点 | 磁盘残留 | 恢复 → boot 后状态 |
     |---|---|---|
     | 拷入 staging 中途 | 半成品 `.staging-*`(升级时另有旧完整 `<ref>`) | 删 staging;旧目录(或缺席)原样;本次 boot 重跑 seed/升级 |
     | staging 完整、升级步 1 前 | 完整 `.staging-*` + 旧完整 `<ref>` | 删 staging(重拷便宜);本次 boot 重跑升级 |
     | 升级步 1 与步 2 之间 | `<ref>` **缺失**;`.old-<nonce>` + `.staging-*` 在 | 删 staging;`.old` rename 回 `<ref>`;本次 boot 重跑升级 |
     | 升级步 2 与步 3 之间 | 新完整 `<ref>` + `.old-<nonce>` 在 | 删 `.old`;新闭包成立 |
     | 首次 seed rename 中(不可能中断,rename 原子) | `<ref>` 或缺席或完整 | 残留 staging(如有)删除;缺席则本次 boot 重跑 seed |
     | **二次崩溃:恢复中删 `.staging-*` 中途** | 删了一半的 `.staging-*` 仍在;主状态(`<ref>` / `.old`)未被该删除触及 | 恢复**可重入**:下次 boot 规则 1 再删(`rm_rf` 幂等);主状态规则 2/3 照常适用 |
     | **二次崩溃:`.old → <ref>` 还原之后、重新 seed 应用之前** | 旧完整 `<ref>` 已归位;无 `.old-*`、无 `.staging-*` | 与正常升级前状态无法区分;本次(或下次)boot 的 seed run 重新检出未改+release 不同 → **升级重新应用**;无损失 |

     恢复规则**可重入**:*恢复过程本身*的任何崩溃留下的残留,下次 boot 由同一套规则
     修复 —— 不需要"恢复的恢复"机制。

   - **registry 卫生。** `SkillRegistry` 扫描防御性**跳过 `*.staging-*` 与 `*.old-*` 名**
     (中间态目录绝不入索引)。
7. **权威保持 system-vetted(设计 §5.3)。** 无运行时可写发布面。store 仅由 `home.init`/boot seed 与
   有节点权限的运维写。未知/未授权 ref **大声**失败(`{:skill_source_not_found, ref}` → `role_degraded`
   + telemetry),绝不静默跳过。

### 4.2 P2 验收 gate

- **`test/.../home/skill_seed_test.exs`**(新):幂等 seed(二次调 no-op);四态字节矩阵 —— 未改+未变
  (no-op)、未改+release 变(升级)、运维改+未变(保留)、**运维改+release 变(保留 + 断言发出
  `Logger.warning` 串 + telemetry 事件触发**,经 `:telemetry_test` handler)。
- **`skill_registry_test.exs` 扩展**:seed 后 `resolve/1` 读 `$EZAGENT_HOME` 源;运维投放的 `<ref>`
  目录在下次扫描注册;索引对账正确命中 `:seeded` / `:exists` / 升级。
- **崩溃恢复 gate(HIGH-1)** —— `test/.../home/skill_seed_crash_recovery_test.exs`:
  **§4.1.6 崩溃点表每行一个测试用例** —— 在部署目录种该行的精确残留(半成品 staging;完整
  staging + 旧 `<ref>`;`<ref>` 缺失 + `.old-<nonce>` + staging;新 `<ref>` + `.old-<nonce>`;
  仅残留 staging;**外加两个二次崩溃行**:恢复被打断留下删了一半的 staging、旧 `<ref>` 已
  还原且无中间态待升级重应用)→ 跑 boot 恢复 + seed 路径 → 断言表中 boot 后状态:中间态清空、
  `SkillRegistry.resolve/1` 返回该 ref **完整**闭包且 hash 正确、**无"运维改过"误判**
  (对账按恢复后目录的真实 hash 分类,绝不按半成品)。
- **全新-home 启动顺序 gate(MED-2)** ——
  `test/.../home/skill_seed_boot_order_test.exs`,测试描述:
  `"fresh $EZAGENT_HOME: every derived Recipe.skills ref resolves on the FIRST
  registry read after boot (SkillSeed strictly before first scan)"`。从**全新
  `$EZAGENT_HOME`** 起步(测试内任何地方都不手调 `seed!`),按 **application supervisor
  实际接线顺序**走 seed + registry 路径(含无 `home.init` 的 boot 兜底)。"任何消费者读之前"
  钉到具体观察者,双向:
  - **顺序**:断言 registry 的 scan/ready 步(其 ETS 表填充或 ready 事件)**仅在**
    `SkillSeed` 完成之后发生 —— 由 supervisor 子进程顺序强制,测试观察该顺序断言
    (如 `SkillSeed` 返回前 registry ETS 表不存在/为空);
  - **首读即成**:断言 boot 后**首次调用** `SkillRegistry.resolve/1` 即对**每个派生
    `Recipe.skills` ref** 成功,测试内**无 retry、无 `Process.sleep`、无最终一致轮询**
    —— 首读确定性成功,否则 gate 红;
  - **ready 前拒答**:registry ready **之前**的 `resolve/1` 尝试**干净失败**(按 §4.1.6
    raise registry-not-ready),**绝不观察到半成品目录** —— 在本测试文件里作为独立用例断言。
  这证明 P2 可独立部署 —— 全新-home 切换不得等到 P3 的冷 spawn 测试。
- **`fs_resolver` / `home` 测试**:`skills` 类型解析到部署目录;骨架 mkdir 在。
- 常规 gate(§3.2)绿 —— 注意 `arch.scan` 可能需像 `socialware` 那样认可 `skills` 类型。

### 4.3 P2 出口

运维投放/更新 `$EZAGENT_HOME/<profile>/skills/<ref>/`,下次 boot 注册/升级;随包默认在 release bump
时自升级,**除非**被运维改过(此时跳过被大声信号);未知 ref 大声降级。唯一运行时源;resolver 无 overlay 逻辑。
全新 `$EZAGENT_HOME` 无需任何手动步骤即 boot 到全可解析的 registry,且首读确定性成功
(MED-2 gate)。崩溃安全(HIGH-1):在**单线程 boot 窗口之外**的任何时刻,磁盘上的 `<ref>`
要么是旧完整闭包、要么是新完整闭包 —— 绝无半成品、绝无缺席;boot 窗口**之内**升级 rename
对之间的短暂缺席态不可被观察(`SkillSeed` 完成前不存在任何读者),且 boot 恢复规则按
§4.1.6 表修复每一种崩溃残留。

---

## 5. P3 —— 物化折进 `stage_and_swap`

**目标:** skill 拷入 agent `config_dir` **折进 `HomeRuntime.stage_and_swap`**(一次原子换入、一个
`.ezagent-config-complete` 标记),使**升级与删除**正确;独立 post-spawn 拷贝与 walk-up **消亡**。

### 5.1 工作项

1. **拷贝折进 `stage_and_swap`**(`home_runtime.ex:279`)。被引用 skills(来自 `Recipe.skills`,经
   `SkillRegistry` 解析)在既有 staging 管线**内部**(`cp_r(reference_dir, staging)` 与标记写之间)
   `cp_r` 进 `<staging>/skills/<ref>`,使整 config_dir —— creds、`CLAUDE.md`、**及 skills** —— 经一次
   `atomic_replace` 落地。因 staging **每次物化全新**,skill 升级/删除现已正确(旧目录不存活),修
   **IC-2** —— 今日 `OrchestratorBootstrap.copy_skill/3` **跳过已存在 dest**(`:356`),已物化 agent 永不
   拾升级。
2. **删独立拷贝。** 移除 `OrchestratorBootstrap` 的 `install_skills/2` + `copy_skill/3` post-spawn 步
   (物化现拥它)。保留产出 `sandbox_content.skills` 的 `resolve_role`/recipe-compose;ref **列表**仍来自
   recipe —— 只是*拷贝*搬家。
3. **移除 walk-up。** `search_skill_source/1` + `walk_for_skill/2` +
   `search_orchestrator_skill_source_from/1` **删除**(P1 的 `:dev`-gate 是迁移桥;P3 删码)。
   `SkillRegistry` 现为唯一解析路径。`:orchestrator_skill_source` / `:role_skill_sources` override 收拢为
   有据的测试 seam 或删除。
4. **`desired_skills`(OQ-2)。** 死的 `AgentTemplate.desired_skills` 域声明**不在此接线**范围;§7 记
   out-of-scope 并留一行 TODO —— 本分支不收拢也不删(另作决策)。

### 5.2 P3 验收 gate

- **`test/.../skill_cold_spawn_regression_test.exs`**(新,**先红**):**全新 `$EZAGENT_HOME` 上冷 agent
  spawn**(空 home → boot seed → registry → 物化)得
  `<config_dir>/skills/ezagent-session-orchestrator/SKILL.md` 在。对折叠前代码写红,折叠后绿。这是端到端
  事故回归。
- **`home_runtime` 测试**:原子换入的 config_dir 里 skills 在;幂等标记仍单一;**skill 升级后重物化拾新字节**
  (IC-2 修 —— 断言升级内容替换旧)。
- `orchestrator_bootstrap` 测试更新为移除拷贝路径(无 `copy_skill`/walk-up 悬引)。
- 常规 gate(§3.2)绿;`arch.scan` 确认 walk-up 已无。

### 5.3 P3 出口

全新 `$EZAGENT_HOME` 冷 spawn 拿到 skill;agent 内 skill 升级/删除经全新 staging 正确;walk-up 在码库不复存在。

---

## 6. 实现约束(来自设计 §7 —— 有约束力)

- **IC-1 —— 目录-hash 语义(已选定,非可选)。** skill 目录内容 hash 覆盖**目录闭包**,计算为:枚举目录下
  所有文件,构建 **`{relpath, exec_bit, content_digest}` 元组的排序集**(relpath = 相对 skill 根的
  POSIX 归一化路径;`exec_bit` = 文件 mode **刻意归一化为单一 owner-executable 布尔** —— 完整权限位
  **有意排除**:macOS 与 Linux 的拷贝/umask 语义在其余位上可能不同,会产生虚假的"运维改过"分类;对
  skill 脚本唯一有语义分量的就是 exec 位;`content_digest` = 文件字节的 SHA-256),对该排序集的规范
  序列化取 SHA-256。后果(全部必需):**重命名**改 relpath → hash 变;**删除**移除元组 → hash 变;
  **chmod +x** 翻 `exec_bit` → hash 变;只动非-exec 位的 chmod **不**变 hash(有意)。**空目录不影响
  hash**(只有文件贡献元组)—— 可接受且有意:种源内容 git 托管,git 本身不跟踪空目录,故任何随包闭包
  不可能只差一个空目录。**Symlink** hash 其**链接目标路径**(作 `content_digest` 输入),不跟随。
  (后续租户 store 须直接**拒绝** symlink 作逃逸向量 —— 为那阶段记,此处不实现。)此语义是 P2 索引契约
  的硬前置;实现为单一 `Ezagent.SkillRegistry.dir_hash/1`(或小 `Ezagent.Skill.ContentHash`),供 `SkillSeed`
  (shipped-hash)与索引共用。
- **IC-2 —— 升级正确性需 P3。** 拷贝搬进 `stage_and_swap`(P3,每次物化全新 staging)之前,已物化 agent 永不
  拾 skill 升级/删除(`copy_skill/3` 跳过已存在 dest)。P2 与 P3 之间,skill 升级因此需 config_dir 重生 —— **写进
  ops runbook**(与 §4.1.5 runbook 行并列)。
- **IC-3 —— 运行时子集派生,非手枚举。** P1 种子清单与 P1 不变量测试都从**全 `roles/0` 种子的
  `Recipe.skills`**计算(§2)。任何地方无手维护清单。
- **IC-4 —— 具名的种子包重生成 helper(本 SPEC)。** 入库的 `priv/skills_seed` 包由专用 mix 任务
  重生成 —— **`mix ezagent.skills.regen_seed`**(dev-only,与既有 `ezagent.*` 任务同在
  `apps/ezagent_core/lib/mix/tasks/`):跑 §2 派生遍历每个 `roles/0` 种子,把每个派生 ref 的
  dev-tree 闭包(`.claude/skills/<ref>/`)拷进 `apps/ezagent_web/priv/skills_seed/<ref>/`,并打印
  派生集 + hash。codex 在 P1 实现此任务(它是工作项 §3.1.1 的*产出方式*,非手拷),使包永不偏离
  派生规则;P1 prod 形态不变量测试是执法,此任务是补救。

### 6.1 待加 runbook 行(ops)

1. *skill-seed 跳过升级* —— 见 §4.1.5(两侧都变的恢复)。
2. *P3 前升级* —— *"P3 落地前,为已 spawn 的 agent 升级 skill 需重生其 `config_dir`(删 config_dir + 标记,
   使下次 spawn 重物化)—— 原地拷贝跳过已存在 dest。"*

---

## 7. 明确的范围外(后续阶段 —— 非本次交接)

- **工作区自定义 / 租户创作 skills**(`resource://<ws>/skills/<ref>` 经 `Resource.FsResolver` 的 per-`<ws>`
  权威;workspace→system 解析兜底)。
- **`resource://<ws>/skills` 资源类型**注册。
- **Skill CR 包装**(为暂存/评审/发布租户 skill 的 `ConfigGovernance.Skill` fork;skill 脚本的创作边界信任守卫)。
- **任何运行时可写发布面** —— P1–P3 store 仅由 boot/`home.init` seed 与有节点权限运维写。
- **`desired_skills` 接线**(OQ-2)—— 死 `AgentTemplate.desired_skills`;留 TODO,此处不收拢。
- **共享只读 skill store / symlink 密度**(OQ-3)—— 先每-agent `cp_r`。

---

## 8. 子步小结(codex checklist)

| 子步 | 落地 | 关键 gate(行为变更处先红) |
|---|---|---|
| **P1** | `priv/skills_seed`(派生集)+ `Ezagent.SkillRegistry` 读打包源 + `resolve_skill_source` 重接、walk-up `:dev`-gate | `skill_distribution_prod_shape_test`(红→绿);`skill_registry_test` |
| **P2** | `skills` 进 FsResolver/Home + `Home.SkillSeed`(shipped-hash 三态 + 两侧都变大声信号;**原子 staging-再-rename + boot 恢复**,HIGH-1)+ registry 重指 `$EZAGENT_HOME` 源 + ConfigObject 索引(`seed_object_upsert`) | `skill_seed_test`(四态矩阵含 telemetry/log 断言);**崩溃恢复 gate**;**全新-home 启动顺序 gate**(MED-2) |
| **P3** | 拷贝折进 `HomeRuntime.stage_and_swap`;独立拷贝 + walk-up 删除 | `skill_cold_spawn_regression_test`(红→绿);IC-2 升级拾新字节 |

**每个**子步的常规 gate:`mix format`、`mix compile --warnings-as-errors --force`、
`mix ezagent.check_invariants`、`mix ezagent.arch.scan`、`mix ezagent.doc.scan`(ratchet,代码核实 `@doc`)。
