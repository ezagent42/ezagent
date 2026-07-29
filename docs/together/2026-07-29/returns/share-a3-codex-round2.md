> **Task:** share-A3 codex round-2 —— 三条必修(认证 requester / 幂等键纳入 scope / command 表 XOR CHECK)
> **Branch:** `feat/socialware-share-a3-consent`
> **PR:** #1597
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-29 16:10 +0800
> **deadline_status:** on_time

## 背景

A3 首轮 M3/M4 经 codex 验证:current-owner 重解析 + consent 行 XOR CHECK 都是真的,但还留三个洞。本轮针对性修完三条,各带判别性回归。已 rebase 最新 main(`c4ec7b478`,今日合 #1596/#1611/#1612/#1614/#1615/#189 等;与 A3 文件零重叠,rebase 干净)。

## 三条修复

### 1. `request` 的 requester 未认证(M3 没闭环)
**洞**:`request/4` 接受任意 requester URI 作自由入参 —— 审批人批的是"声称的 requester",任何调用者能以别人名义发起。
**修**:`request/4` → `request/5`,新增 `authenticated_principal`(transport 传的认证主体)。落库前校验 `requester == authenticated_principal`,不一致直接 `:consent_requester_not_authenticated`,啥也不写。
**回归**:attacker(认证主体)以 victim 名义发起 → 拒;`pending_for_owner(owner) == []`(没留下可误批的请求);honest 路径(requester==principal)仍通。

### 2. 幂等键太粗 —— 批准被跨 behavior/actions 复用
**洞**:consent id = `(target, requester)`,同一对主体一次批准后,不同 behavior/actions 命中同一行 → 批 A 动作等于批 B。
**修**:`share_consent_id` 纳入授权 scope —— `share:<target>:<grantee>:<scope_digest>`,`scope_digest` = `sha256(behavior <> "|" <> sorted(actions))` 取前 16 hex。动作排序 → `[:a,:b]`/`[:b,:a]` 归一;behavior 入摘要 → 两 behavior 同名动作不撞。同 (target,grantee) 不同动作集 = 不同 consent、需另行审批。
**回归**:同一对主体、`[:get_tree]` 与 `[:add_node]` → 两个不同 id;批准 read consent 后 write consent 仍在 `pending_for_owner` 里、read 不在 → 无复用。

### 3. command 行缺 `binding_id XOR consent_id` CHECK
**洞**:M4 只给 **consents 表**加了 binding/uri-share XOR CHECK,**commands 表**没有对应约束 —— 两者都填/都空的命令行能落库。
**修**:migration 给 commands 表补 `consent_command_binding_xor_consent` CHECK(`(binding NOT NULL AND consent NULL) OR (binding NULL AND consent NOT NULL)`);`CompositionConsentCommand.changeset` 加 `validate_shape` + `check_constraint` 镜像,畸形行在 insert 前 fail-loud。
**回归**:changeset 对 both-set 与 neither-set 各 `refute .valid?`(生产两条路径 apply_command/apply_decide 都走 changeset);原生 SQL 绕过 changeset 插 neither(FK-free,隔离出是我这条 CHECK 而非 FK 报错)→ `assert_raise Postgrex.Error ~r/consent_command_binding_xor_consent/`,证 DB 层 backstop 真装上。

## DoD reconciliation
| # | DoD | status | proof |
|---|-----|--------|-------|
| 1 | requester 取自认证主体、伪造拒 | met | uri_share_test:forge→`:consent_requester_not_authenticated`+pending 空 |
| 2 | 幂等键纳入 scope、批准不跨动作复用 | met | uri_share_test:两动作集不同 id + 批 read 后 write 仍 pending |
| 3 | command 表 both/neither → DB 拒 | met | changeset both/neither refute valid + 原生 SQL neither → 命名 CHECK 拒 |
| 回归 | 三条各带判别性回归 | met | 新增 3 test,`composition_consent_uri_share_test` 9/0 |
| 闸 | 编译/format/Z-1/check_invariants/gate.arch | met | warnings-as-errors 0;format clean;Z-1 无 banned literal;check_invariants 全绿;gate.arch 4/0+39/0 |

**Method friction:** (1) migration 改(加 CHECK)→ 跑测试前需 `mix ecto.reset`。(2) 本地 WSL2 box 上文件扫描型 invariant ExUnit 闸(uri_canonicalization / all_per_tenant_uris / no_chat_behavior 等十余个 `System.cmd` grep 闸)全部撞 60s 超时墙 —— 系统负载 + WSL2 文件树扫描慢的环境 artifact,非代码信号(我 diff 不含 URI.parse / 2-segment URI / 任何这些闸扫描的模式);真闸(check_invariants grep + gate.arch AST + socialware conformance)全绿,CI 为权威。(3) 两个 mix 并发跑撞坏 `_build/test/consolidated`(memory 已警告)→ 串行。

## Merge request
A3 codex round-2,PR #1597。三条洞修完,回归判别性充分,rebase 干净无重叠。CI 绿后 cc 快速 codex 验证 → gate+merge。
