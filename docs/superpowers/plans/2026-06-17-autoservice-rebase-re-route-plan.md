# autoservice-dev — Rebase + Re-route 处理规划

> 2026-06-17 | 待 Review

---

## Step 1: Rebase autoservice-dev 到最新 main

**目标**: 获取 #812/#814/#815/#820/#821 的 CapBAC 基础设施

```bash
git fetch github main
git rebase github/main
```

**预期冲突**: 5 个文件（与上次 rebase 相同的冲突点）：
- `catalog.ex` — turn-adapter 条目需要对齐 #821 的北星方向
- `arch.scan.ex` / `doc.scan.ex` — baseline
- `router.ex` / `liveview mix.exs` — 路径

**处理 turn-adapter**: rebase 后**删除** turn-adapter 的 catalog 条目（不进入 catalog，走 #814 模式）。

---

## Step 2: 从 fix/content-and-mechanical 挑选改动

### 直接吸纳（Cherry-pick）

| Commit | 内容 | 理由 |
|------|------|------|
| `00cf2d96` | ContentAdmin 新增 4 个 write action | backend ready |
| `11958f90` | ContentAdmin 新增 5 个 write action (batch 2) | backend ready |
| `2fe6ac9e` | roles.ex cap kind fix + #57 declared dep | latent bug fix |
| `b8590a03` | L0/L1 skill layering + member panel sandbox | bug fix |

### 不直接吸纳（需要适配 #814 模式后重写）

| Commit | 内容 | 原因 |
|------|------|------|
| `5bd12865` | Admin role grants ContentAdmin | 需要改为 `{:rule, ...}` 模式 |

### 不吸纳

| Commit | 内容 | 原因 |
|------|------|------|
| Admin LV 瘦身 commits | `fast_agent_live.ex` 等大幅删减 | 这些文件在 rebase 后需要重写 dispatch 调用方式，旧瘦身版本不兼容 |

---

## Step 3: Re-route admin UI 写路径

### 原则

1. **不改 core/domain** — 所有改动在 plugin 层
2. **不往 catalog 加 system principal** — 走 #814 `{:rule, name, configurer}` 模式
3. **每个 admin 写操作对应 1 个 ContentAdmin dispatch action**

### 实现模式

```elixir
# 之前（绕过了 dispatch）:
File.write!(sandbox_path, content)

# 之后（走 dispatch → CapBAC → telemetry）:
alias Ezagent.Identity.Grant  # ← #814 的统一关口

ctx = Grant.prepare_ctx(:rule, "content_admin_write", configurer_entity)
Invocation.dispatch(%Invocation{
  target: Ezagent.URI.new!("workspace://#{tid}?action=content_admin.write_soul"),
  mode: :call,
  args: %{role: "customer", content: content},
  ctx: ctx
})
```

### 具体改造清单

| Admin LV | 当前写路径 | 改为 dispatch | ContentAdmin action |
|------|------|:--:|------|
| `slow_agent_live.ex` Soul save | `File.write(souls/customer.md)` | `content_admin.write_soul` | ✅ 已有 |
| `slow_agent_live.ex` Slots save | `File.write(slots/customer.yaml)` | `content_admin.write_slots` | ✅ 已有 |
| `slow_agent_live.ex` Skill create/save/delete | `SkillStore.write/delete` | `content_admin.write_skill/delete_skill` | ✅ 已有 |
| `slow_agent_live.ex` KB add/delete | `KbStore.upsert/delete` | `content_admin.upsert_kb/delete_kb` | ✅ 已有 |
| `fast_agent_live.ex` Save | `File.write(config/fast_ack_prompt.md)` | `content_admin.write_fast_prompt` | ✅ 已有 (fix 分支) |
| KB URL fetch | `KbStore.fetch_url` | `content_admin.fetch_kb_url` | ✅ 已有 (fix 分支) |
| KB file upload | `KbStore.ingest_file` | `content_admin.ingest_kb_file` | ✅ 已有 (fix 分支) |
| KB rebuild | `KbRebuilder.rebuild` | `content_admin.rebuild_kb` | ✅ 已有 (fix 分支) |
| CR publish | `CrEngine.publish` | `content_admin.publish_cr` | ✅ 设计已有 |
| Version rollback | `File.ln_s` | `content_admin.rollback_version` | ✅ 已有 (fix 分支) |

### 安全侧

- 删除 `can_write? = admin_uri != nil`
- 让 CapBAC step 5.5 接管权限检查
- Admin role 的 cap 正确配置（`roles.ex` 中 `kind: :workspace, action: :any`）

---

## Step 4: 验证

- [ ] `mix compile --warnings-as-errors`
- [ ] 17 页面全部 HTTP 200
- [ ] 服务端 0 新错误
- [ ] KB search/upsert/delete 功能正常
- [ ] Soul/Slots/Skill 编辑保存正常
- [ ] CR publish 流程正常

---

## 执行顺序

```
Step 1: Rebase (预计 1 次冲突解决，删除 turn-adapter catalog)
  → commit "rebase: sync to latest main + remove turn-adapter catalog entry"
  
Step 2: Cherry-pick 4 commits from fix/content-and-mechanical
  → commit "feat(content): add 9 write actions to ContentAdmin"
  → commit "fix(roles): cap kind :content → :workspace"
  → commit "fix(skill): L0/L1 layering + member panel"

Step 3: Re-route admin LV (每个文件 1 commit)
  → fast_agent_live.ex: File.write → dispatch
  → slow_agent_live.ex: 6 tabs File.write → dispatch
  → init_wizard_live.ex: init File.write → dispatch
  → cr_dashboard_live.ex: publish → dispatch
  
Step 4: 安全 + 验证
  → 删除 can_write? 旁路
  → 全量测试
```

---

## 文件变更预估

| 操作 | 文件数 | 说明 |
|:--:|:--:|------|
| Rebase 冲突解决 | ~5 | catalog.ex, scan baselines, router.ex |
| Cherry-pick | ~4 | ContentAdmin, roles.ex, skill_loader |
| Admin LV dispatch 改造 | ~4 | fast/slow/init/cr |
| 安全侧 | ~2 | tenant_admin_live, operators_live |
| **总计** | **~15** | plugin-only, 0 core/domain |

---

> 请 Review，确认后开始执行。
