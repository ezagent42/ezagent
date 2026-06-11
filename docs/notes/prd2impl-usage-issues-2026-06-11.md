# prd2impl 使用问题记录

> 日期: 2026-06-11
> 项目: AutoService v2 on ezagent
> 源文档: 设计文档 (1580 行) + 实施计划 (1060 行)

---

## 1. 入口选择困惑

**问题**: Entry A (`/prd-analyze`) 和 Entry B (`/ingest-docs`) 的区分不够直观。我们有手写的设计文档和实施计划，应该走 Entry B，但初次使用时不确定 `--tag` 参数的用法。

**建议**: 当用户已经有多个 MD 文件时，自动检测文件类型并提示走 Entry B，不需要用户自己判断。

---

## 2. skill-0 提取丢失关键内容

**问题**: 第一次 `/ingest-docs` 后，YAML 明显丢失了设计文档中的重要内容：
- 5 个 modules 只提取了 4 个（丢失 MOD-05 loom）
- 16 个 file_changes 只提取了 6 个
- 审查修正记录（30+ 项）全部丢失
- PR #715 发现（3 项）全部丢失
- 设计决策细节（sandbox 隔离、admin preview 等）全部丢失

**根因**: 用 Python 脚本手写 YAML 替代了 skill 内置的 extractor（lib/gap-extractor.md, lib/spec-extractor.md, lib/prd-extractor.md）。手动提取不可能达到 skill 的结构化解析精度。

**建议**: skill-0 的 extractor 需要更强的结构识别能力——当前依赖 heading pattern matching 和 section anchor detection，但对于 1500+ 行的设计文档，很多内容在非标准格式的段落中（如 ASCII 架构图、表格、代码块）。考虑增强 extractor 或提供"检查提取完整性"的步骤。

---

## 3. Pipeline 不自动链式触发

**问题**: `/ingest-docs` 完成后，没有提示用户运行 `/gap-scan` 和 `/task-gen`。用户需要自己知道 pipeline 的下一步。结果就是反复在 ingest 阶段修改 YAML，而没有推进到后续阶段。

**建议**: 每个 skill 完成后，显式输出"下一步: 运行 /xxx"。如果检测到依赖的 YAML 已存在，建议用户是否需要重新运行。

---

## 4. 设计变更后需要手动重跑全流程

**问题**: 设计文档经过团队审查后修改了 8 项，但 pipeline 不知道源文档变了。旧的 YAML 仍然存在，需要手动删除并重新 `/ingest-docs`。

**建议**: 支持增量更新或变更检测——比较源文档的 git hash 和 YAML 中的 source hash，发现不一致时提示用户重新摄取。

---

## 5. gap-scan 与 ingest 的 gap 重复

**问题**: `/gap-scan` 生成的 gap-analysis.yaml 覆盖了 `/ingest-docs` 生成的同名文件。两者的 gap 粒度不同：ingest 从 plan 提取任务级 gap，gap-scan 从代码库扫描生成模块级 gap。

**建议**: 明确两者的关系——gap-scan 应该是"补充"而非"覆盖"。合并逻辑：ingest 的 gap 作为 baseline，gap-scan 追加代码库验证结果（existing_code、coverage_pct 等）。

---

## 6. contract-check 在 greenfield 项目无意义但无提示

**问题**: autoservice 是全新项目（代码库 0%），`/contract-check` 发现 `docs/contracts/` 目录为空，直接输出"0 changes, 0 affected"。没有提示用户"greenfield 项目不需要 contract-check"。

**建议**: 在 greenfield 场景（coverage_pct = 0 且无 contracts/ 目录）自动跳过，不产生噪音输出。

---

## 7. superpowers 插件依赖不可达

**问题**: prd2impl 依赖 `superpowers:writing-plans` 做 per-task plan 生成，但超级插件在 marketplace 不可达、GitHub 需要认证、WSL 无代理。最终需要从宿主机的文件系统路径 `/mnt/c/Users/nity/.claude/plugins/cache/claude-plugins-official/superpowers/5.1.0/` 手动复制。

**建议**: prd2impl 的文档明确列出 superpowers 的安装路径（marketplace、git clone、手动复制），并在缺失时给出具体的安装指引，而不是静默降级。

---

## 8. writing-plans 逐个生成 16 个 task 效率低

**问题**: 有 16 个 tasks，每个都需要 writing-plans 生成 ~400 行的详细计划。手动逐个调用 skill 很慢，且 writing-plans 一次只能处理一个 task。

**建议**: writing-plans 支持批量模式——传入 tasks.yaml，自动为所有 task 生成计划。或者 prd2impl 的 skill-8 batch-dispatch 支持 plan 生成阶段。

---

## 9. 分支管理未纳入 pipeline

**问题**: Pipeline 没有分支管理环节。开始执行前应该确认分支、创建 worktree、设置 plans_dir。当前是手动操作，容易遗漏。

**建议**: skill-4 plan-schedule 或 skill-5 start-task 的第一步应该是分支确认/创建。考虑集成 `superpowers:using-git-worktrees`。

---

## 10. 缺少"检查设计文档完整性"的 step

**问题**: 在 `/ingest-docs` 和 `/task-gen` 之间，没有自动检查源文档是否完整、一致、无矛盾。我们通过手动审查发现了 30+ 项问题，但 pipeline 不会提示。

**建议**: 新增 skill-0.5 "design-check"——自动扫描设计文档的章节完整性、交叉引用一致性、术语一致性。

---

## 总结

| # | 严重度 | 问题 | 当前解决方式 |
|---|---|---|---|
| 1 | 中 | 入口选择 | 手动判断 Entry B |
| 2 | **高** | 提取丢失 | 手动补写 YAML |
| 3 | 中 | 不自动链式 | 手动运行下一步 |
| 4 | 中 | 变更检测 | 手动删除旧 YAML 重跑 |
| 5 | 低 | gap 覆盖 | 手动合并 |
| 6 | 低 | 无意义输出 | 忽略 |
| 7 | **高** | 插件不可达 | 宿主机文件系统复制 |
| 8 | 中 | 逐个生成慢 | 手动逐个调用 |
| 9 | 中 | 分支管理 | 手动 git checkout |
| 10 | 中 | 设计完整性 | 手动审查 |

**整体评价**: prd2impl 的核心流程（ingest→gap-scan→task-gen→plan-schedule→execute）是对的，但在**自动化程度、错误恢复、外部依赖**方面还不够成熟。对于 1500+ 行的设计文档，人工介入的比例依然很高。
