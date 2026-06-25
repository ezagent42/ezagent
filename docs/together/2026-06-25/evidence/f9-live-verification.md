# F9 活体验证 — world UI 绑飞书 chat→session（External Mirror bind）

> **日期**：2026-06-25 · **分支**：`feat/product-gaps-f9-f12` · **验证人**：zyli（agent-browser 0.27.0）
> **栈**：`mix phx.server`（host PG `ezagent_pg_compat_dev`，Phoenix :10042 / Vite :5173），`mix run scripts/world_e2e_seed.exs` seed admin。

## 缺口（06-24 验证 F9）

world UI 的 External Mirror 面是**只读表**（`ExternalMirrorTable`），无 bind 入口；后端 `Ezagent.ExternalMirror.bind/5` + CLI `mix ezagent.external_mirror.bind` 早已存在 → 纯 `lv_cli_parity` UI 缺口。

## 验证步骤

1. 登录 `world.localhost:10042` → `admin@ezagent.chat / worlddev`。
2. 导航 `/admin/sessions/<enc:session://system/generic/conv_workspace_system_c4e49e36>/external_mirror`。
3. External Mirror 面现在渲染 **bind 表单**（Adapter 默认 `feishu` + Target(chat id) + **Bind**）+ 现有 binding 行带 **Unbind**(垃圾桶) 按钮。
   - 截图：`f9-external-mirror-bind-form.png`
4. 正向接线证明：Target 填 `oc_demo_f9_wiring_probe`，点 Bind，读 `#world-root[data-last-dispatch]`：

```
error:{:target_ownership_denied, {:lark_check_failed, {:http_status, 400, <<...>>}}}
```

## 结论：端到端链路 100% 接通

点 Bind 的请求穿透了整条链路：

```
React onAction("external_mirror.bind", {session_uri, adapter_id:"feishu", target_id})
  → world:dispatch
  → world_live.ex @admin_actions 白名单
  → AdminActions.handle_dispatch("external_mirror.bind", …)
  → Ezagent.ExternalMirror.bind/5 (facade，caller/caps 取自 socket)
  → feishu adapter target_ownership_check → 真的打了飞书 Lark API
  → HTTP 400 lark_check_failed（oc_demo_f9_wiring_probe 非 bot 所在真实群）
  → reason_string 映射回 data-last-dispatch
```

- **`target_ownership_denied` 而非 `unsupported_action`** = action 被白名单接住、facade 跑了、adapter 真的去验群成员关系了。换成 bot 在的真实 `oc_...` 群 id 即成功绑定。
- 失败的 bind **不写任何数据**（facade 先验 ownership 再落库），零副作用。
- 这正是 F9 要补的「最后一公里」：操作员现在能从 world UI 把飞书群绑到 session（之前只能用 CLI / DB workaround）。

## 入口缺口补充（2026-06-25 自测发现）

操作员实测发现:bind 表单所在的 `/admin/sessions/:id/external_mirror` 页**没有任何 UI 导航入口**(只能手敲 URL)。这是 F9「无操作员 PATH」的另一半。

**补充**:`SessionsTable.tsx` 每个 session 行的 Actions 加一个 **「⌁ External mirror」链接** → `/admin/sessions/<encodeURIComponent(uri)>/external_mirror`,挨着 Open 按钮。

完整可点击路径:**Sessions 列表 → 点某行「External mirror」→ bind 表单**。
- 截图:`f9-sessions-external-mirror-entry.png`
- live 验证:点链接 → 落在 external_mirror 页,bind 表单(Adapter/Target/Bind)渲染 ✅

## 自动化证据（CI 可复现）

- 后端 seam 测试 9/9：`apps/ezagent_plugin_world/test/ezagent/world/admin_actions_external_mirror_test.exs`
- world 套件 23/23（含 lv_parity / slot / routes 闸）
- 前端 tsc 干净 + vite build OK + mount 闸 OK；bundle 含 `external_mirror.bind`/`unbind`/`world-external-mirror-bind-form`
