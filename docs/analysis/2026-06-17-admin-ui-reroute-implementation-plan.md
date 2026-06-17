# Admin UI → ContentAdmin dispatch:re-route 实施计划

> **作者**:FatNine 团队(Claude Code)· **日期**:2026-06-17 · **配套**:`2026-06-17-autoservice-ezagent-native-assessment.md`(评估)
> **状态**:实施计划。**caps PR(`#88`/`#154` 授予机制)落地后即可执行**(只有"给 admin 用户授 cap"那一步等它;其余可先做)。
> **目标**:把 admin UI 的 **85 处直接 `File.write`/`Store.write`(59 个写 `handle_event`)** 收敛到 **`ContentAdmin` Behavior 的 dispatch action**,使每个写操作自动 **cap-gated + CLI-reachable + 可审计**,关掉 `can_write? = admin_uri != nil` 的安全洞。**E2E 不变。**

---

## 1. 原则(为什么)

新 ezagent:**UI 是 transport,写操作走 dispatch → Behavior**。`ContentAdmin`(`apps/ezagent_plugin_content/lib/.../behavior/content_admin.ex`,`use Ezagent.Lifecycle`,每 action 声明 `required_caps/0`)就是这条路径,已有 7 个 action 被测、能用。re-route = 把剩余写操作也搬上来。收益结构性免费:CapBAC(P15)、CLI parity(LvCliParity guard)、dispatch telemetry(审计)、LV 瘦身(过 OversizedModules)。

## 2. 现状映射(实测)

| 写操作族 | 底层调用(现在直接在 LV 里) | 涉及 LV 文件 |
|---|---|---|
| Soul / Slots | `ensure_dir_and_write` → `soul.md` / `slots.yaml` | tenant_admin_live、platform_soul_live |
| Skill | `SkillStore.write/delete/read` | tenant_admin_live、platform_skill_live |
| KB | `KbStore.upsert/delete/fetch/ingest/rebuild` | tenant_admin_live、init_wizard_live |
| CR / Publish | `CrEngine.publish/publish_items/revert_item/ensure_active_cr` | tenant_admin_live、init_wizard_live、cr_dashboard、version_timeline |
| Fast Agent | `File.write` → `fast_ack_prompt.md` | fast_agent_live |
| Operators | `add_operator/disable_operator`(身份/cap)| operators_live |

**ContentAdmin 现有 7 action**:`write_soul_slot` / `write_skill` / `delete_skill` / `upsert_kb` / `delete_kb` / `publish_cr` / `preview_sandbox`。

## 3. 目标 action 集(7 → ~18)

> 原则:**按"数据语义"归并,不按 UI 事件 1:1**(59 个 UI 事件里很多是同操作的变体:`kb_add`/`kb_add_manual`/`manual_add`;`save`/`save_slot`/`save_all_yaml`;`create_skill`/`new_skill`/`save_skill`)。

| # | action | 覆盖的 UI 事件 | 底层逻辑(从 LV 搬入) | 状态 |
|---|---|---|---|---|
| 1 | `write_soul_slot` | save_soul, save_slots, save_all_yaml, add/insert/delete_slot | `ensure_dir_and_write` soul/slots | ✅ 已有 |
| 2 | `write_skill` | skill_save | `SkillStore.write` | ✅ 已有 |
| 3 | `create_skill` | create_skill, new_skill | `SkillStore.write`(空模板) | 🆕 |
| 4 | `delete_skill` | skill_delete | `SkillStore.delete` | ✅ 已有 |
| 5 | `upsert_kb` | kb_add, kb_add_manual, manual_add | `KbStore.upsert` | ✅ 已有 |
| 6 | `delete_kb` | kb_delete | `KbStore.delete` | ✅ 已有 |
| 7 | `fetch_kb_url` | kb_fetch_url, fetch_url | `KbStore.fetch` + `ingest` | 🆕(异步,见 §6) |
| 8 | `upload_kb_file` | kb_upload, consume_kb_uploads | `KbStore.ingest`(上传文件) | 🆕 |
| 9 | `rebuild_kb` | kb_rebuild, rebuild | `KbStore.rebuild` | 🆕 |
| 10 | `delete_kb_source` | delete_source | source 删除 | 🆕 |
| 11 | `write_fast_prompt` | save_fast_prompt | `File.write` fast_ack_prompt.md | 🆕 |
| 12 | `publish_cr` | publish | `CrEngine.publish` | ✅ 已有 |
| 13 | `publish_items` | (per-item publish) | `CrEngine.publish_items` | 🆕 |
| 14 | `revert_item` | revert_item | `CrEngine.revert_item` | 🆕 |
| 15 | `rollback_version` | rollback | version timeline 回滚 | 🆕 |
| 16 | `edit_glossary` | glossary_add/update/delete | glossary 文件 | 🆕 |
| 17 | `preview_sandbox` | preview | 预览会话 | ✅ 已有 |
| 18 | `manage_operator` | add_operator, disable_operator | **身份/cap 操作 → 可能走 IdentityAdmin,不是 ContentAdmin**(见 §7) | 🆕(归属待定) |

> AI assist(`ai_submit/accept/reject`)是 LLM 调用 + 草稿,不直接写持久内容 → **保留在 LV**(它最终通过上面某个 write action 落盘),不单独做 action。

## 4. 每个 action 的搬迁范式(机械、可复制)

```
现在(LV 里,fullstack):
  def handle_event("save_soul", %{"soul" => content}, socket) do
    if socket.assigns.can_write? do            # ← 假门控(任何登录用户)
      ensure_dir_and_write(soul_path(tid), content)   # ← 直接写,无 cap,无审计,无 CLI
      {:noreply, assign(socket, soul_saved_flash: "已保存")}
    ...

re-route 后:
  # content plugin: behavior/content_admin.ex
  action :write_soul_slot, args: [...], caps: [content_write_cap(ws)]
  def handle_write_soul_slot(%{kind: :soul, content: c, tid: tid}, ctx) do
    ensure_dir_and_write(soul_path(tid), c)    # ← 逻辑原样搬来,dispatch 已过 CapBAC
    {:ok, %{}, []}
  end

  # liveview: tenant_admin_live.ex —— UI 变薄,只 dispatch + 反应
  def handle_event("save_soul", %{"soul" => content}, socket) do
    case dispatch(content_admin_uri(tid), :write_soul_slot,
                  %{kind: :soul, content: content}, ctx(socket)) do
      {:ok, _} -> {:noreply, assign(socket, soul_saved_flash: "已保存")}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, "无权限")}
    end
  end
```

要点:**数据写逻辑整段搬进 handler(几乎是 cut-paste);LV 只剩 dispatch + flash/assign**。cap 检查、CLI parity、审计自动来。

## 5. cap 模型(Allen 的口子在这里)

- **检查端**(已有,不动):每个 action `required_caps/0` 声明所需 cap(沿用现有 `write_soul_slot` 等的 `content:write` 形状)。dispatch step 5.5 自动 `holds_cap?`。
- **授予端**(等 `#88`/`#154`):admin 用户要**持有** `content:write`(scoped to workspace)cap,dispatch 才放行。**这步等 caps PR** —— 它正在改"怎么 grant / delegate"。落地后:在 `Roles.bundle(:tenant_admin, ws)` 里挂 `content:write` cap + 登录时授予,`can_write? = admin_uri != nil` 删除。
- **过渡**:caps 未到前,可先把 action 建好 + 测好(测试直接 mint cap),UI 暂不切;caps 一到,切 UI + 授 cap,一气呵成。

## 6. 异步(KB fetch/upload)

`fetch_kb_url`/`upload_kb_file` 当前在 LV 用 `Task.async`(#14)。dispatch 版:action 同步返回"已入队",实际 ingest 走 `{:effect, ...}` 或后台 job;LV 订阅完成事件刷新。**保留异步语义,只把"触发写"挪到 dispatch**。

## 7. 归属边界

- **操作 Operators(#18)** 改的是身份/cap(add/disable operator),**不是内容** → 应走 **`IdentityAdmin` Behavior**(已存在)而非 ContentAdmin。re-route 时分流过去。
- **CsOrchestrator / `#54` Role**:与 admin 写路径正交,**不在本计划**(单独问 Allen)。

## 8. 执行顺序(caps 一到即可跑)

- **Phase 0(现在就能做,不等 caps)**:把 ContentAdmin 缺的 11 个 action **建好 + 单测**(测试 mint cap)。逻辑从 LV cut-paste 进 handler。UI 不动,零破坏。
- **Phase 1(caps 落地后)**:`Roles.bundle(:tenant_admin)` 挂 `content:write` + 登录授予。
- **Phase 2(caps 落地后)**:UI 的 59 个写事件改 dispatch(薄化),删 `can_write? = admin_uri != nil`,删 LV 里搬走的逻辑。LV 大幅瘦身 → 过 Oversized。
- **Phase 3**:跑全量 E2E(soul/skill/kb/publish/takeover)证明不变;LvCliParity / 安全洞 / Oversized 自动绿。

## 9. 风险 + 缓解

- **逻辑搬迁引入 regression** → 每个 action 配单测 + Phase 3 E2E 守住契约。
- **caps API 变形** → 只影响 §5 授予端一步;检查端 + 搬迁逻辑不受影响。
- **佳哥并行改 admin UI** → 他请假;回来按本计划 + 评估 doc(#813)review,范围已公开。

---

**一句话**:Phase 0(建 action + 测,不依赖 caps)现在就能做;caps PR 一到,Phase 1-3 一气呵成,**E2E 不变、债结构性清零**。
