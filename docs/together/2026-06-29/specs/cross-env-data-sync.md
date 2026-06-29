# Cross-Environment Data Sync — 三环境数据同步设计

> Status: **Design SPEC (research + design, pre-review)** — awaiting codex adversarial-review + Allen 复核。
> Author: Claude (research agent, 2026-06-29)
> Scope: 在 ezagent 三环境晋级阶梯(nightly / beta / stable)上,设计**跨环境 DATA 同步**。
> 上游设计:`docs/superpowers/specs/2026-06-25-deploy-flow-design.md`(三环境部署拓扑)。
> 仓库状态基准:`origin/main` @ `755b2a9b`(2026-06-29)。

---

## §0 — 两个目的(必须先分清)

跨环境"数据同步"是一个被笼统使用的词,实际承载**两个性质完全不同**的需求。
任何把它当成一件事来设计都会出错。本 SPEC 把它们分开。

### 目的 1 —— 迁移安全(Migration Safety)**〔首要 / 本期落地范围〕**

当一次升级会改变 **DATA FORMAT / schema**(ecto migrations、`ConfigObject.body`
形状、`kind_snapshots.state_binary` 结构、recipe / socialware-def 的 schema)时,
**先用真实 prod 数据在 nightly / beta 上把这次迁移跑一遍**,验证它不会丢数据 / 破坏数据,
然后再让 stable(prod)去跑同一份迁移。

这是经典的"用 prod 数据的副本做迁移预演(test migrations against a prod-data copy)":
stable 的数据是被保护的资产,任何破坏性变更在抵达 stable 之前必须先在低环境
拿 prod-shaped 数据试过。

**触发:每次包含新 migration 的升级(per-upgrade),不是持续同步。**

### 目的 2 —— 运行时数据传播(Runtime-Data Propagation)**〔次要 / 本期仅设计、defer 实现〕**

一个在 prod(stable)上**运行时创建**的 agent / recipe / socialware-def(例如 #1069 P7
dual-path 编辑器编出来的 user-authored recipe;或自举 dogfood 里用 prod UI 创建的
E2E-runner agent),可能需要**也存在于 beta / nightly**。这是把"运行时产生的定义"
跨环境带过去。

**触发:按需(operator-driven),非每升级。**

### 两者不能共用一套机制,因为方向相反

| | 目的 1(迁移安全) | 目的 2(运行时传播) |
|---|---|---|
| 数据流向 | **stable → beta/nightly**(prod 数据下行,供低环境预演) | 待分析(§3 结论:stable → 也下行,但**仅定义**) |
| 频率 | 每升级一次 | 按需 |
| 范围 | **整库 PG**(schema + 全部运行时数据,这样迁移才暴露真问题) | 仅 ConfigStore 里的**定义**(recipe / socialware-def),绝不含 session 状态 |
| 是否覆盖低环境数据 | **是**(beta/nightly 数据是可抛弃的,整库覆盖) | 否(merge / skip-if-exists,不覆盖目标已有定义) |
| 是否涉及 home 卷 | **否**(PG-only;home 卷的凭据/工作目录不抄) | 否(定义在 PG,不在 FS) |

> §2 设计目的 1;§3 设计目的 2(并论证为什么本期 defer)。

---

## §1 —— 现状:数据如何隔离、迁移如何运行(cited)

### §1.1 三环境 = 三个独立 Postgres(独立容器 + 独立卷 + 独立 DB)

参数化的 `docker/docker-compose.yml`(`origin/main`)用 compose project 名做命名空间,
一次定义、三通道复用:

```yaml
# docker/docker-compose.yml
name: ezagent-${CHANNEL:?set CHANNEL in .env.<channel>}
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: ezagent
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?...}
      POSTGRES_DB: ezagent_${CHANNEL}     # ← DB 名随通道变
    volumes:
      - pg:/var/lib/postgresql/data        # ← named volume → ezagent-<channel>_pg
    networks: [private]
volumes:
  pg:   # → ezagent-<channel>_pg(项目命名空间自动隔离)
  home: # → ezagent-<channel>_home
```

(`docker/docker-compose.yml` L1–L40、volumes 块。)于是:

| 通道 | compose project | DB 名 | PG 卷 | home 卷 |
|---|---|---|---|---|
| nightly | `ezagent-nightly` | `ezagent_nightly` | `ezagent-nightly_pg` | `ezagent-nightly_home` |
| beta | `ezagent-beta` | `ezagent_beta` | `ezagent-beta_pg` | `ezagent-beta_home` |
| stable | `ezagent-stable` | `ezagent_stable` | `ezagent-stable_pg` | `ezagent-stable_home` |

**确认:三个 PG 实例彼此完全隔离**(独立容器 + 独立 named volume + 独立 DB),
PG 只在各自通道的 `private` 网络里,绝不外露。这正是本设计要"打通"的前提:
隔离是事实,跨环境数据流动**必须显式 operator 动作**,不存在隐式同步。

> 注:还有一个遗留的单环境 `docker/docker-compose.prod.yml`(DB `ezagent_prod`,
> `prod_pg` / `prod_home`),是 #942 全容器化时的单环境版。三环境版以参数化
> `docker-compose.yml` 为准;`.prod.yml` 在三环境落地后退役(本 SPEC 不依赖它)。

### §1.2 两类数据:code-seeded(每次开机重派生)vs runtime-created(只活在当前 env 的 PG)

ezagent 的数据有两类来源,这对同步设计是关键:

**A. Code-seeded built-ins —— 同一镜像在任何 env 开机都会重派生,不需要同步。**
- 插件的 `roles/0` 声明 → `Ezagent.Plugin.RoleSeedHook` → `RecipeRegistry.seed_role_if_absent/2`
  在 boot 时把 role 写成 ConfigObject,落在 `workspace://system`。
  幂等且 override-safe:已存在指针则不写,**租户已发布的运行时改写不会被重启覆盖**。
  (`apps/ezagent_core/lib/ezagent/plugin/role_seed_hook.ex`;
  `apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex` moduledoc §"Seeding"。)
- 插件包的 `seed_refs`(priv/ 里的 recipe JSON)→ `Ezagent.Plugin.SeedHook` 在
  `Ezagent.PluginPackage.install/1` 时写入。(`apps/ezagent_core/lib/ezagent/plugin/seed_hook.ex`。)

→ **结论:built-in recipe / socialware-def 是代码的函数,不是状态。** 同一镜像在 nightly
和 stable 开机都会得到同一份 built-ins。目的 2 的"传播"只对**运行时创建**的定义有意义。

**B. Runtime-created data —— 只活在当前 env 的 PG,是真正需要(在目的 1 里)被复制、(在目的 2 里)被传播的对象:**
- `kind_snapshots` 表:`uri` 主键 + `state_binary`(`:erlang.term_to_binary/1` 的完整 slice map,
  无损保留 MapSet/URI/DateTime/atom)+ `workspace_uri` + `ever_created`。
  这是**所有 Kind 实体(agents / sessions / templates / workspaces)的持久状态**。
  (`apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex` schema。)
- `socialware_config_objects`(append-only 不可变)+ `socialware_config_pointers`(repoint 实现更新/回滚)。
  `body` 是 JSON map;三层 cascade:workspace / user / session。
  recipe 的存储形状:`subject_uri = config://<ws>/recipe/<name>`、`key = "recipe"`、layer = workspace。
  (`apps/ezagent_domain_identity/lib/ezagent/socialware/config_object.ex`;
  `apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex` `@layers`、`write_and_point/1`。)
- 身份与运营数据:`users` / `entity_profiles` / `feishu_user_bindings` / `magic_link_tokens` /
  `protocol_api_keys` / `invite_codes` / `messages` / `message_routings` /
  `socialware_anon_bindings` / `socialware_settlements` / `routing_rules` / `workspaces` /
  `credential_grants` 等(62 条迁移累计出的 schema,
  `apps/ezagent_core/priv/repo/migrations/*.exs`)。
- **home 卷(FS,非 PG)**:`EZAGENT_HOME=/data/<profile>/` 下的 `credentials/`(feishu.yaml、
  smtp_config.json、per-agent OAuth)、`snapshots/`、`logs/`、agent 工作目录(git checkout、
  node_modules)、`runtime/secret_key_base`。(`docker/entrypoint.prod.sh`。)

### §1.3 迁移在每次开机时自动运行(release `bin/ezagent`)

prod 容器入口脚本在启动 release **之前**显式跑迁移:

```bash
# docker/entrypoint.prod.sh
echo "[entrypoint.prod] migrating (Postgres via DATABASE_URL)"
/app/bin/ezagent eval "EzagentCore.Release.migrate()"
echo "[entrypoint.prod] starting release on :${PORT:-10042} ..."
exec /app/bin/ezagent start
```

`EzagentCore.Release.migrate/0` 对每个 repo 跑 `Ecto.Migrator.run(repo, :up, all: true)`
(幂等,跑完所有 pending)。
(`apps/ezagent_core/lib/ezagent_core/release.ex`。)

此外 `EzagentCore.MigrationGate` 被接进 `EzagentCore.Application` 的 `{Ecto.Migrator, ..., skip: ...}`,
当 `RELEASE_NAME` 已置(release 模式)或 `MIX_ENV=prod` 时**开机自动迁移**;
`EZAGENT_SKIP_MIGRATIONS=1` 是逃生阀。
(`apps/ezagent_core/lib/ezagent_core/migration_gate.ex`。)

→ **结论:每次部署新镜像 = 一次自动迁移。** build-once / re-tag 下,stable 晋级到镜像 X 时,
entrypoint 会对 **stable 自己的 prod 数据**跑 X 里累计的所有 pending migration。
**这正是目的 1 要保护的时刻:这个迁移此前只在该镜像的低环境部署里跑过,跑的是低环境那份
小、假、与 prod 形状不同的数据。** 它没在 prod-shaped 数据上验过就抵达了 prod。

### §1.4 现有的部署 / 备份原语(§5 重用清单的根据)

- **`docker/deploy.sh <channel>`** —— build-once / promote-artifact 部署:
  仅 nightly 允许构建;beta/stable **fail-closed 拒绝重编**(必须用已存在的 `ezagent:<sha>`)。
  `docker tag` 后 `up -d --force-recreate ezagent`,然后**直接读容器 health**,
  不健康则自动回滚到上一镜像(`PREV` image id)。(`docker/deploy.sh`。)
  → 含义:**硬迁移失败(migrate 抛异常 → 容器不健康)已经被 deploy.sh 的 health 门 + 自动回滚兜住。**
  目的 1 要补的是"软破坏"(迁移成功但数据语义坏了)和"prod-volume 才暴露的性能问题"。
- **`docker/backup.sh <channel>`** —— 逐域逻辑备份到 `./backups/<channel>/<ts>/`:
  `pg_dump -U ezagent -d ezagent_<channel> | gzip > db.sql.gz` +
  `fs-snapshot.tar.gz`(排除 node_modules / _build / deps) + `manifest.json`
  (明确标注 `atomic: false`,DB 与 FS 非单一一致快照)。
  (`docker/backup.sh`。)→ **这就是 prod→下行复制的现成 PG dump 路径。**
- **`mix ezagent.home.backup` / `mix ezagent.home.restore`** —— 全 home + DB 可移植备份:
  `pg_dump --format=custom`;**restore 会重写 `kind_snapshots.state_binary` 里的持久化绝对路径**
  (`config_dir_path` / `agent_config_dir`,从源 profile dir 改写到目标 profile dir)。
  (`apps/ezagent_core/lib/mix/tasks/ezagent.home.restore.ex`;
  `apps/ezagent_core/lib/mix/tasks/ezagent.home.backup.ex`;
  `docs/scenarios/31-home-backup-restore-migration/scenario.md`。)
  → 含义:跨机/跨路径恢复的路径改写机制**已存在**(目的 1 可直接重用;见 §2.5 的"跨环境是 no-op"结论)。

---

## §2 —— 目的 1 设计:迁移安全(stable prod 数据 → 下行预演)

### §2.1 核心论点:build-once 让"用 prod 数据预演迁移"既必要又充分

- **必要**:stable 跑的是镜像 Y(较旧,schema v_N)。候选镜像 X 里带了 migration 把 schema 推到 v_M。
  迄今 X 只在 nightly/beta 部署过 —— 跑的是低环境那份**小、且形状偏离 prod** 的数据
  (nightly 是实验数据,beta 是种子 + 少量冒烟数据)。**v_N → v_M 这段迁移路径从未在 prod 数据上走过。**
  迁移可能在 prod 数据上才暴露的问题:
  1. **NOT NULL / unique 约束违反**:prod 有历史行违反新约束(低环境干净数据触发不了)。
  2. **backfill 超时 / 锁表**:prod 行数大,一个 `UPDATE` 全表回填在低环境瞬时、在 prod 可能小时级或锁库。
  3. **`state_binary` / `body` 形状改写**:`kind_snapshots.state_binary` 是 `term_to_binary` 的 Erlang term,
     migration 若解码/改写它(如 home.restore 那样的路径改写、或 atom 重命名),prod 的 term 可能含
     低环境没见过的形状 → 静默 corrupt。
  4. **schema 重命名 / 列删除** 而 snapshot blob 还引用旧字段 → 软破坏。
- **充分**:三环境**逐字节同镜像**(build-once)。所以在 beta 上用镜像 X 跑出来的迁移行为,
  和 X 抵达 stable 后跑出来的**完全一致** —— 唯一变量是数据。把"prod 数据副本"喂给 beta,
  就**正好**把那条未走过的 v_N → v_M 在 prod-shaped 数据上跑了一遍。build-once 在这里是**使能条件**,
  不是障碍。

### §2.2 流程(per-upgrade 迁移预演)

每次含新 migration 的晋级(stable 升级到新 SHA),在 stable 晋级**之前**插入一次预演:

```
                  ┌──────────────── 1. pg_dump stable ───────────────┐
                  │   ezagent_stable → stable.prod.sql.gz(-F custom) │
                  │   (reuse backup.sh 的 pg_dump 路径;可选 scrub §2.4)│
                  └──────────────────────────┬───────────────────────┘
                                             │
              ┌── 2. 目标低环境(beta 优先;nightly 兜底)整库覆写 ──┐
              │   drop + recreate ezagent_beta,pg_restore 导入        │
              │   (beta 原数据是可抛弃的实验/冒烟数据)                 │
              └──────────────────────────┬───────────────────────────┘
                                         │
          ┌── 3. 部署候选镜像到 beta(deploy.sh beta;build-once)──┐
          │   entrypoint 自动 Release.migrate() 跑 v_N → v_M       │
          │   对着刚导入的 prod-shaped 数据                          │
          └──────────────────────────┬───────────────────────────┘
                                     │
            ┌── 4. 验证门(§2.3)──┐
            │   硬失败:deploy.sh health + 自动回滚(已存在)│
            │   软失败:smoke e2e + 抽样查询(新增)         │
            └────────────────┬─────────────────────────┘
                             │
                ┌── 5. 绿 → 晋级 stable(deploy.sh stable)──┐
                │   同一镜像 X,这次对 stable 自己的 prod 数据 │
                │   跑同一段 v_N → v_M(已在 beta 验过)        │
                └────────────────────────────────────────────┘
```

- **频率**:每升级一次(仅当候选镜像含新 migration;可用 `Mix.Tasks.Ecto.Migrate` 的
  `--log` 或对比 `priv/repo/migrations` 目录在两个 SHA 间的 diff 判断是否触发)。
  不是 cron、不是持续。
- **方向**:stable → beta(首选)/ nightly(兜底)。beta 比 nightly 更适合,因为 beta
  的代码轨迹(`beta` ref)就是要晋级到 stable 的那一格;让 beta 拿 prod 数据预演,
  就是把"晋级前最后一道门"做实。nightly 数据更脏(每晚 main HEAD),适合做兜底。
- **覆写语义**:beta/nightly 的数据整库被覆盖 —— **这是设计意图**,低环境数据是可抛弃的。
  与目的 2(merge、不覆盖)根本不同(§0 表)。

### §2.3 验证门:超过"容器健康"才算过

`deploy.sh` 已有的 health check(GET `/` 200,40s `start_period`)能抓**硬失败**(migrate 抛异常
→ entrypoint 非 0 → 容器不健康 → 自动回滚到 PREV)。但抓不住**软破坏**。预演必须额外验:

1. **迁移日志无 warning/error**:`docker logs <ezagent-beta> 2>&1 | grep -iE 'migrate|error|warning'`,
   确认 `EzagentCore.Release.migrate()` 返回 `{:ok, _, _}`、无 `(Ecto.MigrationError)`。
2. **行数对照**:对一组关键表(`kind_snapshots`、`socialware_config_objects`、`users`、`messages`)
   对比 stable 源库 vs beta 导入后 vs 迁移后,行数应一致(或可解释的增量)。
   `SELECT count(*) FROM <t>;` 三处对齐。
3. **抽样语义完整**:随机 N 条 `kind_snapshots.state_binary` 能被 `:erlang.binary_to_term/1`
   解码且字段齐全(`uri` / `workspace_uri` / `ever_created`);随机 N 条 ConfigPointer 指向的
   ConfigObject 仍存在(`pointer.config_id` 外键完好)。
4. **冒烟 e2e**:复用 `docs/phase-specs/<phase>/VERIFICATION.md` 里的 smoke flow,
   至少跑"建 session + 发一条消息 + dispatch 成功"。
5. **(可选,当 stable 数据量大时)迁移耗时记录**:记下 beta 上 v_N → v_M 的耗时,
   作为 stable 晋级的 SLA 参考(若 beta 耗时已接近 maintenance window 上限 → 触发在线扩容评估)。

> 这 5 条是"软破坏"的最低门槛。把它们落成一个 `verify-rehearsal.sh`(§5 NEW 清单)。

### §2.4 scrub:把 prod 数据带进低环境前的卫生处理

stable 的 PG dump 含**真实用户内容 + 身份 + 凭据引用**;低环境(beta/nightly)虽然只
tailnet 可达、operator 可信,但仍应遵循最小化原则。scrub 策略(按强度递增,选其一):

- **方案 A(最简 / 推荐起步):PG-only + 不 scrub,接受 tailnet 信任域。**
  低环境 tailnet-only、operator-only;不公网。把 prod dump 整库导入 beta,不 scrub。
  优点:零额外机制、dump 是真正的 prod-shaped(预演最真实)。缺点:prod PII / 凭据引用
  落到 beta。**适合单 operator、tailnet 全信任的当前阶段。**
- **方案 B(推荐演进):`pg_dump --exclude-table-data` 抹掉敏感表的行(保留 schema)。**
  对 `magic_link_tokens`、`protocol_api_keys`、`invite_codes`、`socialware_anon_bindings`
  这类纯凭据/令牌表,导出时只导 schema、不导行(`--exclude-table-data=<t>`,可多次)。
  `users` / `entity_profiles` 仍保留(登录路径才能验),但 `entity_profiles` 里的 email
  可用 `pg_restore` 后一条 `UPDATE` 做 mask。优点:不削弱迁移预演真实性(这些表的 schema
  仍参与迁移),只去掉"低环境不该有的活令牌"。缺点:多一个 scrub 步骤。
- **方案 C(最严,本期不做):列级 redact / 合成数据替换。** 留 TODO。

**关键:redact 不能伤及 schema。** scrub 只动 `--exclude-table-data`(行级)或 `UPDATE`(值级),
绝不改 DDL —— 否则预演就不再是 prod-shaped 迁移测试,失去了目的 1 的意义。

### §2.5 build-once 张力 & 跨环境路径改写(已是 no-op)

- **home 卷不抄。** 目的 1 是 PG-only:迁移是 schema + 数据的事,home 卷(凭据、agent 工作目录)
  与迁移无关,且含真实凭据 —— 低环境用自己的 `SECRETS_DIR=./secrets-<channel>` 和自己的 home 卷。
  (`docker/docker-compose.yml` 的 `SECRETS_DIR` / `secrets-<channel>`。)
- **`home.restore` 的路径改写在跨环境场景是 no-op,但机制现成。** `mix ezagent.home.restore` 会
  把 `kind_snapshots.state_binary` 里的 `config_dir_path` / `agent_config_dir` 从源 profile dir
  改写到目标 profile dir。三环境的 profile dir 都是 `/data/default`(路径相同、只是挂的是不同的
  named volume:ezagent-`<channel>`_home)→ **源 = 目标,改写为空操作**。这意味着:
  用 `pg_dump`/`pg_restore`(纯 SQL,不走 home.restore 的 term 改写)就足够,**不需要** path rewrite。
  但如果将来哪天低环境的 profile dir 偏离 `/data/default`,要切到 `home.restore` 走改写路径
  (机制已验证,scenario 31 green)。
- **跨环境数据导入后,per-agent OAuth / sandbox 凭据会缺失**(它们在 home 卷里,没抄)。
  → 导入后那些 agent **能在 PG 里被列出(snapshots 解码完整),但不能真正跑**
  (子进程没有 OAuth)。这对**迁移预演**没问题(目的 1 只验迁移本身 + 数据语义,不验 agent 执行);
  对**目的 2** 才是问题(定义要能跑),这也是目的 2 更难、本期 defer 的原因之一。

---

## §3 —— 目的 2 设计:运行时数据传播(本期 design-only / defer)

### §3.1 方向分析:哪一种"向外"对数据成立?

代码晋级方向是 nightly → beta → stable(build-once,新代码向外传播)。**数据能否复用同一方向?**
逐一对照三个环境的语义:

| 通道 | 代码 | 数据性质 | 数据是否"该向外传播" |
|---|---|---|---|
| nightly | main HEAD(最新、实验) | 实验数据、每晚、可抛弃 | **否** —— 实验数据污染 curated 环境 |
| beta | beta ref(准晋级) | 种子 + 冒烟 + 少量手测 | 否 —— 过渡态 |
| stable | release ref(prod) | **curated、真实用户、运营产出** | **是(仅定义)** |

- **"latest outward"(nightly → beta → stable)对数据不成立**:nightly 数据是实验性的、每晚重置,
  把它往外推等于把实验污染进 prod。代码可以最新向外,因为代码有 CI 门禁 + review;数据没有。
- **"curated outward"(stable → beta → nightly)对**运行时**定义成立**:一个 operator 在 prod 上
  真实使用时创建的定义(例如自举 dogfood 里用 prod UI 建的 E2E-runner agent、或 #1069 dual-path
  编辑器编出的 user-authored recipe),是"被真实使用打磨过的 curated 定义",把它带回低环境
  让低环境用**更新的代码**跑这份定义 —— 这才是有意义的传播方向。

**方向结论:stable → beta/nightly,且仅限运行时定义(ConfigStore 里的 recipe / socialware-def)。**

### §3.2 范围:定义 only,绝不带 session/state

- **传播**:ConfigStore 的 ConfigObject(`subject_uri` ∈ recipe / socialware-def、`key="recipe"` 等、
  layer = workspace)。这些是**可重建、无状态、幂等**的定义。
- **绝不传播**:
  - `kind_snapshots` 的 session/agent 运行态(对话历史、membership、transient state)——
    这是某环境独占的执行轨迹,跨环境带过去无意义且冲突。
  - 身份数据(users / tokens / bindings)—— 与环境凭据强绑定。
  - home 卷 —— 见 §2.5。
- **与目的 1 的根本区别**:目的 1 抄整库(含 snapshots),为的是暴露迁移问题;目的 2 只抄定义,
  为的是让一份 curated 定义跨环境可用。两件事不能混用同一份数据。

### §3.3 冲突处理(设计决策,留给 Phase 2 实现)

ConfigStore 的定义身份是 `(workspace_uri, subject_uri, key)` 三元组 + 三层 cascade。
导入 stable 的定义到 nightly 时:

- **默认 skip-if-exists**:目标环境同三元组已有指针 → 不覆盖(尊重低环境自己的实验)。
  重用 `RecipeRegistry.seed_role_if_absent/2` 的 `seed_object_if_no_pointer` 语义
  (`Ezagent.Socialware.ConfigStore.seed_object_if_no_pointer/1` —— pointer 存在则 `:nothing`,
  divergent body 才报 collision)。
- **跨 workspace 层叠**:built-ins 在 `workspace://system`,运行时定义在具体 workspace。
  导入时保留原 `workspace_uri`(不重映射),靠 RecipeRegistry `lookup/2` 的 cross-ws fallback
  天然生效。(`recipe_registry.ex` §"Read-through" step 3。)
- **版本化**:SessionTemplate 已是 `template://session/<ws>/<name>@<hash>` 内容寻址
  (`ezagent-socialware` SKILL);导入时哈希不变即同版本,天然去重。

### §3.4 为什么本期 defer

1. **需求面窄**:built-ins 已由代码每次开机重派生(§1.2 A);只有"operator 在 prod 运行时创建
   且希望在低环境复用"的定义才需要传播。当前只有自举 dogfood 一个用例在视野内。
2. **与 build-once 的张力更尖锐**:低环境跑新代码、新 schema;stable 的运行时定义是在旧 schema 下
   写的。导入后可能因 schema drift 无效,需要在导入时跑一遍 `Recipe.new/1` 验证(机制存在,
   但要接进流程)。
3. **目的 1 的优先级压倒性**:迁移安全保护的是 prod 数据资产(不可替换);目的 2 是便利性。
   先把目的 1 落地。

> Phase 2 实现细节(skip-if-exists 导入脚本、schema-drift 校验门、UI 入口)留 TODO,
> 等 自举 dogfood 把需求压实再 writing-plans。

---

## §4 —— 分期建议

### Phase 1 —— 迁移安全(落地范围)

**交付物:**
1. `docker/rehearse-migration.sh <target-channel>` —— operator 脚本:
   pg_dump stable →(可选 scrub)→ drop+recreate 目标 DB → pg_restore → `deploy.sh <target-channel>` → `verify-rehearsal.sh`。
2. `docker/verify-rehearsal.sh <channel>` —— §2.3 的 5 条验证门(日志 grep、行数对照、snapshot 解码、pointer 外键、smoke e2e)。
3. `docker/scrub.sql`(可选,方案 B)—— `--exclude-table-data` allowlist + 一条 email mask UPDATE。
4. 文档:把 `docs/guide/deploy-mac-stack.md` 升级为三环境版,加入"晋级前迁移预演"一节
   (与 `2026-06-25-deploy-flow-design.md` §8 模块 6 对齐)。

**触发集成**:在 `deploy.sh stable` 之前(或 CI 的 stable 晋级门里)提示/要求近期一次
`rehearse-migration.sh beta` green。本期可先文档约定(operator 自觉),后续再机械化门禁。

**验收**:任取一段含新 migration 的候选镜像 → `rehearse-migration.sh beta` 跑通 →
故意注入一条会在 prod 数据上违反约束的 migration → 验证门**红、拦截 stable 晋级**。

### Phase 2 —— 运行时数据传播(设计 only / defer)

- 本 SPEC §3 已给出方向(stable→)、范围(定义 only)、冲突规则(skip-if-exists)。
- 触发条件:自举 dogfood 或第二个用例把需求坐实。
- 实现占位:一个 `import-definition.sh <target-channel> <subject-uri>`(从 stable 导出单个 ConfigObject → 导入低环境,走 `seed_object_if_no_pointer`)。

---

## §5 —— 重用 vs 新建(不重新发明轮子)

| 能力 | 重用 | 出处 |
|---|---|---|
| prod PG 一致 dump | `pg_dump`(PG 自带) | 已用于 `docker/backup.sh` |
| 整库覆写导入 | `pg_restore` / `dropdb`+`createdb`+`psql` | PG 自带 |
| build-once 部署 + health + 自动回滚 | `docker/deploy.sh` | `docker/deploy.sh` |
| 迁移执行 | `EzagentCore.Release.migrate/0` + `MigrationGate` | `entrypoint.prod.sh` 已调 |
| 跨路径 snapshot 改写(跨环境 no-op,但备用) | `mix ezagent.home.restore` | scenario 31 |
| 定义级 skip-if-existent 导入 | `ConfigStore.seed_object_if_no_pointer/1` | `config_store.ex` |
| recipe 验证边界 | `Recipe.new/1` | `recipe_registry.ex` |
| **新建** | `rehearse-migration.sh` + `verify-rehearsal.sh`(+ 可选 `scrub.sql`) | 本 SPEC §4 |

**净新建 = 2 个 operator 脚本 + 1 个可选 SQL**。其余全部重用现有原语。
没有新 Elixir 模块、没有新表、没有新迁移。

---

## §6 —— 开放问题(给 Allen / codex review)

1. **beta vs nightly 谁做预演靶?** 本 SPEC 倾向 beta(它就是"准 stable")。但如果 beta 的数据
   本身要保留(例如 dogfood 在跑),是否轮流?或专门用一个"rehearsal"通道?
2. **stable 数据量当前规模**:若 stable 目前只有几十行(早期 prod),迁移预演的"性能/锁"
   维度(§2.3 第 5 条、§2.2 失败模式 2)测不出来 —— 预演真实性强依赖数据规模。
   要不要在 scrub 阶段顺带**放大**数据(合成扩量)?Phase 2+ 议题。
3. **scrub 方案选择**:起步用 A(不 scrub)还是 B(`--exclude-table-data`)?取决于 tailnet 信任域
   是否真只 operator 可达、以及合规要求。
4. **触发机械化**:Phase 1 先文档约定;要不要直接做 CI 门(stable 晋级必须最近一次
   `rehearse-migration` green)?成本:CI 里跑 prod-data 副本要一套临时 PG。
5. **目的 2 的 schema-drift 校验**:导入 stable 定义到更新 schema 的 nightly 前,要不要强制
   `Recipe.new/1` 通过?若失败是拒绝导入、还是自动迁移定义形状?
6. **与 `2026-06-25-deploy-flow-design.md` §5.2 备份的关系**:本 SPEC 的 pg_dump 与该设计的
   `./backups/<env>/` 是同一份产物吗?(是。)应该让 `rehearse-migration.sh` 直接复用最近一份
   stable backup,而不是单独再 dump 一次 —— 待确认备份频率是否跟得上晋级频率。

---

## 附:来源(cited paths, `origin/main` @ 755b2a9b)

- 拓扑 / 部署:`docs/superpowers/specs/2026-06-25-deploy-flow-design.md`;
  `docker/docker-compose.yml`;`docker/docker-compose.prod.yml`;`docker/deploy.sh`;
  `docker/entrypoint.prod.sh`;`docker/.env.channel.example`。
- 迁移:`apps/ezagent_core/lib/ezagent_core/release.ex`;
  `apps/ezagent_core/lib/ezagent_core/migration_gate.ex`;
  `apps/ezagent_core/priv/repo/migrations/*.exs`(62 条);
  `config/runtime.exs`(`DATABASE_URL` / `priv: "priv/repo_pg"`)。
- 数据模型:`apps/ezagent_core/lib/ezagent_core/repo.ex`;
  `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex`;
  `apps/ezagent_domain_identity/lib/ezagent/socialware/config_object.ex`;
  `apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex`;
  `apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex`。
- seed(代码派生 built-ins):`apps/ezagent_core/lib/ezagent/plugin/role_seed_hook.ex`;
  `apps/ezagent_core/lib/ezagent/plugin/seed_hook.ex`。
- 备份/恢复原语:`docker/backup.sh`;
  `apps/ezagent_core/lib/mix/tasks/ezagent.home.backup.ex`;
  `apps/ezagent_core/lib/mix/tasks/ezagent.home.restore.ex`;
  `docs/scenarios/31-home-backup-restore-migration/scenario.md`。
- Skills:.claude/skills/ezagent-developer、.claude/skills/ezagent-socialware。
