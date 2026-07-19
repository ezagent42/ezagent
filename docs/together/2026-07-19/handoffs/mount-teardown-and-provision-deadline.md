# 挂载宿主退场清理 + 冷建 provisioning deadline(通用 infra 两件)

> 面向不了解本线上下文的读者。两件事都是**通用平台问题**,零业务字面,
> 从业务分支上剥出来单独提。

## 件一:宿主退场时,名下挂载没人清 → 悬空钥匙 + 悬空挂载行

### 现象

平台里有一类「数据宿主 agent」:别的 agent / 人通过 **mount**(挂载)拿到指向它的
钥匙(capability)+ 一条挂载表行(`socialware_mounts`,durable SoT)。宿主被删除
或退休时,之前只有「按自然键逐个 unmount」的入口——没有「把这个宿主名下**全部**
挂载一次清光」的入口。结果:删宿主的业务路径要么自己手搓循环,要么漏清,留下:

- grantee 手里指向已死宿主的钥匙(悬空 cap);
- 挂载表里指向已死宿主的行(悬空 SoT,reconcile 时还会试图对死宿主重发钥匙,刷警告)。

任何 socialware 只要删数据宿主(不止某一个业务),都会撞这个坑。

### 方案

- `Ezagent.Socialware.MountRow.list_for_target/1` —— 按 target 的反向索引:
  指向该宿主的**所有**挂载行(跨 session、跨 grantee、session 行 + person 行都算),
  oldest first。
- `Ezagent.Socialware.Mount.unmount_all_for_target/1` —— 逐行卸载(撤钥匙 + 删行;
  session 行走 `unmount/4`,person 行走 `unmount_for_person/3`)。**单行失败只记
  warning 计入 `failed`,不牵连其余行;整体永不 raise**(和现成的
  `reconcile_session_mounts/1` 同一种 best-effort 姿态——清理路径不能因为一行坏数据
  就把整个删除流程崩掉)。返回 `{:ok, %{unmounted: n, failed: m}}`。

业务侧删宿主时调一行 `Mount.unmount_all_for_target(target_uri)` 即可。

(注:person 行 `session_uri` 为 NULL,清理时必须分路处理,否则解析 session URI
会 raise、整个清理退化成 no-op——本实现已按 scope 分路。)

## 件二:冷建 provisioning 默认 5s 超时 → 建到一半崩出「孤儿/幽灵」

### 现象

冷建一个 agent(spawn + recipe 物化 + CapMint + snapshot)或一个会话(模板物化 +
socialware 安装)实测经常超过 5 秒。而 dispatch 的 `:call` 默认超时是 GenServer
的 5s(`inv.ctx[:deadline_ms] || 5_000`)。于是:

- caller 这边 5s 一到收到 timeout,整条 `with` 链按失败崩掉;
- 但底层建到一半的东西**已经建成了**——留下「agent 建成、零钥匙零挂载行」的孤儿
  宿主,或「报错但会话其实已存在」的幽灵成功。

### 方案

透传管道 main 上已有:`Ezagent.Workspace.Provisioning.maybe_put_deadline_ms/2`
会把 caller ctx 里的 `:deadline_ms` 放进 dispatch ctx。本 PR 三处小改:

1. `Mount.provision`(建宿主 + 当场挂)—— `owner_ctx` 显式带 `deadline_ms: 30_000`;
2. `Provisioning.create_session/3` —— 补上和 `create_agent/3` 同款的
   `maybe_put_deadline_ms` 透传(原来只有 create_agent 接了,create_session 落下了,
   caller 传了也会被丢);
3. world UI 建会话入口(`ConversationActions.do_create_session`)—— caller ctx 带
   `deadline_ms: 30_000`。

**没做的(留提案)**:provisioning 全线统一默认 30s(而不是每个 caller 自己给)——
这是个一刀切的架构决定,记给 Allen 线,本 PR 不动默认值。

## 验证

- `mix test apps/ezagent_domain_session/test/ezagent/socialware/mount_test.exs
  apps/ezagent_domain_session/test/ezagent/socialware/mount_row_test.exs` 绿
  (含新增:跨 session/跨 grantee/person 行全清 + 别的 target 不牵连 + 空 target no-op);
- `mix format --check-formatted`、编译零 warning、`mix ezagent.check_invariants` 绿;
- diff 内零业务字面(纯通用 infra,业务名 grep 零命中)。
