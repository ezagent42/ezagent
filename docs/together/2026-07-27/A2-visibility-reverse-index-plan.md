# A2 — caps_toward(正向可见性)+ grantees_of(反向索引)plan + DoD

分支:`feat/socialware-share-a2-visibility`(from main `20556be9f`)· Group A 第 2 件 · **纯 cap/identity 层,零 kanban 文件**

## 目标(additive)
1. **`caps_toward(caps, behavior)`**（正向）——从持有的 cap 集派生"指向某 behavior 的 target 实例集"。泛化 kanban 私有的 `union_cap_boards`（`world_data.ex:163`,硬编码 `behavior: Kanban`)。收 4 处 bespoke 可见性的"∩ 持 cap"过滤(kanban world_data / workspace_reads / session_reads / anon_admission 各写一遍 `list_caps_for + 手工过滤`)。
2. **`grantees_of(target, behavior)`**（反向索引）——"这个资源的 cap 发给了谁"。cap 存储无反向索引(`list_caps_for` 只正向),`:members` 今天在 biz 层手做此事。

## xy 调研(已定)
- **cap 结构** = `%Capability{kind, behavior, action, instance, workspace_uri}`(`capability.ex:40`)。正向读 = `Ezagent.Identity.list_caps_for(uri)`。
- **caps_toward** = 纯函数:`caps |> Enum.filter(&(&1.behavior == behavior)) |> Enum.map(& &1.instance) |> Enum.uniq`。无 DB 改动。
- **grantees_of 反向索引的写钩点** = cap 真正落地的存储收口 `Ezagent.EntityCaps.UserStore.persist/2`(identity absorb handler `identity.ex:264` 调它把 caps 写进 caps_json)。所有 cap 落地(含 member-cap)都过 absorb → persist。
- **撤销 = generation-bump 不删行**:反向行存 `key_id/generation`,读时按 target 当前 generation 过滤(镜像 `verify_against_current`,零新撤销机制)。

## PR 内步骤(TDD)
### caps_toward(先做,简单)
- `Ezagent.Cap.CapsToward`(或 `Ezagent.EntityCaps` 加函数):`caps_toward(caps, behavior) :: [URI.t()]`。**test**:多 behavior 混合的 cap 集只挑对的 behavior + 去重 + 空集。
- (迁 4 处 bespoke → 本 PR 只建通用函数;各处改调它归 Group B/各自 PR,避免碰 kanban/workspace 业务)。**A2 只建 + 单测,不迁消费者**(迁移碰业务层,违"infra 不掺业务")。

### grantees_of(反向索引)
- 新表 `cap_grants`(migration,repo_pg):`(target_uri, grantee_uri, behavior, actions_json, key_id, workspace_uri, inserted_at)`,index on `(target_uri, behavior)`。
- **写钩**:`EntityCaps.UserStore.persist` 落 cap 时同写反向行(派生投影,只读,永不反过来重发)。查证:确保 member-cap 也过此点。
- **读** `grantees_of(target, behavior \\ :any)`:查 `cap_grants` where target + 按 target 当前 generation(`Cap.Authority.current_generation`)过滤失效行。
- **test**:铸 cap → grantees_of 见 grantee;revoke_all_to(generation bump)→ grantees_of 不再见(旧行按 generation 失效)。
- `:members` 投影迁移**留 A4/后续**(碰 M-9,分两步)。A2 只建索引 + 接口。

## DoD(四性质)
- [ ] `caps_toward` 纯函数:混合 behavior 只挑对的 + 去重（单测）。
- [ ] `grantees_of`：铸 cap 后见 grantee；generation-bump 撤销后不见（派生失效，单测）。
- [ ] 反向行是**派生只读**：永不作为授权源、永不从它重 mint（设计守卫 + 注释）。
- [ ] **零 kanban / 零业务层文件**(纯 cap/identity + core migration);grep 确认。
- [ ] full suite CI 绿 + 提交后监控 + doc-coverage（新 public def 带 @doc）。

## 非目标(留后续)
- 迁 4 处 bespoke 可见性消费者(碰业务/world → Group B/各自)。
- `:members` 投影到 grantees_of(A4,碰 M-9 分两步)。
- caps_toward 与 grantees_of 相互独立,可先后落。
