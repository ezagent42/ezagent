# A² 验收 e2e — #1209 物化 agent 自动继承 installer host 登录(零手动 creds、零 watcher)

**验收结论:通**。分支 `feat/sw-kanban`(rebase 到 main `03136e446` = PR #1209)上,独立冷库、
**全程不手动拷任何 credentials、不跑 creds watcher**:发布 cc 变体 → UI 建会话 → 两个 cc agent
materialize 后 config_dir **自动**出现 `.credentials.json`(sha256 与 host `~/.claude/.credentials.json`
逐字节一致),PTY 首屏 banner 直接 `Claude Max` 已认证,`Not logged in` 在本轮日志中 0 次;
mention 极小指令拿到真思考回复(17*23 → 391,8s 回合)。r2 的 gap ⑤(watcher 竞态 + 手动拷兜底)
在 #1209 下不再需要。

## 与 #1209 实现的对照(逐条验证注入形态)

#1209 的 seam 不是"拷文件到 config_dir"这个动作本身新加的——它是在
`DefinitionAgents.materialize_fresh_agent` 前插了一个幂等 auto-adopt
(`Ezagent.Agent.HostLoginAdopt.ensure_installer_source/3`,apps/ezagent_domain_agent/lib/ezagent/agent/host_login_adopt.ex):
当 flavor 是有凭证的 CredentialAdapter、host 登录可用(`CredentialAdapter.host_login_source_dir/1`
要求 host home 存在且 secret 在场)、且 installer 是 host operator(genesis admin,
`Ezagent.Identity.admin?/1`)时,把 host 登录注册成 durable per-workspace source 并写
(installer, ws, flavor) 的 UserDefaultSource 指针;下游全部走**未改动的 #17 cascade**
(resolve → installer caps 下铸 grant → layer merge + §D6 secret-only copy)。逐条实测:

| #1209 声称 | 本轮实测 | 证据 |
|---|---|---|
| auto-adopt 写 (installer, ws, cc) 指针 | `user_default_credential_sources` 1 行:`entity://system/user/admin` / `system` / `cc` → `entity://system/agent/cc-host-login`(冷库,零 `mix ezagent.credential.adopt`、零 UI adopt) | `03b-db-seam-evidence.txt` |
| host-login source 注册 + AgentLineage owner 边 | `agent_lineage` 有 `entity://system/agent/cc-host-login` 行 | 同上 |
| 每个物化 agent 一条 installer 批准的 durable GrantRow | `credential_grants` 恰 2 行,`aa36918d…`/`d4bb4b6e…` 各一条,`credential_source_uri` 均 = `cc-host-login` | 同上 |
| §D6 secret-only copy 进 config_dir | 两个 config_dir 各有 `.credentials.json`(0600,471B),sha256 `cef6c1a1…` 与 host 源一致;merge 层其余文件(`.claude.json`/`settings.json`/`skills/`…)同批出现 | `03-config-dirs-and-environ.txt` |
| 物化即已认证(修的就是 "Not logged in" 空 config home) | 双 PTY 首屏 banner `Opus 4.8 (1M context) · Claude Max`;`Not logged in` 全程 0 次;`/proc/<pid>/environ` 的 `CLAUDE_CONFIG_DIR` 各指自己的 config_dir(隔离没破) | `03c-pty-banner.txt`、`03-config-dirs-and-environ.txt` |

## 环境(照 r2,唯一区别 = 零手动 creds、零 watcher)

- 独立冷库 `POSTGRES_DB=ezagent_a2_e2e`(drop/create/migrate,零 seed;admin 由 boot
  `EZAGENT_ADMIN_PASSWORD=worlddev` 供给,`admin@ezagent.chat`)
- 工具链 `mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13`;server distributed
  (`elixir --name ezagent_runtime@127.0.0.1 --cookie $(cat ~/.ezagent/default/runtime/cookie) -S mix phx.server`,PORT=10042)
- agent-browser 真 Chrome,world 控制台 `http://world.localhost:10042/`
- host 登录源:`~/.claude/.credentials.json`(471B,0600)——**唯一的"凭证"输入,且没人碰它**

## 步骤与判定

| 步 | 判定 | 证据 |
|---|---|---|
| 1 冷起+登录 | ✅ 冷库 0 会话,admin 登录 | `01-login.png` |
| 2a 发布 cc 变体 | ✅ `manifest_attrs(name:"a2-verify",flavor:"cc")` → 真 governance `{:ok,:published}`(erpc,`publish_a2.exs` = r2 脚本改名) | server 落库日志 |
| 2b 下拉建会话 | ✅ 下拉 6 项含 `value=a2-verify`(title "Kanban 看板团队");名称 `a2-zero-creds`;创建按钮 JS click(r2 gap ⑥ 同样复现) | `02-create-form-cc-variant.png` |
| 2c 双 agent materialize | ✅ `aa36918d…`=kanban-assistant、`d4bb4b6e…`=dev-together,MEMBERS=3 全绿 | `02-session-agents.png` |
| 3 **主证:零手动自动认证** | ✅ 两个 config_dir 自动出现 `.credentials.json`(sha256 与 host 一致);DB 指针/grant/lineage 齐;banner `Claude Max`;environ 佐证 | `03-*.txt` 三件 |
| 4 真思考证明 | ✅ owner 全 URI mention(裸名仍不路由,r2 D⑧ 未变)发"17*23 是多少" → mentions 解析中,PTY `← esr-bridge:` 收到,8s 真回合回 "17*23 的结果是 391。" 落库进对话 | `04-instruction-sent.png`、`04-real-reply.png` |
| 5 清理 | ✅ 按 PID 点名:claude 33597/33710 → beam 32102(KILL 补刀)→ 全子进程验证退出;浏览器 close | — |

## 本轮小刺(不影响验收结论,如实记)

1. **UI 建会话 5s call timeout**:点创建后 LV 报
   `创建会话失败：{:create_session_exit, {:timeout, {GenServer, :call, [...5000]}}}`——
   materialization(双 cc PTY 冷启动 + auto-adopt + cascade)远超 5s,但**后台照常完成**,
   刷新后会话在、agent 全绿。UI 层 call 超时时长 vs 物化耗时的错配,纯 UX 问题,建议单开 issue。
2. 发布变体后需刷新页面,建会话下拉才含新变体(LV mount 时点快照,r2 未记录此点)。
3. r2 gap ⑥(创建按钮原生 click 不触发 LV 事件,JS `el.click()` 即中)原样复现。

## 复跑指引

```bash
POSTGRES_DB=ezagent_a2_e2e mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- mix do ecto.drop, ecto.create, ecto.migrate
POSTGRES_DB=ezagent_a2_e2e EZAGENT_ADMIN_PASSWORD=worlddev PORT=10042 mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- \
  elixir --name ezagent_runtime@127.0.0.1 --cookie $(cat ~/.ezagent/default/runtime/cookie) -S mix phx.server
# 登录 http://world.localhost:10042/ → erpc 发布变体(r2 publish_variant.exs 改 name)→ 刷新 → 建会话
# 等 ~1 分钟物化(UI 会报 5s timeout,不影响)→ 直接查 ~/.ezagent/default/cc-agents/system/<uuid>/.credentials.json
# 不需要 watcher,不需要手动拷任何东西
# 清理:kill <claude pids>;kill <beam pid>(顽固时 -9)
```

前提:host operator(= 起 server 的同一 OS 用户)`~/.claude/.credentials.json` 在场且有效;
installer 必须是 genesis admin(非 operator installer 按 #1209 DoD 6 不继承——本轮未另测,
有 #1209 自带的 invariant test 覆盖:`socialware_cc_credential_inherit_test.exs` 非 operator 安全 case)。
