# 场景 21：Template 版本 tag + 实例化

**类别**：9 — Template + 版本 tag
**状态**：⏳ partially-implemented
**最近验证**：从未（版本 tag 特性尚不存在）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已登录
- `workspace://system` 中存在 cc.agent 模板

## 角色

- **调用方**：admin
- **目标**：模板 `template://system/my-cc-agent`

## 步骤（设想 — 尚未接线）

### Tag

1. 在 `/admin/templates/my-cc-agent` 点 "Tag version"；提供 tag `v1.0.0` + 描述。
2. 系统把模板当前内容快照到 `template_versions` 表。

### 从 tag 实例化

3. 在 `/admin/workspaces/system` 点 "Create agent from template"；选模板 `my-cc-agent`，版本 `v1.0.0`。
4. 验证 spawn 的 agent 配置匹配 v1.0.0 快照，**非**当前模板内容。

### 更新 + 回滚

5. 编辑模板（改 `working_directory`）；保存。
6. Spawn 新 agent：使用**当前**模板（非 v1.0.0）。
7. 标新版本 `v1.1.0`。
8. 再从 `v1.0.0`（tag）spawn 一个 agent；验证用旧配置。
9. 点 "Rollback to v1.0.0"；验证当前模板现匹配 v1.0.0。

## 预期结果（设想）

- `template_versions` 表 per tag 一行。
- 带 `version:` arg 的 spawn 用 tag 内容。
- 无 `version:` 的 spawn 用当前（最新）内容。
- 回滚非破坏：之前的 "当前" 成为新 tag（或在本例保留为 v1.1.0）。

## 失败模式（设想）

- 重名 tag：`:already_exists`。
- 从已删除 tag spawn：`:version_not_found`。
- 回滚到不存在的 tag：`:version_not_found`。

## 交叉引用

- 相关 PR：无 — 版本 tag 特性尚未发布。
- 相关 SPEC：尚无。
- 测试：
  - `apps/ezagent_domain_workspace/test/integration/add_template_invokes_test.exs`（当前模板 CRUD）
  - `apps/ezagent_domain_workspace/test/integration/update_agent_template_reconciler_test.exs`（当前更新路径）
- Open bug / gap：
  - **版本 tag 作为特性不存在**。最接近的：`AgentFlavorRegistry` template_class 注册，是编译期、非运行时版本化。
  - **无版本 tag 的 SPEC**。需定义：存储 shape、tag 名约束、实例化时解析、回滚语义。

## 备注

- 这是类别 9 主要 gap。阻塞 Phase 3（带受控模板升级的生产部署）。
- 按 `feedback_dont_defer_what_is_solvable_now`，Phase 2 Behavior 迁移稳定后 SPEC + 最小实现可在 1-2 个 PR 落地。
- 标 ⏳ 而非 ❌ 因底层模板 CRUD 工作；只是缺版本维度。
