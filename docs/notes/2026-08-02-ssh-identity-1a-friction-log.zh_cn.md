# 研发摩擦记录 — User SSH 身份 1a

> 日期：2026-08-02
> 来源：`feat/agent-ssh-credential` 分支（13 commit，3 个 task，11 次 review 派发，7 轮修复）
> 目的：**记录过程中撞到的框架 / 规约 / 环境问题**，供后续总结改进。不是设计文档，也不改变任何运行时语义。
> 证据规则：每条带 `file:line` 或实测命令输出；拿不到证据的标注为推断。

---

## 一、框架与 API：不直观、易踩的地方

### 1.1 `Task.async` 在 Lifecycle handler 里没有先例

本模块是**全仓唯一**在 `use Ezagent.Lifecycle` 模块里用 `Task.async` 的地方，没有既有模式可抄。三处不直观：

- `Task.async` 建立 **link**。直觉上"任务里抛异常会打挂 caller"——但 `Ezagent.Kind.Server` 设了 `Process.flag(:trap_exit, true)`（`apps/ezagent_actor/lib/ezagent/kind/server.ex:106`），handler 跑在其中（:939），所以异常会**变成消息**被 catch-all `handle_info`（:1233）吸收，`Task.yield` 优雅返回 `{:exit, reason}`。
  **本轮曾把错误机制写进代码注释并标为 "verified empirically"** —— 探针跑在非 trapping 的脚本进程里，结论不适用于生产。两道 review 分别从相反方向指出后才订正。
- **直接调 handler 的单元测试跑在非 trapping 的 ExUnit 进程里**，所以那里的语义与生产**不同**。这是为什么 `System.cmd` 的 rescue 必须放在 task 函数**内部**。
- 每次成功调用会在 Kind.Server 邮箱留一条 `{:EXIT, task_pid, :normal}`，落进 catch-all `handle_info` → 扇出到每个 behavior 的 `handle_kind_message/3` → 被 Lifecycle 默认的 `handle_signal → :ignore`（`lifecycle.ex:318`）吃掉。良性，但每次调用浪费一个邮箱轮次 + 一次 persist diff。本模块用选择性 receive 排掉了。

**改进建议**：若后续还有 Behavior 需要跑有界子进程，值得把这套（限时 + 排 EXIT + rescue 位置）提取成一个共用 helper，而不是每家重造。

### 1.2 缺少"短命子进程 + 限时 + 收集输出"原语

- `Ezagent.Runtime.OsProcess` 只有 `spawn/2`，是为**长命 sidecar / PTY** 设计的，无 run-and-collect。
- `System.cmd/3` **没有 timeout 参数**。
- `GitRunner` 因此自建了一整套（trapping GenServer + deadline + 输出上限，`apps/ezagent_domain_workspace/.../git_runner.ex`）。

于是每个需要"跑个命令拿结果"的地方都要在"裸 `System.cmd`（无限时）"和"抄 GitRunner 那一套"之间二选一。本模块选了 `System.cmd` + `Task` 限时。

### 1.3 `System.cmd/3` 对含 NUL 的 argv 静默截断

实测（Erlang/OTP 28 erts-16.2，Elixir 1.19.2）：

```elixir
System.cmd("echo", ["a" <> <<0>> <> "b"])  # => {"a\n", 0}
```

**不报错，静默截到 NUL 处。** 本轮最初以为它会抛 `ArgumentError`（一位 reviewer 也这么判断），实测推翻。后果是持久化的字段会与子进程实际收到的值分叉——属于"不要 silent 失败"要挡的一类，需在调用前自行校验。

### 1.4 手写 `required_caps/0` 会整体替换宏的自动派生

`apps/ezagent_actor/lib/ezagent/behavior/legacy_callbacks.ex:41-49` 的 `maybe_add_unless_defined/5`：只要模块定义了 `required_caps/0`，宏就**完全不注入**自动版本 —— **不是逐键合并**。

而自动派生（同文件 :62-86）会**丢弃 `kind:` 选项、硬编码 `:any`**。

**后果**：新增第五个 action 却忘了扩手写 map → 该 action 的结构性 `kind: :user` 钉子**静默消失**，verifier 走 fallback（`apps/ezagent_core/lib/ezagent/cap/verifier.ex:156-174`）合成 `kind: kind_type(kind_module)`。

**且 domain 层没有 gate catch 这个**（见 §2.3）。

### 1.5 真实 dispatch 测试证明不了生产注册

`Kind.BehaviorSet.resolve_action/3`（`apps/ezagent_actor/lib/ezagent/kind/behavior_set.ex:262-273`）在 `BehaviorRegistry` 未命中时会回落到 `per_instance_behavior/3` → `Kind.Introspection.behaviors_of/1` → `Kind.behaviors/0`。这是**有意的 RF-1 韧性设计**。

**后果**：删掉 `application.ex` 里的 `CapabilityRegistry.register(User, action, Behavior)` 整行，**经真实 dispatch 的测试照样绿**。只有直查 `CapabilityRegistry.lookup_subject/2` 才抓得住。

这一条极其反直觉——"我用了真实 dispatch，所以覆盖了注册"是错的。本轮的验收标准最初就是这么写的，实现者在动手前发现并绕开。

### 1.6 `Ezagent.Kind.read/2` 不做运行时 cap 检查

`apps/ezagent_actor/lib/ezagent/kind.ex:656` 返回扁平化 state，**无运行时授权**。敏感 slice 的保护完全依赖**静态 gate 的名单**（`apps/ezagent_core/test/invariants/sensitive_slice_read_test.exs`）。

**后果**：新增一个存明文密钥的 slice 却忘了加进那个名单 → 任何 `Kind.read/2` 消费者都能绕过为该数据设计的 cap 分离，而 gate 不报警。本轮的最终复审就是靠这条抓出了 M1。

**改进建议**：这个名单是"人记得加"型防护。若能从"slice 声明里标注 sensitive"派生，就不会漏。

### 1.7 dispatch 默认 deadline 与 Behavior 自身超时会耦合

`apps/ezagent_actor/lib/ezagent/invocation.ex:440`：`timeout = inv.ctx[:deadline_ms] || 5_000`，且超时是 `call_live_target/3` **重新抛出 EXIT**（:470-471），**不映射成错误元组**。

**后果**：Behavior 内部若也用 5000ms 保护性超时，调用方的期限**先起跑**（早于路由 + cap 校验 + handler），所以**先触发** → 调用方拿到 `** (exit) :timeout`，而不是 Behavior 承诺的 `{:error, _}`。

本轮把模块内超时降到 3000ms 并在 `invocation.ex` 加了 18 行注释记录这个耦合（纯注释，零行为变更）。

**改进建议**：任何带内部保护性超时的 Behavior 都要**严格小于**这个默认值，或自己设 `ctx[:deadline_ms]`。这一条目前只靠注释传达。

### 1.8 OTP 能解析 OpenSSH 私钥但不能编码

- **能**：`:ssh_file.decode(key, :openssh_key_v1)` → 成功解析 ed25519 私钥（这是 Git Provider Plan A 里"SSH parser 缺失"那条 NO-GO 被推翻的依据）。
- **不能**：试过 `{:ed_pub, :ed25519, pub}` / `{:ed_pri, :ed25519, pub, priv}` × `:openssh_key` / `:ssh2_pubkey` / `:openssh_key_v1` 六种组合**均失败**（不排除还有正确形状未试到）。

所以生成密钥要走 `ssh-keygen` 子进程。

**另一个约束**：`:ssh` **不在本 umbrella 的 release app graph 里**（各 `mix.exs` 无声明，根 `mix.exs` 的 `releases/0 applications:` 也没有）。所以即便只为"真解析私钥"而引入 `:ssh_file`，也等于扩大 release 的 OTP application graph —— 在无法验证 release 启动正确性时，本轮选择了不引入，保留前缀判定并在注释里如实记录该弱点。

---

## 二、规约与 gate：会咬人的地方

### 2.1 `set_effect_sites` 用源码正则计数 —— 注释里的文字会虚增

`apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex:458` 的正则 `\{:set,\s*:[a-z_]+,` 扫的是**源码行**，不区分代码与注释/docstring。

**本轮踩了两次**：在 moduledoc 和注释里描述 effect 时写成 `{:set, :some_key, value}` 形状 → 计数虚增 → ratchet 变红。

**规避**：注释里用文字描述（"写入 `:some_key`"），不要写元组形状。

### 2.2 `cap_signing_architecture_test.exs` 的 `private_key` 子串启发式会误报

`apps/ezagent_core/test/architecture/cap_signing_architecture_test.exs` 的守卫是 `String.contains?(source, "private_key")` + 路径豁免名单。任何**合法地**处理 SSH/其它私钥的文件都会命中。

GitHub App 的 JWT key 文件已在名单里，本轮又加了 SSH 模块（第二个）。真正护边界的另一半（`framework_signing?` 查 `Cap.Signing` / `Authority.sign(` / `Authority.verify(`）**不受影响**，所以豁免是窄的、路径键控的、改名会响亮失败。

**观察**：这是"子串启发式 + 豁免名单"型 gate。可接受，但每加一个豁免都要人工判断"这次是误报还是真问题"。

### 2.3 文档声称存在、实际不存在的 gate

`apps/ezagent_actor/lib/ezagent/behavior.ex:318` 的文档把 `Ezagent.Invariants.BehaviorRequiredCapsParityTest` 称为 core/domain 的 `required_caps` key-parity gate。

**该模块在整个仓库中不存在。**

实际情况：
- plugin compiler 有 key-parity 校验（`apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex:834`）
- 但 `apps/ezagent_domain_identity/mix.exs` **未安装该 compiler**
- umbrella 级的 `apps/ezagent_core/test/ezagent/behavior_required_caps_action_invariant_test.exs:22` 只校验**已有 entry 的 action 轴**，不查 key 完整性

所以 §1.4 那个静默失效在 domain 层**无人看守**。本模块只能手写测试自保。

**建议**：要么创建该 gate，要么订正 `behavior.ex:318` 的文档——现状会让人以为有保护。

### 2.4 `check_invariants.lifecycle` 在 main 上是红的

实测（2026-08-02，main `fe1fa6d0f` 之前的 `4edd3cfed`）：

```
✗ gate_no_engine_internals
  apps/ezagent_domain_session/lib/ezagent/behavior/template.ex:268
✗ NP-2 layer-vocabulary
  apps/ezagent_core/lib/ezagent/owner_gated_workspace.ex
  apps/ezagent_core/lib/ezagent/session/message_sequence.ex
```

而 `ezagent-developer` SKILL 把该 gate 描述为「**HARD-fails CI**」。**要么 CI 未运行它，要么 main 明知故红。** 两者都值得确认——因为它直接影响"新分支能否宣称 gate 全绿"。

### 2.5 CLAUDE.md 的 core LOC budget 已严重 stale

CLAUDE.md 写 `ezagent_core` target ~870 LOC、red line 1100。**实测 40454 行**。

这个数字曾被用来质疑"能不能往 core 加东西"，但它早已不适用。**建议删除或更新**，否则每次都要重新发现它是 stale 的。

### 2.6 `.superpowers/` 在 gitignore 里但有 7 个追踪文件

`git ls-files .superpowers/` → `task-1-report.md` + `task-4` … `task-8` + `task-a-report.md`。它们在 ignore 规则之前就提交了。

**本轮踩了**：让 subagent 把报告写到 `.superpowers/sdd/task-1-report.md`，**覆盖了 PR #1445 的取证记录**（+950/−185），由最终整支复审抓出，已还原。

**建议**：要么把这些文件迁到 `docs/notes/`，要么从索引里移除——"目录被 ignore 但里面有追踪文件"是个静默陷阱。

---

## 三、环境与工具链

| 问题 | 现象 / 绕法 |
|---|---|
| **Postgres 端口** | 本机监听 **15432**，`config/test.exs:63` 默认 55432。不设 `POSTGRES_PORT=15432` 则测试以连接超时失败（不是明确的"端口错"报错，容易误判） |
| **新建 worktree 无 deps** | 需 `MIX_DEPS_PATH=<根>/deps MIX_BUILD_PATH=<worktree>/_build`，否则 `mix test` 报一堆 "dependency is not available" |
| **`gh pr edit` 必失败** | 该仓库上 exit=1，原因是 GitHub 的 Projects(classic) GraphQL 弃用而 `gh` 的 `pr edit` 仍查 `projectCards`。绕法：`gh api repos/<owner>/<repo>/pulls/<n> -X PATCH -F body=@<file>`。`gh pr create` 不受影响 |
| **codex 子代理是纯转发器** | 只调一次 `task --background` 并返回 task id，**不能取结果**。结果要自己轮询 `~/.claude/plugins/data/codex-openai-codex/state/<worktree>/jobs/<id>.json` 的 `status` 字段 |
| **git fetch/push 偶发挂死** | 全程加 `timeout`，不要裸跑 |

---

## 四、方法论观察（跨 task，可复用）

### 4.1 两道独立 review 的关注面天然不重叠

本轮 6 条真缺陷，两个 reviewer **各占一半、零重叠**：

| 缺陷 | 谁抓到 |
|---|---|
| 私钥泄漏断言因 JSON 转义永不匹配 | A |
| 读测试 map 部分匹配、不约束 key 集合 | A |
| 模块超时与 dispatch 默认期限相等 | A |
| 覆盖了别人 PR 的追踪文件 | A |
| `Task.async` 的 link 语义 | B |
| **metadata-only 状态被降级为 `:absent`（Critical）** | B |
| `cap.behavior` 从不被断言 | B |
| 无-cap 拒绝只覆盖四分之一 action | B |
| 随分支交付了会误导下一个实现者的过期文档 | B |

分布特征：A 强在**单个 diff 内部**的断言强度与逻辑；B 强在**跨文件追语义**（追 `trap_exit`、追宏是否整体替换、追 snapshot 重载可达性、追 RF-1 回落）。

### 4.2 返工比首次实现贵

Task 1：实现 50 分钟，两轮修复 81 分钟。返工根因高度集中在**同一类**：**写的断言比要防的东西宽，坏实现照样过**（本轮出现四次）。

### 4.3 最有效的单条干预：三段式红色演示

要求实现者：**把实现按失败场景改坏 → 贴真实红色输出 → 逐字节还原并贴 `git diff` 空输出 → 重跑贴绿**。

只贴红不够——曾出现"红了但未证明还原干净"的证据缺口。

它的价值超出"防偷懒"：实现者据此**推翻了一条错误的因果断言**（补全 fixture 并不会让某测试变红，因为 revoke 无条件清全部字段）、**拒绝了一个考虑不周的建议**（`:ssh` 不在 release graph）、并**发现了验收标准本身的陷阱**（§1.5）。

### 4.4 plan 里的示例代码不是规范，spec 才是

本轮唯一的 Critical，根因是**实施计划里给的示例代码没有兑现同一份 spec 的定义**：spec 说"任一身份字段存在即 `unavailable`"，示例代码只查两个字段，实现者照抄。

**对策**（后续 task 已采用并当场见效）：派发时明确要求「**先把 brief 的断言与 spec 的定义逐条对照，发现落差先报告再实现**」。用了这条的那个 task 当场抓出两处（一处是 brief 里一条从不检查目标字段的假测试，一处是 §1.5 那个陷阱）。

### 4.5 gate 状态的表述纪律

本分支从未达到"所有 gate 全绿"，且每一条红都已归因到 main。

**正确表述是「本支无新增红」，不是「gate 全绿」。** 两道最终复审都要求逐字采纳这个措辞。用 stash/pop 与未改基线比对是确认"无新增红"的正确方法，但它**不支持**"gate 全绿"这个更强的说法。

---

## 五、建议的后续动作（均不在本分支范围）

1. **订正或创建** `Ezagent.Invariants.BehaviorRequiredCapsParityTest`（§2.3）—— 现状是文档承诺了不存在的保护
2. **确认** `check_invariants.lifecycle` 为何在 main 上红（§2.4）—— 是 CI 未跑，还是已知欠账
3. **清理** `.superpowers/` 的追踪文件（§2.6）—— 迁到 `docs/notes/` 或移出索引
4. **更新或删除** CLAUDE.md 的 core LOC budget（§2.5）
5. **考虑** 把"有界子进程"提取成共用 helper（§1.1 / §1.2）
6. **考虑** 让 sensitive-slice 名单从 slice 声明派生，而非人工维护（§1.6）
