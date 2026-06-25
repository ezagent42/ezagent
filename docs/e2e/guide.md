# 测试全流程的流程(人肉 E2E 记录指南)

> 这份 guide 定义**你怎么操作、我怎么记**,以及每条 `scenario-<no>.md` 的取证、命名、判定规范。
> 索引和黄金路径清单在 [`README.md`](./README.md)。

---

## 1. 角色分工

| 角色 | 谁 | 做什么 |
|---|---|---|
| **操作员** | zyli(你) | 真实点 UI / 敲命令,口述每一步在做什么、看到了什么 |
| **记录员** | Claude(我) | 实时把你的操作写进 `scenario-<no>.md`,抓证据、归档截图、回填判定与状态表 |

**节奏**:你做一步 → 告诉我"我点了 X,看到 Y"(或贴截图)→ 我追加一条执行记录行 + 归档证据 → 进入下一步。
一条 scenario 跑完 → 我回填实测结果、判定、`README.md` 状态表,并提示是否 commit。

---

## 2. 全流程总览(黄金路径)

```
01 登录 ─→ 02 创建 agent ─→ 03 建 session+加成员 ─→ 04 echo 往返
                                                       │
        ┌──────────────────────────────────────────────┤  (逐个 agent flavor 接入同一 session)
        ▼              ▼                ▼
   05 cc 往返     06 codex 往返    07 curl/deepseek 往返
        └──────────────┬─────────────────┘
                       ▼
              08 @mention 门控路由
                       ▼
              09 跨 session mention 被拒(负路径)
                       ▼
              10 绑定 Feishu chat↔session(出站:session 回包镜像到 Feishu)
                       ▼
              11 Feishu 入站到达 → 路由到 agent(外部 channel → dispatch)
                       ▼
              12 dispatch 审计核对(收口:DB/审计行兜底证明前面都真发生了)
```

- **顺序硬约束**:01→02→03 必须先跑(登录态 → 有 agent 可加 → session+成员是后续前置)。04~07 可任意顺序但都依赖 03。08 依赖至少 2 个成员。10→11 依赖 Feishu sidecar(出站先通才验入站)。12 最后跑,用审计行交叉验证前 11 条。
- **每条都对应一个设计场景**(`docs/scenarios/NN`)——执行前先读对应设计场景的"预期结果/失败模式",照着验。**02 创建 agent 当前无设计场景**(`docs/scenarios` 缺位)——按 world UI 实际流程跑,并把它当成候选补一条设计场景。

---

## 3. 环境前置(每次开测先确认)

| 项 | 值 | 备注 |
|---|---|---|
| Phoenix HTTP | `http://localhost:10042`(或 Tailscale `http://100.64.0.27:10042`) | `PORT` 可覆盖 |
| **World 操作员 UI** | `http://world.localhost:10042` | host-routed;**别用** `world.ezagent.chat`(HSTS 升级成 HTTPS 会白屏) |
| 登录/注册 | `http://localhost:10042/login`、`/register` | host-agnostic |
| 公开 customer 页 | `http://localhost:10042/socialware/customer?session_uri=<enc>` | `public_view` session 免登录 |
| Health | `GET /_health` → 200 | 起没起先探这个 |
| Action 目录 | `GET /api/v1`(JSON,106 路由) | 排错用 |
| **world seed admin** | `admin@ezagent.chat` / `worlddev` | world E2E seed 后(见下) |
| 共享 stack admin | `entity://system/user/admin` / `e2e-admin-2026` | 登录用户名栏填**完整 URI** |
| 默认 workspace | `workspace://system` | `workspace://default` 是禁用别名 |

**启动**(server 没跑时):按 `docs/guide/world-e2e-seed.md` 起 PG → seed → `mix phx.server`。
**自助凭据**:卡密码就自己 mint,别等 Allen —— `mix ezagent.user.token entity://system/user/admin --mint` 然后 `set_password`(见 scenarios/README §1.1)。

每条 scenario 头部都要记下**当次实际**的:commit hash、分支、server URL、执行时间。

---

## 4. 取证规范(硬规则)

> 沿用 `feedback_esr_e2e_standards`:触及 UI / Feishu 的 E2E,**必须** agent-browser 截图。仅看日志**不算签收**。

1. **主证据 = agent-browser 截图**(headless Chrome 对 LiveView)。每个关键步骤(登录成功、session 创建、消息往返、路由命中/被拒)至少一张。
2. **辅助证据**:CLI/curl 原始输出贴进代码块;关键 SQL/审计行(`invocations` 表)在 09 收口时抓。
3. **不算数的**:cc-openclaw 自己的 Feishu DM 不计;只有 ezagent sidecar 的回复算。纯日志截图不算 UI 签收。
4. **截图存放**:`docs/e2e/evidence/scenario-NN/`,命名见 [`evidence/README.md`](./evidence/README.md)。
5. **React 岛注意**(见 `world_react_island_form_submit_swallowed` 记忆):world 里 `phx-update=ignore` 岛内原生 form submit 会被 LiveView 吞,取证时若遇"点了没反应",用 `onClick + form.submit()` 绕过,并在记录里标注。

---

## 5. 一条 scenario 的生命周期

```
⬜ pending          复制 template,填头部元信息 + 前置 + cross-ref
   ↓ 你开始操作
🔧 executing        每步追加一行:操作 | 实际观察 | 证据链接 | 单步判定
   ↓ 跑完
🟩/🟥/🟨 判定       回填"实测 vs 预期"、遗留/bug、证据清单
   ↓
回填 README 状态表 + 进度汇总 + 提示 commit
```

**记录粒度**:执行记录表一行 = 一个可观察动作。宁可细不可粗 —— 别人照着这张表能复现。

---

## 6. 判定标准

| 判定 | 含义 |
|---|---|
| 🟩 **PASS** | 实测结果 == 设计场景预期,关键步骤都有截图证据,无未解释偏差 |
| ⚠️ **PASS-with-gaps** | 主路径过了,但有非阻塞瑕疵(UI 小问题、缺失败模式覆盖),已在"遗留"列明 |
| 🟥 **FAIL** | 关键步骤结果 != 预期,且不是前置问题。必须附:复现步骤 + 证据 + 初判根因 |
| 🟨 **BLOCKED** | 被前置 scenario 失败 / 已知 bug(如 F5)/ 环境问题卡住,没法判 PASS/FAIL。注明阻塞源 |

FAIL/BLOCKED **不要**自己改代码"修"掉 —— 按 CLAUDE.md grill 文化:记 issue、标证据、暂停等 Allen。

---

## 7. 收尾约定

- 一条跑完:回填该 `scenario-NN.md` 末尾 + `README.md` 状态表那一行 + 进度汇总。
- 一轮(多条)跑完:`docs(e2e): <范围> 执行记录(NN..MM)` 提交(证据截图一并入库)。
- 发现的 bug:在该 scenario 的"遗留/bug"区记清,必要时新建 `docs/scenarios/` 的 open-bug 交叉引用,**不在执行层修设计**。
