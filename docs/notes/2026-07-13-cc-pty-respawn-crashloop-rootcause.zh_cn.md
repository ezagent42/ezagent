# cc PTY 重生死循环 —— 根因(canary,2026-07-13)

**状态:** 根因已在 canary 上一字不差复现。修复落在本分支
(`fix/pty-crashloop-halt-and-continue-flag`);本文是证据记录。

**对象:** `entity://ezagent/agent/test-zyli-cc-1` 每 ~7s 重生一次 `claude` 子进程,
无休止(报告时 `.claude.json` 的 `numStartups` = 523)。

**结论先行 —— 交接单里的根因是错的,它开的药方等于没修。** 这个循环不是认证失败。
真凶是 `--continue`:**我们自己的重生路径**给它加上了这个 flag,而 agent 的 config home
里没有任何可恢复的对话,于是它每次必败。交接单要我把 halt 决策接上去的那个
auth-failure OBSERVER,**在这个场景里从来没有 fire 过**(933 次崩溃,命中 0 次)。

---

## 1. 症状

`EzagentDomainPty.Supervisor` 重启 PtyServer → `handle_continue(:spawn_pty)` 拉起一个新
`claude` → 子进程一秒内退出 → 循环。`RespawnBackoff` 正确地把节奏限制在 ~7s/圈(因此它
既没有触发 supervisor intensity、也没有拖垮兄弟 PtyServer —— 这部分完全按设计工作),
但**没有任何东西能让这个循环停下来**。

## 2. 证据 —— canary,2 小时日志窗口

容器 `ezagent-canary-ezagent-1`(镜像 `ezagent:canary`),`claude` **2.1.162**。

| 信号 | 2 小时内次数 |
|---|---|
| `PtyServer spawned claude … test-zyli-cc-1` | **933** |
| `child process exited … test-zyli-cc-1` | **933** |
| `respawn backoff … test-zyli-cc-1` | **933** |
| **`AUTH FAILURE signal … matched`** | **0** |
| `parked`(ParkedDialogWatch) | **0** |

每一圈的形状完全一致:

```
05:02:36.894  PtyServer spawned claude os_pid=31027
05:02:37.549  auto-prompt dev_channels_dialog matched — sending "1\r"    (开机后 655ms)
05:02:37.586  child process exited: {:exit_status, 256}                  (敲键后 37ms)
```

`exit_status 256` = `1 << 8` = 退出码 1。

从活进程抓到的真实命令行:

```
/usr/bin/claude --continue --dangerously-skip-permissions \
  --dangerously-load-development-channels server:esr-bridge \
  --settings /app/lib/ezagent_plugin_cc-0.1.0/priv/claude-pty-settings.json \
  --mcp-config /data/default/cc-agents/ezagent/test-zyli-cc-1/.mcp.json
```

## 3. 复现(对 config home 的隔离副本 —— 没碰生产目录)

把 agent 的 `CLAUDE_CONFIG_DIR` 复制到容器 `/tmp`,以下每一轮都跑在**副本**上。真实
config home、数据库、BEAM 节点全程零写入。

| 轮次 | 命令 | 结果 |
|---|---|---|
| **C** | 线上命令,可信 cwd,不敲键 | 停在 dev-channels 对话框,18s 仍活 |
| **D** | 线上命令**去掉 `--continue`** + `"1\r"` | **完整启动 TUI,22s 仍活 —— 不崩** |
| **E** | **一字不差的线上命令** + `"1\r"` | **exit 1**,屏幕:`No conversation found to continue` |
| **G** | **一字不差的线上命令 + 真实 cwd**(transcript 完全在作用域内) | **exit 1**,同样的报错 |

D 和 E 把病因锁死在**单个 flag** 上。

G 补上了最后的漏洞,而且它直接决定了修复方案的形状。这个 agent **确实**有一份 transcript
(`projects/-data-…-test-zyli-cc-1/5271f2db-….jsonl`,7799 字节,7 条记录,含一条 `user`
和一条 `assistant` 轮次,内部记录着 `"cwd": "/data/default/cc-agents/ezagent/test-zyli-cc-1"`)。
RUN G 就是用这个**真实 cwd** 跑的(所以 project key 和 transcript 内部记录的 cwd **都**对得上),
配合副本 `CLAUDE_CONFIG_DIR` —— 条件与生产完全一致。`claude --continue` **依然**报
`No conversation found to continue` 并 exit 1。

> 更早的 RUN F 把 transcript 放到了**另一个** project key 下,因此**不成立** —— 记录内部带着
> 原始 cwd,claude 是因为路径不匹配才拒绝的,理由不对。RUN G 取代它。此处保留记录,以免后人重蹈。

**这对修复方案的含义:磁盘上存在 transcript 文件,不代表 `--continue` 能成功。** 任何
「先查对话文件是否存在,再决定传不传 `--continue`」形式的修复,在这里都会照样传、照样崩。
而且**没有健康样本可以用来校准这个磁盘判据**(见 §7)。因此这道闸必须是**失败后回退**,
不能是**事前预测**。

## 4. 根因

### 缺陷 1 —— 重生路径上的 `--continue`(cc plugin)。这是循环的成因。

`apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex:31-37` 给每一次重生都加
`--continue`,依据是它自己的这段注释:

> "Verified empirically: on a first spawn with no prior conversation `--continue`
> degrades gracefully to a fresh session (**it does not error**), so it is safe on
> the respawn path even if the very first spawn had crashed before persisting a
> transcript."

**这句断言在 claude 2.1.162 上是假的。** 没有可续对话时,`--continue` 会打印
`No conversation found to continue` 并 exit 1。

结果是一个**自我维持的死锁**,而维持它的正是这个 flag:

```
claude 崩溃 → 没留下可恢复的对话
  → 重生时加上 --continue
  → "No conversation found to continue" → exit 1
  → 依然没留下可恢复的对话 → 无限重复
```

**重生路径本身保证了:一个失败过一次的子进程,永远不可能再成功。**

### 缺陷 2 —— 重生决策是无条件的(Domain.Pty)。这是它停不下来的原因。

`Ezagent.Domain.Pty.Server.handle_continue(:spawn_pty)` 永远是"退避一下,然后 spawn"。
系统里**不存在**"这个 agent 不该再被拉起来"这个概念,所以**任何**永久失败的子进程都会
无限循环。`RespawnBackoff` 只负责减速,它从来不负责终止。

### 不是根因 —— 缺失凭证(一个真实但独立的缺陷)

这个 agent 确实没有凭证:`.credentials.json` 不存在,容器里没有任何 `ANTHROPIC_*`,而
`claude -p "say OK" --settings <真实的 settings 文件>` 返回
`Not logged in · Please run /login`。

这是真的,而且会让 agent 永远**无法回话** —— 但它**造不成**这个崩溃循环。没有凭证时
claude 的 TUI 照样正常启动(轮次 D),只有在**试图说话**时才失败。交接单把两者混为一谈了:
它的复现命令 `claude -p 'hi'` **同时省掉了 `--settings` 和 `--continue`**,因此既错过了
真凶,又撞见了一个真实但无关的症状。

## 5. 为什么交接单开的药方修不好

交接单要求把 halt 决策接到已存在的 #17 PR-C auth-failure OBSERVER 上(「别新造检测 ——
它就是 halt 触发点」)。但这个 observer 是拿 PTY 输出去匹配
`[~r/Please run \/login/, "API Error: 403", ~r/API Error: 401/, ~r/Invalid API key/]`
(`cc_agent.ex:220`),而**这四个串在本故障里一个都没被打印过** —— 933 次崩溃命中 0 次,
轮次 C–F 也从未出现任何 auth 信号。把 halt 接到它上面的结果是:**单元测试全绿**(因为测试
自己模拟 observer 触发),**canary 依旧以 ~470 次/小时 的速度空转**。

## 6. 修复方案

有一个机械细节同时决定了两个修复的形状:**`DynamicSupervisor` 会把 child spec 冻结。**
`Ezagent.Domain.Pty.start/2` 交给 `DynamicSupervisor.start_child/2` 的是
`{Server, params}`,此后**每一次** supervisor 重启都用**同一份 params** 重跑
`Server.start_link/1`。也就是说,带 `--continue` 的 argv 是 cc plugin **只决定了一次**,
然后被 supervisor **原样重放** 933 次 —— **cc plugin 再也没有被问过第二次**。因此这个循环
**无法只从 cc 侧打断**,spawn 路径自己必须有"改主意"的能力。

1. **让 resume flag 自愈(`--continue` 绝不能有能力阻止启动)。** 因为可恢复性**无法从磁盘
   预测**(§3),所以由 cc plugin 同时给出**首选 argv**(带 `--continue`)和一份**降级备用
   argv**(不带);当首选命令活不到健康寿命时,PTY spawn 路径**用备用命令重试**。重启时丢掉
   对话上下文是一个回归,但**根本起不来是致命的** —— 这个回退用前者换掉后者。同时改掉
   `spawn_plan.ex:31-37` 那句被证伪的注释,它是这个 bug 的源头。
2. **让重生决策可被否决(Domain.Pty)。** 交接单的**结构直觉是对的**,错的只是触发器。
   改用**与根因无关**的 **crash-loop 熔断**:连续 K 次 spawn 都活不到健康寿命(且已无备用
   命令可试)→ 停止重生,把 agent 置于**持久化的终态 halt**并附带原因。`RespawnBackoff`
   **已经在数这个了**(`attempt_count/1`),把它从"减速"升级成"到点熔断"是个很小的改动。
   这个触发器能抓住**本 bug**(它根本不是 auth)、也能抓住 auth 的、OOM 的、对话框选错的。
   auth observer 和 `CredentialPrecondition` 可以作为**更快的**附加触发器叠上去,但不能是唯一的。
3. **给被 halt 的 agent 一条回来的路。** 见 §7 —— 目前**没有任何** operator 控件能重启一个
   agent,所以只 halt 不给恢复路径,等于把一个死胡同换成另一个死胡同。

## 7. 途中发现的其它缺口

* **canary 上 6 个 cc agent,没有一个有凭证。** `/data/default/cc-agents/ezagent/` 下全部
  6 个 config home 都没有 `.credentials.json`,容器里也没有任何 `ANTHROPIC_*`。这跟崩溃循环
  无关,但它意味着**本周「agent 真回话」的目标无论如何都卡在凭证发放上**,修完本 bug 也一样。
  同时它也意味着**没有任何健康 cc agent 可以用来校准"这个对话可恢复吗"的磁盘判据** ——
  进一步印证 §6.1「必须回退、不能预测」的结论。
* **系统里根本不存在 operator 的「停止 / 重启 agent」控件。** world UI 只暴露
  `agents.create` / `agents.delete` / `agents.config.*`
  (`apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex`);`mix ezagent` 只有
  `agent.create`。交接单假定人工恢复可以「复用现有 liveness/restart 控制」—— **那个控制
  不存在**,修复 (2) 必须把它补出来,否则一个被 halt 的 agent 没有任何回来的路。
* **`claude -p` 在未登录时退出码是 0**,所以任何靠退出码判断的检查都看不见 headless 凭证失败。
* `CredentialPrecondition.check_materialized/2` 对这个 agent 的磁盘形态**本来就会**返回
  `{:skip, {:config_home_without_credentials, flavor}}`,但它只接在自动物化链上
  (`session_creator/definition_agents.ex`)。**PTY 重生路径对凭证一无所知。**

## 8. 取证方式

对生产状态的访问全程只读。读:`docker ps`、`docker logs`、`ls`/`cat` config home、
`ps` 抓活进程命令行。复现轮次是对容器 `/tmp` 下 config home 的**副本**执行 `claude`
(事后已删除);生产 config home、数据库、运行中的 BEAM 节点**全程零写入**,未使用任何 RPC。
