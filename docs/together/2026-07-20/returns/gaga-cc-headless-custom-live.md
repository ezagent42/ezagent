# Return: cc-headless-custom live spawn — F2/F4 fixed, F3 decided+implemented, dual-backend live proof

> **Task:** 看板 gaga 卡验收 ②（cc-deepseek 泛化为可配置 cc-custom + deepseek/kimi 双后端实测）的收尾缺口 — issue **#1460**（#1449 接受的两项 deferral 之一）
> **Branch:** `fix/1460-cc-headless-custom-live`（off main `5f5c811d7`，rebase 后 6 commits；PR #1485）
> **Dev:** gaga Claude session
> **returned_at:** 2026-07-20
> **deadline:** 2026-07-20 EOD
> **deadline_status:** on_time
> **Rebase-base SHA:** `5f5c811d7`（batch #1483 后 rebased；首版基于 `fe2906431`，codex 评审 Minor 已修文档 SHA）

## What's done

| Commit | 内容 |
|---|---|
| `a06264157` | **F2 修复** — cascade 自调 `{:calling_self}`：`template.instantiate` 在模板 Kind 自己进程内运行，cascade 层解析却经 `UriQuery → Kind.get_slice` 自调。现在自引用层（layer_dir_for/source_dir_for）直接从手上 content 的 config_dir 供给（活数据，非快照），非自身源走原默认；guard 对自源短路。回归测试：测试进程注册为源模板 URI，修前复现生产同款 error tuple，修后通过。 |
| `969a02ff4` | **F4 修复** — `CcHeadlessAgent.ensure_config_home/2`：content 无 config_dir 时按 create 道同款补 per-agent 目标并分配（materialize 全程照跑：derived config / sandbox skills / plugin manifest / completion marker）。畸形 config_dir 不动，`{:invalid_config_dir}` 依旧 fail-loud。 |
| `440b38066` | **F3 决策落地**（issue 授权二选一：接纳 provider，catalog fail-closed 校验）— ①两个 custom 类 `config_schema` 加共享必填 `provider` 枚举（`Provider.provider_config_field/0`，options=ProviderCatalog.names()）；②`do_create_agent` 补 cc-custom/cc-headless-custom 子句走 file-flavor cascade 道（原来落到 direct-spawn fallback：不 instantiate → 僵尸 Kind 无 sidecar，空 flavor_config 甚至跳过校验）。 |
| `857d0a374` | 证据 + LOC：`agent_create.ex` 被 F3 子句推过 gt_1000 门（1018）→ `register_file_flavor_agent` 统一从 class_name 派生 tmpl_prefix（每调用点原本就是 class<>"."），落回恰好 1000；live proof 证据目录。 |
| （codex 评审修复） | **codex Major**:custom flavor 入 file-flavor 道后 `role_step.ex @file_flavors` 未跟上 → role 参数会过校验再被静默丢弃 → 两个 custom flavor 补进 `@file_flavors`（role 现在与 plain twins 同款 fail-loud `:role_unsupported_for_flavor`）+ 双 flavor 回归测试 + valid-provider 到达 `{:backend_api_key_missing}` 门的集成测试。**codex Minor**:本 return 的 SHA/base 更新为 rebase 后值（本行）。 |

## DoD reconciliation（issue #1460 §Acceptance）

| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | F2/F4 fixed so a cc_headless_custom.agent can be spawned live end-to-end | **met** | 单元/集成回归（cascade_activation 10/0、cc_headless_agent 24/0、plugin_cc 446/0、domain_workspace 221/0、domain_agent 165/1=main 基线同红）+ **live**：F2 道（含 config_dir）spawn + curated 层落盘（`curated-marker.txt` 入 agent home）；F4 道（无 config_dir）spawn + home 自动分配。`docs/e2e/2026-07-20/cc-headless-custom-live-proof/` |
| 2 | F3 decided: provider admitted (validated against ProviderCatalog) or ad-hoc lane declines | **met（admitted）** | config_schema 开键 + 模板 validate fail-closed；集成测试：bogus → `{:invalid_template_data, {:unknown_backend_profile,"bogus"}}`（两 flavor）、缺省 → `:missing_backend_profile`；live：world New Agent 表单出现必填 Backend profile 下拉并建成 sidecar agent |
| 3 | live headless proof transcript in docs/e2e/ | **met** | `docs/e2e/2026-07-20/cc-headless-custom-live-proof/`（README verdict 表 + server 摘要 + sidecar SDK 原始应答 + 8 张截图 + Playwright 驱动脚本；证据目录 grep 零密钥） |

**双后端实测明细（看板验收原文）**：deepseek `ds-pong` ×2、F3 道 `f3-pong`；kimi-coding `kc-pong`、sidecar 杀死后重生 `kc-pong-2`（`ensure_subprocess_alive` 现场 respawn）。kimi（开放平台）profile 依旧无有效 key（厂商 401，同 07-18 结论）——kimi-coding 订阅面是 kimi 后端的可用泳道，profile 值 07-18 已实证。

## 顺路抓到的大事（均已登记，不在本分支范围）

1. **#1482（新 issue，CRITICAL 级）— main 冷启动崩溃**：世界插件 after_boot `spawn_workspace("system")` 撞 `{:already_registered, "workspace://system"}`，**任何 populated DB 上的重启必崩**（空 DB 首启正常；2/2 复现 @ fe2906431）。附带毒掉所有 boot 全 app 的 mix 任务（如 `ezagent.user.token --mint`）。疑似 Loader 重跑与 world after_boot 竞速（或注册键形不一致：lookup 说没有、spawn 说已有）。**可能与 #189 主线不稳定相关，建议优先 triage。**
2. **CLI 布尔 parity 缺口（pre-existing，F5 同类）**：自动派生的 `mix ezagent workspace create_agent` 无法表达必填布尔 `--with-pty`（bare switch 吞掉下一个 token；`--with-pty=false` 以字符串 "false" 到 action 被 `is_boolean/1` 拒）。GUI 表单正常。记入 F5 所属的 CLI/GUI parity 账。
3. 07-17 F1（PtyServer crash dump 泄漏 cmd_env 含 ANTHROPIC_AUTH_TOKEN，#1455）本次未触发（headless 无 PTY crash dump；日志扫描 0 命中），但修复仍开着。

## 环境备忘（复现用）

- 隔离栈：`EZAGENT_HOME=/tmp/ez-hc-proof/home PORT=10101 POSTGRES_DB=ezagent_hc_proof` + 丢弃 signing seed/pepper + `EZAGENT_ADMIN_PASSWORD`（boot 的 `repair_admin_user` 即配好 admin 登录，**不需要 seed 脚本**）。
- 密钥：只 source `~/.ezagent/default/credentials/cc-custom.env`（CR 已剥）；本机 ambient ANTHROPIC_* 已 scrub。
- CLI token：因 #1482，`--mint` 全 app 启动会崩，改用 `mix run --no-start` 最小节点（postgrex+ecto_sql+EtsOwner+注册 6 scheme+Repo）mint。
- world SPA：本 worktree 需 `pnpm install && pnpm build`（xterm 依赖曾缺失）。
- 证明服务器已停（证据已全部落盘）。

## Method friction

- **`mix test apps/<app>`（app 根目录形式）静默跑 0 个测试**，必须 `apps/<app>/test`——这个坑已在 memory，但今天又咬了一次；建议把它写进 dev-together handoff-standard 的门禁节（method-delta ① 的自然延伸）。
- **formatter 对长调用行的展开不可预估**，LOC 预算在 985/1000 这种贴线文件上需要提前算 formatter 展开后的行数；这次 F3 子句三易其形才落回预算。贴线文件改动前先看 `wc -l` + 预算余量。
- Playwright 文本等待器容易误配自己刚发的消息（token 在 operator 气泡里已出现一次）；等"叶节点文本==token 精确匹配"才稳（脚本已按此写）。

## Merge request

PR 待开（`fix/1460-cc-headless-custom-live` → main），合入顺序与 #1445（gaga 另一 session 的 git provider 脊骨）无交叠（不同 app 面）。合入后即可关 #1460。#1482 建议独立于本 PR 尽快处理（它挡所有重启）。
