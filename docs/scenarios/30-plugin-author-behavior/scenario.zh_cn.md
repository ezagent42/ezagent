# 场景 30：插件作者 DX — 用 effects 写新 Behavior

**类别**：18 — 插件作者 DX（Router/Behavior/Kind 架构）
**状态**：⏳ partially-implemented
**最近验证**：从未作为绿地走查（Phase 1 PR #451 发布 LegacyAdapter；Phase 2 演练此场景）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Phase 1（PR #451）合并：`Ezagent.Behavior` 宏 + `action/3` 可用
- 开发者（插件作者）已克隆 umbrella，准备写新 plugin
- 插件作者技能已加载（`ezagent-developer`，按 `feedback_subagent_must_load_project_skills`）

## 角色

- **调用方**：插件作者（开发者）
- **目标**：
  - 新 Behavior 模块
  - `Ezagent.Behavior` action 宏
  - effects 词汇表（`:set` / `:emit` / `:dispatch` / `:notify` / `:effect` / `:effect_returning` / `:saga` / `:halt` / `:terminate`）

## 步骤

### 绿地 Behavior（Phase 2 后的预期工作流）

1. 创建 `apps/ezagent_plugin_widget/lib/ezagent/behavior/widget.ex`。
2. 写：
   ```elixir
   defmodule Ezagent.Behavior.Widget do
     use Ezagent.Behavior

     action :do_thing, caps: [{:any, :any, :do_thing, :any, :any}] do
       def handle(args, ctx) do
         {{:ok, %{processed: args.input}},
          [
            {:set, :last_input, args.input},
            {:emit, :widget_processed, %{input: args.input}}
          ]}
       end
     end
   end
   ```
3. 在 plugin 的 `Ezagent.Plugin` 声明注册 Behavior：
   ```elixir
   def behaviors, do: [{Ezagent.Entity.Session, :do_thing, Ezagent.Behavior.Widget}]
   ```
4. `mix compile` 跑编译期验证（按 SPEC 2026-05-22 plugin-authoring-contract）：
   - `plugin_info/0` 返回 well-formed map
   - 所有声明的 Behavior 实现契约
   - 无 `feishu://`-style 新顶层 scheme 尝试（allowlist 强制）
5. 启 phx；验证 Behavior 已注册。

### 派发 + 验证

6. iex：`Ezagent.Router.dispatch("session://system/sess_a", :do_thing, %{input: "hi"})`。
7. 验证：
   - Cap 检查通过（任何 session cap 或 admin）。
   - Handler 返回 `{:ok, %{processed: "hi"}}`。
   - Effect `{:set, :last_input, "hi"}` 更新 slice。
   - Effect `{:emit, :widget_processed, ...}` 写 EventLog。
   - Session 订阅者收到 `:widget_processed` 事件。

### LegacyAdapter 迁移（Phase 2 预期工作流）

8. 取一个现有 `Behavior.Chat.invoke/4` 调用点。
9. 经 `LegacyBehaviorAdapter` 包装：
   ```elixir
   {{:ok, result}, effects} = LegacyBehaviorAdapter.wrap(Behavior.Chat, :send, args, ctx)
   ```
10. 验证 adapter 产生同 Invocation shape + 结果匹配迁移前 baseline。
11. 把 `Behavior.Chat.invoke/4` 迁移到直接 `use Ezagent.Behavior` + `action :send`。
12. 比较前后：同派发 shape、同 effects、行为无变化。

### Saga 补偿（设想）

13. 声明多步 saga：
    ```elixir
    action :complex_thing, caps: [...] do
      def handle(args, ctx) do
        {{:ok, %{}},
         [
           {:saga, [
             {:dispatch, "agent://...", :step_a, %{}},
             {:dispatch, "agent://...", :step_b, %{}},
             {:dispatch, "agent://...", :step_c, %{}}
           ], compensate: [
             {:dispatch, "agent://...", :undo_a, %{}},
             {:dispatch, "agent://...", :undo_b, %{}}
           ]}
         ]}
      end
    end
    ```
14. 验证：三步全成 → 无补偿。step_b 失败 → undo_a 跑（补偿顺序是执行顺序的反序）。

## 预期结果

- 新 Behavior 编译 + 启动，**无需**触及 core、registry API 或任何其他 plugin。
- Effects 由框架按声明顺序应用；插件作者**永不**直接调 `EventLog.write/1`。
- 新 Behavior 的 plugin LOC ≤ 30 LOC（SPEC #445 目标）。
- 按 `feedback_north_star_plugin_isolation`，插件作者**零**核心知识接触。

## 失败模式

- 声明无匹配 cap 模式的 action：宏编译期错误。
- 返回未知 effect tuple：框架抛 `:unknown_effect`。
- Saga 步骤失败 + 补偿也失败：SagaRunner 标记 operator-repair（场景 24）。
- Behavior 返回畸形 `{result, effects}`：编译期 + 运行时 guard。

## 交叉引用

- 相关 PR：
  - PR #447 — EventLog + EventSubscriber
  - PR #448 — SnapshotStore + StateRebuilder
  - PR #449 — SagaRunner
  - PR #450 — Cmd、Router、Behavior 宏、Kind ext、LegacyAdapter
  - PR #451 — Phase 1 整合
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md` — REV 2 契约
  - `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` — 本场景的**治理性** SPEC
- 测试：
  - PR #450 子分支测试覆盖宏 + LegacyAdapter shape（`feat/p1a-core`）
  - 尚无绿地 Behavior E2E 测试（这是 Phase 2 PR-1 将落地的）

## 备注

- 这是 master README §6 优先级 1 — Phase 2 done-gate 是插件作者无核心知识写新 Behavior。可运行的绿地 E2E + golden file 是 gate。
- 按 `feedback_completion_requires_invariant_test`，"plugin-author-isolation" 不变式必须表达为 CI grep gate（按 SPEC #445 §11）："plugin 代码永不 import `Ezagent.EventLog`、`Ezagent.SnapshotStore` 等"。
- LegacyAdapter 迁移路径是允许 Phase 2 增量迁移 22 个 Behavior 而非大爆炸重写的桥梁。
