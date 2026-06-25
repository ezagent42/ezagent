你（codex）继续实施 ezagent **sub-task A 的 A2-A6**（A1 已合进 main）。工作目录 `/Users/h2oslabs/Workspace/esr-ng`。

## 第一步 — 加载 skill（你没有 Skill 工具，直接 `cat` 读完再动手）
- `.claude/skills/ezagent-developer/SKILL.md`
- `.claude/skills/elixir-phoenix-helper/SKILL.md`

## 读（以它们为准）
- `docs/together/2026-06-25/specs/A-plan.md`（A-plan rev2，A1-A6 的 files/idiom/risk —— **但 A4 见下方修正**）
- `docs/together/2026-06-25/specs/A-agent-flavor-config-unification.md`（spec + /goal）
- A1 已落地的 `Ezagent.Kind.Template.FlavorHook` + `Ezagent.Agent.FlavorTemplateHook`（你的起点）

## 工作模式（关键，和以往不同）
**不要做一个阶段 return 一个阶段。** 在**一个 target branch** 上把 A2-A6 全做完：
- 目标分支 `feat/agent-flavor-A2-A6`，off 当前 `main`（已含 A1）。
- A2/A3/A4/A5/A6 作为该分支上的连续提交（每个子任务自带 TDD + 测试，逻辑上是一个子 PR 的量，但都落到这一条 target branch，不单独开 PR-to-main）。
- **全部做完后，回报整条 target branch 的情况**（每个子任务做了什么、gates、A4 的 config_schema 落点、给 gaga 的 config_field 真实返回示例）。**由 lead（我）把整条 target branch 合进 main。**

## A2-A6 内容
- **A2** 移 flavor 集群（AgentFlavorRegistry/Resolver/Attributes）core→domain.agent：用 ReadyGate 式注册 hook 反转 `Plugin.publish` 的 registry 写入（`plugin.ex:469`，**让 core 不再引用 registry**）；domain.agent 新建 EtsOwner（最先启动）接管那两张 ETS 表；迁读者；加 arch gate `no_flavor_refs_in_core`=0。
- **A3** `Entity.Agent.behaviors/0` 从 registry 推导（base + 已注册 folded flavor instance_behaviors 并集）+ **必须先造 "flavor registry sealed" boot barrier**（cc 的 after_boot load_all 会在所有 flavor 注册完前就 spawn → 否则重演冷重启丢 behavior #110/#113/#114）+ 冷重启回归测试。
- **A4（修正！不按 rev2 的 D5）** = **`config_schema/0` 加在 `Kind.Template` behaviour 上（optional @callback）+ 各 flavor 的 Template Class（CcAgent/CodexAgent/CurlAgent）各自实现**，返回 `[config_field]`。**不要**放进 agent_flavor_decl。**config_field 契约（已与 gaga 定稿，照此实现）：**
  ```elixir
  @type config_field_type ::
          :string | :text | :integer | :boolean | :enum | :list | :json | :secret
  @type config_field :: %{
          required(:key) => String.t(),       # 配置键，如 "model"/"permission_mode"
          required(:type) => config_field_type(),
          required(:label) => String.t(),
          optional(:options) => [String.t()], # :enum/:list 可选值；可经 Application.get_env 运行时覆盖
          optional(:default) => term(),
          optional(:required) => boolean(),
          optional(:help) => String.t()
        }
  @callback config_schema() :: [config_field()]   # optional callback on Kind.Template
  ```
  各 flavor 的 schema 内容从它已有的 `template_data_extra/1`+`validate/1` 知识里取（cc: model/effort/permission_mode/tools；codex: approval_policy/sandbox；curl: provider/api_url 等）。**权威校验仍在各 Template Class 的 `validate/1`**——config_schema 只声明 UI shape，别复制校验逻辑。echo 等不实现即可（optional callback）。gaga console 经 `AgentFlavorRegistry.lookup(flavor).template_class.config_schema()` 消费——回报时给我每个 flavor 的真实 config_schema 返回示例。
- **A5** 去掉独立 `Ezagent.AgentConfig`，agent config CRUD 收拢进 domain.agent（保留 cap 门控）；迁移真实调用方：`world/agent_actions.ex:196/219/242` + `world/identity_data.ex:184` + `domain_identity/config_evolve.ex`；加 `domain_agent→domain_identity` dep（无环）。**和 gaga 的 console 对接**（它消费这个 + A4 的 config_schema）。
- **A6** 清 `AgentKind` 别名（`plugin_cc/application.ex` 用 `Entity.Agent`）。

## 纪律（硬门槛）
1. **独立 worktree**，绝不碰共享检出 `/Users/h2oslabs/Workspace/esr-ng`（切分支会污染别人）。
2. **最终 target branch 必须**：`precommit + check_invariants` 绿 + rebase 到当前 main；`no_flavor_refs_in_core` gate 通过；冷重启回归测试通过。每个子任务按四性质 DoD。
3. **arch_baseline_manifest.exs** 多任务共改 → 你内部串行；与 main 冲突时 rebase 重 ratchet（对齐实际值，别盖过新违规）。
4. **不自合 main** —— 回报整条 target branch，lead 合。
5. **澄清原则**：开工前一次性想清所有要澄清的问题（带默认假设）→ 自驱做到完成、过程不逐个停 → 完成回报时一并提澄清。

全部做完，把 target branch 名 + 每个子任务的 gates + A4 给 gaga 的 config_schema 真实示例，回报 lead。