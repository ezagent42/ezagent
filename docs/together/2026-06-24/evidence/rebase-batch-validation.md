# Rebase-batch validation — origin/main @ c2971d9c (本批 4 PR)

> 2026-06-24 下午 · `zyli-fullflow-validation-0624` rebased 到 `c2971d9c`(含 #939/#937/#931/#938 + #940 logo)
> 环境:deps.get + pnpm install(pnpm@9,Node20 兼容)+ dev/test migrate(protocol_api_keys/email_thread_state/email_inbound_binding 三表确认存在)+ server 活跑 :10042。

## #939 Bug A — 会话创建(快照竞态修复 + no_such_actor 可观测)— ✅ PASS

### 正路(不再 5s 竞态)
建 3 个 session(`bug-`/`bug-1`/`bug-2`),每个:
```
session.create → granted → snapshot.written (version 0, 创建即落地)
chat.send → session.send granted + snapshot.written
```
**无 no_such_actor、无 5s timeout、无崩溃**,连续 3 个全绿。06-23「create 撞 5s 预算→快照没落→send no_such_actor」现象消失。
(无 agent 自动回复=default 模板无 agent + 无路由规则 F12,与 Bug A 无关。)

### 负路(新可观测性)
开不存在的 `session://system/default/ghost-xyz-999` + composer 发消息 →
```
[error] Ezagent.Invocation: fire-and-forget cast dispatch FAILED before delivery
        target=…/ghost-xyz-999?action=session.send reason=:no_such_actor
[debug] World.self_join: … could not join …ghost-xyz-999: :no_such_actor (observe-only)
```
UI fail-closed(发不出、不显示),失败**服务端日志可见**(06-23 静默吞)。3 次发送均触发。✅

## #937 Bug B — 插件 resource type 重启自愈 — ✅ PASS
- world UI 重启后持续正常使用(Overview Layout / Identities / 会话面板 / Bug A 全程)= `world-layouts` resource 解析正常(重启后 resource type 未丢)。
- **uploads 解析**:bug-1 上传 image/png →
  ```
  POST /world/uploads (email.png) → 消息 attachments:[resource://system/uploads/777ee5e2-…-email.png]
  GET /uploads/download → 取回成功
  ```
  resource:// 上传链路解析正常。「Registry 重启重放」单测覆盖(#937)。

## 🎉 BONUS — world UI @提及 → agent 回复(L4 核心,06-23 阻塞)— ✅ 现在通
admin 在 bug-1 发 `@test-echo-1 你好`:
```
消息 mentions:[entity://system/agent/test-echo-1]   (@ 解析为 agent URI,非空)
test-echo-1 回复 "echo: @test-echo-1 你好" (ref_id=原消息)
```
**操作员 world UI @提及 agent → agent 真回复**。修正认知:F12(@提及未路由)是**飞书 adapter 特有**(feishu @ 未映射到 session agent),**核心 mention 路由正常**。

## #931 cc-headless — ⛔ 创建失败(F15,创建阻塞 bug)
建 cc-headless agent(flavor=cc-headless, cwd=/tmp/cc-headless-test, with_pty)→
```
[error] Behavior Ezagent.Behavior.Workspace.handle_create_agent/2 crashed:
  %RuntimeError{message: "config-dir resolution failed for
  resource://system/cc-headless-agents/test-ccheadless-1: :none"}
```
根因:cc-headless template/flavor 已注册(plugin_cc/application.ex:96/112),但其 **config-dir FsResolver resource type `cc-headless-agents` 未注册**(`config_dir_namespace="cc-headless"` → 派生 `cc-headless-agents`,resolver 对未注册 type 返回 `:none`)。普通 cc 用 `cc-agents`/`Home.path` 可解析,cc-headless 这条没在 Registry boot_registrations/register_all 声明。→ **cc-headless agent 无法创建**(送消息/回复无从测起)。环境:已装 claude-agent-sdk(uv 缓存)+ ANTHROPIC_BASE_URL=deepseek/anthropic 重启,均未走到。
**Owner: @黄佳佳(#931)。** 严重度:**high**(新 flavor 完全不可用)。fix 分支:`fix/cc-headless-config-dir-resource-type-unregistered`。

## flavor 路由(顺带)
echo/curl 已验回复(L5/bonus);cc=F5、codex=F7、cc-headless=F15 —— 四旧 flavor 路由各自独立,无误路由迹象(各自失败原因不同、互不串)。

## #938 agent-config 后端 — ✅ PASS(IEx/mix-run 冒烟,全新 team_alpha agent)
```
read_cascade(初)           → {:ok, cascade}
apply_delta create         → effective %{"tone"=>"decisive"}         (写 patch ✅)
apply_delta merge(soul_md) → {:ok}                                   (浅合并 ✅)
delete_path ["tone"]       → effective %{"soul_md"=>"# Soul"}        (版本化删除 ✅)
apply_delta A/B + repoint→first → effective %{"soul_md"=>..,"tone"=>"A"} (回滚 ✅)
apply_delta(stranger, 空caps)   → {:error, :unauthorized}            (无 cap 拒绝 ✅)
apply_delta(他 agent manage-cap)→ {:error, :unauthorized}            (跨 agent 拒绝 ✅)
```
read cascade / 写 patch / 版本化删除 / 回滚 / 跨-agent cap 门 全部正确。end-to-end UI 待戴明 #84 console 接线。

## 本批总结
| PR | 结果 |
|---|---|
| #939 Bug A 会话创建 | ✅ PASS(正路无竞态 + 负路 no_such_actor 可观测)|
| #937 Bug B resource type 重启自愈 | ✅ PASS(uploads + 布局)|
| #931 cc-headless | ⛔ F15 创建阻塞(resource type 未注册)→ @黄佳佳 |
| #938 agent-config 后端 | ✅ PASS(冒烟 4 API + 2 拒绝)|
| bonus | world UI @提及→agent 回复 work(06-23 L4 核心已修)|

## Round-3 — 剩余 UI 面验证 + 与早前截图对比(无回归)
A 组(无旧截图,验渲染):
- **Workspaces** ✅ 列表渲染(4 ws;`system` 9 templates=印证 F19/F22 累积无删)
- **Plugins** ✅ 11 插件卡(含 Hello=印证 F24)
- **Admin** ✅ Dashboard 统计 + **CC orchestrator: ok**(系统 orchestrator 健康 → F5 排查线索:绑用户 create 路径/sandbox,非 claude 本身)
- **Command(cmdk)** ✅ 搜索面板 + Admin(Observability/Registry/Routing/Settings/Snapshots)/Navigate 命令
- 后端日志:`GET /workspaces /plugins /admin` + `cmdk.open/close` 全成功,无报错/崩溃。

B 组(对比早前 L1c/agent-list/agent-detail/customer 外壳):world UI 外壳(左导航 + 顶栏 + 卡片/表格/主题)与早前**完全一致 → rebase `c2971d9c` + 清理无渲染回归**;唯 agent 列表数据 churn(清理+boot 重建,预期内,非回归)。

证据:`workspace.png` / `plugins-list.png` / `admin-list.png` / `command-list.png`。**A/B 均为验证 PASS,无新 finding。**
