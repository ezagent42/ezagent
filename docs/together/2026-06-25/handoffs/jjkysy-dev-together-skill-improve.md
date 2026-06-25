# Handoff — dev-together skill 改进（jjkysy / 姚升悦，**owner**）

> **任务**: 分析当前 review/plan，完善 dev-together skill 并提交改进 PR，从根上提升分析/规划质量。
> **分支**: `chore/dev-together-skill-improve`（off `main`，保持 rebase）
> **协助**: `ruihuachen-designer`（陈瑞华）出可外发版式设计，你落进 skill；**你是 skill 的单一写者**。

## 背景
昨天的 review 第一版"过于粗糙"。问题暴露出 dev-together 的 review/plan 产出质量不稳定：分析没强制走系统功能层面、没强制按人完成 + 待办、没区分"内部讨论"与"可外发"、plan 没强制声明 off-plan 预算。需要把这些固化进 skill 模版/命令，而不是靠每次临场发挥。

## 要做什么
1. **分析当前 review/plan**：看 `docs/together/2026-06-24/`（review.zh_cn.md 外发版 / 内部底稿 cycle-*.md）+ `2026-06-25/plan.md`，归纳"好版式"与"坏版式"的差异。
2. **改进 dev-together skill**（`.claude/skills/dev-together/`）：
   - `commands/review.md`：强制**系统功能层面分析** + **按人完成情况** + **待处理事项**；强制产出**可外发版本**（去内部讨论过程）+ 内部底稿分离。
   - `commands/plan.md`：强制**off-plan/越界预算声明**；用**完整 github 名**；中文可外发。
   - `references/`：加一个 review/plan 的**标准版式模版**（吸收 `ruihuachen-designer` 的设计）。
   - **修正 clarify 原则（@林懿伦 2026-06-25 拍板）**：把"遇未知就停下问、别猜"改成 —— **快速迭代下：开工前一次性想清所有可能要澄清的问题（一起问/带明确默认假设）→ 过程中自驱做到完成、不逐个停问 → 完成后回头澄清是否要改**；只有"猜错会推翻整个方案"才中途停。改进 SKILL.md / handoff / return 命令里所有 clarify-first 措辞，使其符合这个"front-load → self-drive → post-clarify"模型（与 wake-but-don't-stop 一致）。
3. 通过 `scripts/validate_skill.sh`。

## DoD（四性质）
- [ ] review.md / plan.md 命令强制：系统功能层面 + 按人完成 + 待办 + 可外发/内部分离 + off-plan 预算 + 完整 github 名。
- [ ] 新增**可外发版式模版**（references/），`ruihuachen-designer` 的设计已吸收。
- [ ] **验证**：`bash .claude/skills/dev-together/scripts/validate_skill.sh` 通过；并用模版**重跑一遍 2026-06-24 的 review** 作为"好版式"样例，证明新模版产出比旧版好（对照）。
- [ ] **CI 绿** + rebase 到当前 main（纯 docs/skill，CI 会绿）。

## 关键文件
- `.claude/skills/dev-together/commands/{review,plan}.md`
- `.claude/skills/dev-together/references/`（新模版）
- `.claude/skills/dev-together/scripts/validate_skill.sh`（验证）
- 参考输入：`docs/together/2026-06-24/review.zh_cn.md`（外发样例）、`2026-06-25/plan.md`

## 必读
- dev-together skill（SKILL.md + 它最近一次大改：四性质 DoD / clarify 前相 / 机器 return 闸 / method-writeback）
- `ruihuachen-designer` 的版式设计稿（协作输入）

## 注意
- 你是 skill 单一写者；`ruihuachen-designer` 出设计、不直接改 skill 文件，避免冲突。
- 这条本身就是"用 dev-together 改 dev-together" —— 按新流程走（自测绿、rebase、DoD 逐条）。
