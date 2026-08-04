# 会话范围内 Agent Admission 对账设计

**日期：** 2026-08-04

**状态：** 已确认

## 问题

用户在 PTY 中成功登录后，PTY 类型的 admission 仍可能一直停留在
`authenticating`。当前受监督的 admission sweeper 只会清理超时尝试，以及重新检查
已经加入会话的 Agent；它不会判断活跃的临时 Agent 是否已经完成认证。World 虽然
暴露了 `session.agent_admission.complete`，但对话客户端没有在 PTY admission 流程中
调用它。

因此，即使临时 Agent 已经持有有效凭据，会话角色仍然是空缺状态。用户随后点击
取消时，系统会清除 admission 与该候选 Agent 的关联。再次点击 `Connect Codex`
就会创建一个新的临时 Agent；它拥有新的独立凭据目录，所以会再次显示登录流程。

## 目标

临时 Agent 完成认证后，自动完成 PTY admission，同时保持同一个 Agent、会话本地
凭据隔离，以及对话界面中的显式恢复入口。

对账以 `session_uri` 为边界，只检查该会话拥有的活跃 admission 记录。它不会扫描
任意 Agent、凭据目录或其他会话中的候选 Agent。

## 不变式

1. 一个 admission 候选只属于一个会话和一个角色。
2. 对账操作接收 `session_uri`，只读取该会话 working copy 中的
   `agent_admissions`。
3. 在该会话内，可以检查全部 `authenticating` 或 `materializing` 候选；绝不检查
   其他会话的候选。
4. 认证成功后加入的是原临时 Agent，不能创建替代 Agent，也不能发布可复用的凭据源。
5. 凭据缺失或暂时无法读取属于等待状态，不是认证失败，不能清理候选。
6. 完成、取消和超时必须通过同一把 admission 锁串行化。
7. 取消或超时在清理前必须最后检查一次凭据。已经认证的候选应完成 admission，
   不能被销毁。
8. 重复对账和重复客户端操作必须具有幂等性。

## 考虑过的方案

### 1. 只增加显式完成按钮

增加“我已登录”操作来调用现有完成接口。实现简单，但完成流程仍依赖浏览器，用户
可能忘记额外操作，而且当前具有破坏性的认证失败路径会让过早点击变得不安全。

### 2. 只做自动对账

由后台检测凭据并完成 admission，不要求客户端操作。成功路径最短，但如果状态推送
延迟或终端暂时不可用，用户没有恢复入口。

### 3. 自动对账加会话范围内的恢复操作

采用此方案。后台负责完成 admission，对话界面为当前候选提供“继续登录”和
“检查连接状态”。这样正确性不依赖浏览器，同时用户可以确定地恢复登录或立即发起
一次检查。

## 架构

Session 领域继续负责 admission 状态转换。它提供一个以 `session_uri` 为输入的
会话范围对账操作，候选只来自该会话的持久 admission 记录。World 仍然只是传输和
投影层；React 不根据 PTY 输出推断认证状态，也不读取凭据文件。

现有受监督 admission 进程按会话调用对账。World 当前展示的会话也可以请求立即
对账。两条路径调用同一个领域操作，因此共享锁、授权上下文、凭据检查和幂等语义。

这不是全局凭据目录扫描。监督进程可以通过现有会话注册表发现会话，但每次调用都只
处理一个 `session_uri` 及其 admission 记录。

## 状态流程

对于会话内的每个活跃候选：

1. 获取会话 admission 锁，并重新读取当前记录。
2. 确认角色、attempt ID、临时 Agent URI、声明和模板版本仍然与会话 working copy
   一致。
3. 使用 admission 记录中冻结的 provider profile，读取该临时 Agent 的凭据状态。
4. 状态为 `authenticated` 时，进入 `materializing`，绑定声明的 recipe 和
   capabilities，把同一个 Agent 加入会话并持久化为 `joined`。
5. 状态为 `missing` 或 `unknown` 时，保持活跃记录不变，返回等待结果，不执行清理。
6. 出现终止性的 materialization 错误时，使用现有显式失败和补偿路径，并发布失败
   状态。

正常成功流程变为：

1. `Connect Codex` 创建一个临时 Agent 并打开它的 PTY。
2. 用户完成正常 Codex 登录。
3. 会话范围对账检测到凭据，并将同一个 Agent 加入会话。
4. 对话投影移除 admission 提示并显示已加入成员，不需要第二次点击 Connect。

## 取消和超时竞态

取消表示中止仍在等待的登录。在破坏性清理前，操作必须获取同一把 admission 锁，
并进行最后一次凭据检查：

- `authenticated`：完成 admission，由完成操作胜出，同一个 Agent 加入会话；
- `missing` 或 `unknown`：记录 `connection_cancelled`，并清理临时候选；
- attempt 已过期：返回现有 stale-attempt 结果，不影响更新的候选。

超时遵循相同规则。到达截止时间时，先在 admission 锁内检查凭据，再决定是否过期。
这样可以避免恰好在截止时间前写入的凭据被并发 sweeper 销毁。

## 对话体验

admission 仍然活跃时，对话卡片显示：

- “继续登录”：重新打开 admission 当前 `provisional_agent_uri` 的 PTY；
- “检查连接状态”：请求立即对账当前会话；
- “取消”：使用上述竞态安全的取消语义。

客户端不能为了重新打开活跃候选而调用 `begin`。`begin` 仍需保持幂等作为纵深防御，
但 PTY 恢复必须直接使用现有候选 URI。完成后，正常的会话状态发布会让成员显示出来。
如果实时更新丢失，重新构建或刷新对话投影仍然会读取持久化的 `joined` 状态。

## 错误处理

- 凭据 `missing` 和 `unknown` 是非破坏性的等待结果。
- 格式错误或不属于该会话的临时 URI 必须 fail closed，不能暴露 PTY 或加入 Agent。
- 过期的角色声明或 attempt 不能修改当前 admission。
- 对账失败日志包含 session URI、角色和 attempt ID，但不能记录 secret 或凭据内容。
- 一次临时 sweep 失败后，持久化活跃记录仍可由下一轮对账继续处理。
- 已加入 Agent 的现有凭据重新验证逻辑保持不变。

## 测试和验收

回归测试必须证明：

1. 对账会检查指定会话中的全部活跃候选，但不会检查其他会话的候选；
2. 凭据从 `missing` 变为 `authenticated` 后，原临时 Agent 会自动加入；
3. `missing` 和 `unknown` 会保留 attempt ID、临时 Agent URI、PTY 和活跃状态；
4. 认证完成后的取消会完成 admission，而不是清理候选；
5. 认证完成后的超时会完成 admission，而不是把候选标记为过期；
6. 仍未认证的候选在取消或超时后会正常清理；
7. 重复对账、取消、超时和完成之间的竞态不会创建第二个 Agent 或重复成员关系；
8. “继续登录”会打开原候选 PTY，不调用 `begin`；
9. “检查连接状态”只对账当前会话；
10. 自动完成会更新对话投影，无需第二次 Connect 就能显示已加入成员。

运行时验收使用一个全新的 Hello Codex 会话：只连接一次，在 PTY 中完成登录，返回
对话界面，观察同一个 Agent 加入，并确认不会再次显示登录流程。

## 与现有设计的关系

本设计修订 `2026-08-03-pty-credential-admission-bootstrap-design.md`：PTY admission
不再只能由用户显式完成，并新增活跃凭据检查。它保留
`2026-08-03-session-agent-credential-isolation-design.md` 的隔离不变式，以及
`2026-08-04-codex-admission-pty-view-design.md` 的 PTY 视图投影规则。
