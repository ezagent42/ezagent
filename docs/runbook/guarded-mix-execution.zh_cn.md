# 受控 Mix/BEAM 执行 runbook

## 1. X 问题——一次调用是有主有界作业

根本问题是把 Mix/BEAM 调用当成一个已经启动的命令。它应是有主有界作业：
一个串行进程树、一套资源边界、一个期限、一个 partition、清理证据，以及保留
原始退出状态的结果。

## 2. 本 runbook 关闭的 Y 问题

本契约关闭裸跑或重叠 Mix、缺少 cgroup/scheduler 限制、无界等待、partition
冲突、资源证据缺失、含糊的 agent 断连和未检查的孤儿进程。它不自行诊断产品
失败，也不杀死非本作业启动的进程。

## 3. 强制使用场景

本地 test、compile、migration verification 和 precommit 必须使用 guarded
runner。dev-together handoff 需要 Mix/BEAM 时也必须使用。机械或非 Mix handoff
只有给出理由才能标记资源边界不适用。让所有既有 CI 调用都经过 runner 不在
第一阶段采用范围内。

## 4. 标准命令

从 umbrella 根目录运行：

```bash
scripts/guarded_mix.sh \
  --timeout 900 \
  --partition provider_full \
  test apps/ezagent_domain_provider_connection/test
```

实际有界命令必须包含这些字面设置：

```text
MemoryHigh=4G MemoryMax=5G MemorySwapMax=0 MemoryAccounting=yes OOMPolicy=kill
ERL_FLAGS='+S 4:4' MIX_ENV=test
```

runner option 后传入 Mix 参数。runner 把它们保留为 argv，绝不求值命令字符串。

## 5. 资源边界默认值

| 设置 | 值 |
|---|---|
| Lock | `/tmp/ezagent-mix.lock` |
| MemoryHigh | `4G` |
| MemoryMax | `5G` |
| MemorySwapMax | `0` |
| MemoryAccounting | `yes` |
| OOMPolicy | `kill` |
| ERL_FLAGS | `+S 4:4` |
| MIX_ENV | `test` |

这些设置组成一个契约，不得选择性省略。

## 6. Partition 和 timeout 选择

每次运行都使用包含工作或 Closure 名称的唯一、可描述 partition，例如
`provider_full`；可能并发的作业不得复用。根据既有证据选择最小合理超时，
并记录在 handoff 中。默认值为 900 秒。延长超时必须给出理由，且不授权扩大
内存边界。

## 7. 运行前检查

1. 确认从 umbrella 根目录运行，并记录目标 Git SHA 和 working tree。
2. 确认 `flock`、`systemd-run`、`timeout`、`mix`、可执行的
   `/usr/bin/time` 均存在，且 user systemd manager 可用。
3. 检查匹配的 Mix/BEAM 进程并记录已存在项；不得只因匹配就杀死进程。
4. 确认不应有其他自有作业占用 `/tmp/ezagent-mix.lock`，并选择唯一 partition。
5. 记录 timeout、精确 Mix argv、资源边界、数据库/fixture 准备和预期证明。

缺少前置条件属于 setup failure，不得回退到裸跑 Mix。

## 8. 必需的结果证据

保留开始/结束时间、Git SHA、精确 argv、partition、timeout、子进程退出码、
耗时、Max RSS、swap、结果分类和运行后的匹配进程报告。即使后续运行通过，
也要保留第一次失败输出和 stderr。测试需记录 suite/file 和计数；compile、
migration 或 precommit 需记录具名门禁及其退出结果。

## 9. 运行后孤儿检查

每次退出后报告匹配的 Mix/BEAM 进程，并与运行前记录比较。不得使用宽泛 kill，
不得杀死无关进程。如果自有 systemd scope 仍存在，先捕获其状态和进程树，
再只停止该 scope。检查未记录或锁未释放时，运行不算完成。

## 10. OOM 和 timeout 取证

超时时保留退出码 `124`、scope 状态、子进程树、资源摘要、末尾 stdout/stderr
和请求的 timeout。遇到 `137` 等信号退出，只记录作业被杀；没有 cgroup 或
kernel 证据不得称为已证 OOM。清理前捕获 cgroup memory event、systemd scope
属性以及可用 kernel/journal 消息，并记录 Max RSS 和 swap。agent 断连本身是
基础设施证据，不是 OOM 诊断。

## 11. 失败分类

把已记录结果准确分类为以下一类，或保留为未解决：

- **product（产品）：** 可复现行为违反产品契约。
- **fixture/model（夹具/模型）：** DB、runtime、fixture 或测试假设不一致。
- **resource（资源）：** 有界作业触及已证的资源或期限边界。
- **infrastructure（基础设施）：** 前置依赖、user systemd、数据库、传输、
  host 或 agent 连接使有效运行无法完成。
- **non-reproduced concurrency pollution（未复现并发污染）：** 已记录失败在
  隔离受控条件下未复现，且没有证据归入其他类别。

后续证据可以重新分类，但不得删除原始记录。重跑到绿色不能抹除已记录的
full-suite 失败。

## 12. 禁止做法

- 禁止并行、重叠或裸跑本地 Mix/BEAM。
- 禁止裸跑 `mix precommit`。
- 锁、user systemd、timeout 或 accounting 不可用时禁止回退。
- 可能重叠的作业禁止共享 test partition。
- 禁止宽泛 kill、workspace 清理、提高 baseline、添加 `arch-allow` 或削弱门禁
  来获得绿色输出。
- 禁止把反复重跑当成先前失败没有发生的证明。
- 禁止仅凭退出码 `137`、agent 断连或 VmmemWSL 增长就声称 OOM 已证或创建
  进程已识别。

## 13. 修改资源边界

不得临时修改上限。契约变更提案必须包含 workload、受控测量、理由、风险、
owner、临时/永久决定，并同步更新 runner、两份 runbook、测试、工作流模板和
CI 契约。按方法变更评审。合入前使用标准边界或报告 workload 被阻塞；不得
静默提高 baseline 或绕过 guard。
