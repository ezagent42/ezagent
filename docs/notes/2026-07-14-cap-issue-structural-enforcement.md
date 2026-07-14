# 用源码扫描去证明一个运行时性质 —— 这场军备竞赛赢不了

**状态:** 待 Allen 决策。**不是 bug 报告 —— 是"我们守错了地方"。**

**性质:** Decision #162 说 `Cap.issue/3` 是唯一的 grant constructor。我们用**源码扫描**去强制它。**扫描器被绕过了三轮。第三轮之后我才明白:它永远绕得过。**

---

## 事实先摆着

我们想要的性质是一句关于**运行时**的话:

> **每一个进入 `users.caps_json` 的 cap,都经过了 `Ezagent.Cap.issue/3`。**

(这一列**就是**用户的权限 —— user Kind 开机时从它对账出自己的 cap slice。)

我们拿**源码长什么样**去证它。三轮:

| 轮次 | 扫描器"修好"之后,还漏 | 谁发现 |
|---|---|---|
| 1 | `Users.create_read_only/2` · `scripts/*.exs` | 自查 + codex |
| 2 | 管道 · 别名 · `apply` · capture | codex |
| 3 | `import` · `@attr` · **`Module.concat`** | 自查 |

前两类都补上了(现在 7 种写法全抓,见 `cap_issue_chokepoint_boundary_test.exs`)。

**但第三类补不上:**

```elixir
m = Module.concat([:Ezagent, :Users])
m.create(uri, pw, forged_caps)          # 模块名在【运行时】拼出来
```

**任何源码扫描都看不见它。** 不是扫描器写得不够好 —— **是原理上看不见。**

而且我此前声称的"守列(leg 3a)是它的结构性兜底"—— **那句是假的**。绕过的**调用方**并不写 `caps_json:`,写它的是 `users.ex`。leg 3a 抓的是「`Users` 里新增写入函数」,**不是**「没登记的调用方」。

---

## 所以这道 gate 到底证明了什么

**只证明这个,一个字不多:**

> **每一个【静态可解析】的调用点都被枚举了,且这一列的每一处赋值都被枚举了。**

**它没有证明** "每一个进入 `caps_json` 的 cap 都经过了 `Cap.issue`"。

**这个缺口不是"再聪明一点的扫描器"能补的。**

---

## 真正的修法:让它在运行时不可违反

```elixir
# Ezagent.Cap —— 发放时记指纹
def issue(authorization, target, cap) do
  with :ok <- CapabilityRegistry.authorize_grant(...),
       {:ok, artifact} <- prepare_provenance(authorization, cap) do
    Ezagent.Cap.Issued.record(artifact)      # ETS,core 里已有同类表(KindRegistry / Idempotency)
    {:ok, artifact}
  end
end

# Ezagent.Users —— 拒收未发放的 cap
defp do_create(uri_str, password, caps, opts) do
  :ok = Ezagent.Cap.assert_all_issued!(caps)   # ← 结构性:跟【怎么拼那个调用】完全无关
  ...
end
```

**这样,`Module.concat`、宏、动态 atom —— 全都无所谓了。伪造的 cap 存不进去。**

源码扫描降级成 **review 锚点**,不再是保证。

### 必须一起定的三个边角(不能含糊过去)

| | 问题 | 备选 |
|---|---|---|
| **信任根** | genesis bootstrap 在开机时铸 admin 的通配 cap,**那一刻没有更早的权威可依** | 给它一个**刺眼命名**的显式豁免口(`Users.create_genesis_admin/2`),让"信任从这里开始"在代码里**看得见** |
| **结构性默认 cap** | `do_create` 会自动 prepend `User.default_caps/1`(自省用的 `identity.list_caps`)。这些也没经过 `Cap.issue` | 要么一起发放,要么显式豁免 —— **但必须选一个,不能默认漏过** |
| **ETS 生命周期** | 指纹表随 owner 进程死。重启后旧 artifact 不在表里 | issue → store 在同一条调用链里完成,窗口极短。但**要显式确认**:有没有跨重启的 issue-then-store? |

---

## 为什么这是决策,不是我自己改

它动 **core**(`Ezagent.Cap`)+ 改 **`Ezagent.Users` 的公开 API 契约**(`create/3` 从"接受任意 cap 列表"变成"只接受已发放的 artifact")。

按 CLAUDE.md:**架构决策走 Allen。**

---

## 更值得记住的那条(这才是我写这份 note 的原因)

这不是一次"扫描器写得不够仔细"。**这是一个反复出现的形状:**

> **一个安全性质有 N 条路可以被违反。验证了其中一条(或几条)。然后把【那次验证的结果】写成【整个性质的证明】。**

同一个形状,在这个仓库里至少出现过四次:

| | 验证了什么 | 声称了什么 |
|---|---|---|
| **Codex PR #356 r1** | 收窄了**谁能进** `create_user` 这扇门 | 把 *"could mint users with arbitrary caps"* 标成已处理 —— **门修了,房间里的炸弹没碰**。三个月后工作区管理员仍能造出全局 admin |
| **I7 leg 1 & 2** | 守住了 cap **构造** + `{:set, :caps}` **slice 写入** | 声称 chokepoint 已强制 —— **`caps_json` 那条路一直没人守** |
| **`spawn_plan.ex` 的注释** | *"Verified empirically: `--continue` degrades gracefully"* | 那是**某个条件下**的观察,被写成了**普遍性质**。它是假的,而且它就是 #1294 的根因 |
| **`CredentialPrecondition` moduledoc** | 假定"用户可以进自己 agent 的 PTY 打 `/login`" | **那个出口从来没被实现过**。没人验证过它存在 |

**每一条单独看都是真话。合起来是假的。**

### 为什么这个习惯这么顽固

**因为修一条路有即时反馈(测试变绿),枚举全集没有。**

枚举全集看不到进度,而且它的产出是一句坏消息:「我还有 3 个洞没修」。所以人本能地跳过它。

**这不是能力问题,是激励问题** —— 而"下次更仔细一点"治不了激励问题。

### 落到可执行的一条

**gate 的价值不是"防别人以后犯错"。是"逼我在声称之前先枚举全集"。**

**你写不出守列的 gate,就说明你还不知道那一列有几个入口 —— 那你就没资格说"守住了"。**

而当枚举出来的全集里,出现一条**源码看不见**的路 —— **那不是让你去补 gate,是让你去换实现。**

---

**相关:**
- `apps/ezagent_core/test/invariants/cap_issue_chokepoint_boundary_test.exs` — gate 的边界,**写成了测试而不是注释**(注释会烂,而它已经骗了我三次)
- GLOSSARY Decision Log #162 — ISSUE → STORE → VERIFY
