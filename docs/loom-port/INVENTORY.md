# loom → main 移植 · Phase 0 清单

> 分支:`loom-on-main`(off `origin/main` @ bb409ee6)。源参照:`loom-stitch`(worktree `/home/ning/ezagent`)。
> 策略:整包搬 `apps/ezagent_plugin_loom`(additive)+ 重新落 12 个共享钩子,按 main 规范写,PR 回 main。

## A. 功能清单(验收依据)

stitch 独有 = `apps/ezagent_plugin_loom/`(218 文件 / ~17k 行)+ 钩子。

- **Agent 团队**:orchestrator / builder(v0) / 主题 worker / salesperson 团队(主动答·辅助答) / worker管家(meta)
- **builder/LLM**:claude_code + deepseek 后端 + 切换;素材读取门 + 回合预算 + `error_max_turns` 重试
- **多页**:增删页 / `?page=` 路由 / 每页 salesperson 开关 / 每页 Live2D / 活动页同步
- **角色门控 v3**:`my-roles` 列全部符合角色 / 登录按钮 / 去 `?role=`
- **发布·衍生·谱系**:发布全套模板 / fork / 快照只读 / 从模板新建可编辑会话 / lineage 树(session scope)
- **回退**:按页 / 初始版本 / 当前标记 / 10 条/页
- **预览侧 AI**:Stitch / AiSpot(✨) / 弹幕 / Live2D(直连 DeepSeek)
- **接线员台**:按发布版本 cohort 列会话 / 跨会话发消息
- **临时用户升级**:登录后正式账号接管会话(OwnedSessions)
- **素材库 / 知识库**:上传 / 清单 / Read 注入
- **admin 改动**:Open Loom tab / 存为模板 / 右栏折叠 / 刷新含列表 / 切工作区异步不卡

## B. 钩子清单(共享文件改动,12 个)

| 文件 | 量 | 内容 | 难度 |
|---|---|---|---|
| `apps/ezagent_web/mix.exs` | +4 | loom 依赖 | 低 |
| `config/config.exs` / `config/runtime.exs` | +22 / +48 | 插件注册 + LLM backend | 低 |
| `apps/ezagent_web/lib/ezagent_web/router.ex` | +10 | forward `/loom` + signup | 低 |
| `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex` | +93 | `loom_signup` | 低 |
| `apps/ezagent_core/lib/ezagent/runtime.ex` | +14 | 小核心钩子 | 低 |
| `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex` | +12 | 小钩子 | 低 |
| `apps/ezagent_plugin_liveview/.../views/conversation_view.ex` | +33 | loom 消息渲染 | 低 |
| `apps/ezagent_domain_ui/lib/ezagent_domain_ui/workspace_shell.ex` | +41 | 右栏折叠 + loom view | 低-中 |
| `apps/ezagent_plugin_liveview/.../admin/session_editor.ex` | ~205 | Open Loom / refresh / 存模板 | 中 |
| **`apps/ezagent_plugin_liveview/.../admin_live.ex`** | **+609** | loom session view / 接线员 / 列表过滤 / refresh / 切工作区异步 | **高** |
| **`apps/ezagent_plugin_liveview/.../workspace_detail_live.ex`** | **+746** | Spawn-template / loom 模板展示 | **高** |

## C. 不兼容清单(三项,都有界)

**C1 — behavior 写法。** loom 有 **7 个 Behavior** 用 `use Ezagent.Behavior`;main 自己已用 `Ezagent.Lifecycle`(两个宏都在)。**待 Phase 1 首次编译验证**:loom 这 7 个能否原样编译,还是要迁 Lifecycle。界:≤7 个 behavior。

**C2 — CapBAC #154 ratchet(决策点)。** main 有 `no_unowned_system_principal_grant_test` + `system_principal/catalog.ex`。loom 在 30 处用 3 个系统主体:`system://session-internal`、`system://chat-reply`、`system://template-materialize`。门卡的是「铸造 grant_cap/revoke_cap 的主体」(category-B);loom 这 3 个多半纯执行(chat.send/join)→ category-A,只需 catalog 注册 + 分类。**默认按 category-A 执行主体处理,待 CapBAC owner 确认。** 界:3 个主体。

**C3 — admin_live 拆分(最硬单文件)。** main `admin/` 拆成 10 模块(compose / invite / rehydrate_flash / routing_rules / session_context / orchestrator_restart / event_format / member_panel / session_editor / session_external_mirror_live);stitch 只 3 个。loom 钩子(+609)要拆着落进对应子模块。`workspace_detail_live`(+746)同理但稍轻。

## 工作顺序
Phase 1(搬 loom + 接线 + 首编译定 C1)→ C2(catalog 注册分类)→ Phase 2 钩子(低风险先,admin_live/workspace_detail 最后)→ Phase 3 验收 → Phase 4 PR。

## 待 owner 拍板
- C2:loom 3 个系统主体在 main 的分类(默认 category-A 执行主体 + catalog 注册)。
