# 研究 · external_mirror 出入站的开发/e2e/证据约定（mindmap↔Miro，2026-06-22）

> 只读分析，未跑 mix / 未改代码。给"把 mindmap↔Miro 做成完整 external_mirror 出入站"这一轮开发用，
> 让它参照已落地的 external_mirror（feishu push + socialware pull）+ 已有 mindmap 三份证据的规范落地。
> 引用全部带 file:line。

---

## 0 · 先认清 external_mirror 的两条轴（这是本轮的骨架）

external_mirror Domain 把"ezagent 数据 ↔ 外部 surface"拆成 publisher / adapter / binding 三层
（`docs/superpowers/specs/2026-05-24-external-mirror-domain.zh_cn.md:109-321`）。**P3-1 给 adapter 加了
KIND 轴**（push / pull），这是本轮最关键的参照，看
`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex:69-97`：

- **`:push`（默认轴）** = 原版出站。adapter 是**纯函数** `event_to_payload/1`（无 I/O，
  `adapter.ex:39-49` 解释为什么必须纯）；配套一个 **Binding GenServer** 真做传输（`publish/2`）。
  `:bind` 时 Domain spawn 一个 Worker，每条 publisher event 调一次 `binding_module.publish/2`。
  必需回调：`binding_module/0` + `cap_subject/0` + `target_ownership_check/2` + `event_to_payload/1` +
  id/name/description 三件套（`adapter.ex:78-80`）。
  → **mindmap 出站（节点树变化 → Miro）就是一个 `:push` adapter `{MiroAdapter, MiroBinding}`**。

- **`:pull` 轴** = 按需被 caller 的 Phoenix channel 渲染（socialware customer feed，P3-2 commit e3b6ffba）。
  无 Binding、无 Worker、无 `target_ownership_check`、无 `event_to_payload`；只实现 `render/2`
  返回 json 视图（`adapter.ex:82-88`、`adapter.ex:255-264`）。
  → **Miro 入站不属于 pull adapter**。pull 是"外部来 GET 我的数据"，Miro 入站是"人在 Miro 改 → 回灌 ezagent"，
  Miro 无服务端长连只能本地**轮询 GET mindmap_nodes + diff**，它走的是**入站 dispatch 通路**（见 §3），
  不是 external_mirror 的 adapter 回调。external_mirror 只覆盖出站那一半。

`adapter_kind/0` 是 optional，back-compat 默认 `:push`（`adapter.ex:90-96`、`kind_of/1` 在 `adapter.ex:287-298`），
所以老 adapter（feishu mirror、测试 adapter）不声明也算 `:push`。注册期的"按 kind 卡必需回调"在
`AdapterRegistry.assert_required_callbacks!/1`（`adapter.ex:155-159` 指明），不是编译器。

---

## ① 一个 external_mirror 特性的 e2e 证据长什么样

DoD = **可演示产物**，不是"测试绿"（`.claude/skills/dev-together/references/handoff-standard.md:6-18`）。
external_mirror 是 backend/外部集成，对应的可演示形态 = **"一条数据真的穿过新通路、外部真有变化"的实测输出**。
已有 mindmap 三份证据是模板，照抄它们的结构：

### 出站（ezagent → Miro，真推）的可演示产物
照 `docs/superpowers/evidence/2026-06-22-mindmap-miro-outbound-evidence.md` 的写法，五段：
1. **API 契约探活**（先探真 API 再写代码）—— 用真 token 对 experimental 端点逐步探活反推 schema，
   贴出 201 响应 + 确切 body 形状（该文 §1，`:1-13`）。
2. **端到端实测**：构造一棵与 `get_tree` 同形的树 → 经出站链路真推 Miro → `GET .../mindmap_nodes` 复核，
   贴**真实 stdout**（该文 `:19-24`：`PUSH_OK board_id=… 建了 N 个节点` + `VERIFY_GET 板上实有节点=N 其中根=1`）。
   **关键断言三件**：节点数对、根数=1、层级（父在子前）对。
3. **单元测试**（纯函数无网络，如 `tree_to_ops/1` 树→有序操作，该文 `:29-32`）。
4. **PR gate 全绿表**（该文 `:34-42`）。
5. **诚实推迟**段（该文 `:49-54`）—— 把还没做的（入站、复用同板、增量 diff）**显式列出**，不伪造绿。

> 注意：现有出站证据是**裸 `Miro.Sync.push_tree/2` 脚本**，每次**建新板**（证明链路）。本轮要升级成
> **走 external_mirror adapter 契约 + 复用同板 + ez_id↔miro_id 映射 + 增量 diff**（该文 §6 已把这列为下一步），
> 所以本轮出站 e2e 应额外断言：**复用同一 board_id 第二次推只发增量、不重建**。

### 入站（人在 Miro 改 → 回灌 ezagent）的可演示产物
external_mirror 自身没有入站；入站是**轮询 + dispatch** 的独立链路（§3）。对应可演示产物 = **"在真 Miro 板上手改一个节点
→ 轮询一拍 → ezagent 树真的变了"** 的实测输出 + 一条经 `Ezagent.Invocation.dispatch/1` 的成功记录。
照 `docs/superpowers/evidence/2026-06-22-mindmap-e2e-evidence.md` 的双向往返写法（该文 `:7-29`：建→导出→改→导入→读树反映改动，
**每步均经真实 dispatch**，贴 ExUnit 真实输出 `1 test, 0 failures`）。

---

## ② gate 全集 + 本插件特有注意

### gate 全集（handoff 标准，每个 PR 都过）
权威清单 `handoff-standard.md:16-18` + 现有 mindmap 证据已逐条跑过
（`2026-06-22-mindmap-increment3-evidence.md:20-28` 的全 gate 表 = 最新模板）：

| gate | 命令 | 现状基线 |
|---|---|---|
| compile + 插件契约 | `mix compile --force`（含 `:ezagent_plugin_check`）| exit 0 |
| arch.scan | `mix ezagent.arch.scan` | `set_effect_sites: 122/122` |
| check_invariants | `mix ezagent.check_invariants` | clean |
| check_invariants.lifecycle | `mix ezagent.check_invariants.lifecycle` | clean |
| doc.scan | `mix ezagent.doc.scan` | `undocumented_public_defs 374/392`（cap 别超）|
| uri_query.scan | `mix ezagent.uri_query.scan` | no violations |
| format | `mix format --check-formatted <你的文件>` | rc=0 |
| test | `mix test`（本插件全绿 + umbrella 编译干净）| — |

外加 **"work 自己的 invariant/regression 测试"**（`handoff-standard.md:18`）——
出站的 echo-loop safety、入站的 cap-denial-回滚，都该有自己的测试。

> umbrella 主线本就带红（liveview/workspace 那批与本插件无关的既有失败），
> 诚实声明照 `2026-06-22-mindmap-e2e-evidence.md:61-65` 的写法：本插件自身测试全绿 + umbrella 编译干净即可，
> 不为主线既有红伪造绿。

### 本插件三条特有注意（最容易踩，已在现有证据踩过并记录）

1. **set_effect_sites 单 commit（arch.scan）**。每个写状态的 Behavior 至少需 1 条 `{:set}` effect，
   arch.scan 卡 effect 站点总数（umbrella 基线 cap=122）。mindmap 的做法是**整棵树收进单一 `:tree` key + 所有
   14 个动作的写收敛到唯一一个 `commit/1`**，于是只新增 1 个站点
   （`2026-06-22-mindmap-increment3-evidence.md:23`："所有写走单一 `commit/1`，14 动作不增站点"；
   增量1 的 ratchet 论证 `2026-06-22-mindmap-e2e-evidence.md:56`）。
   → **本轮新增的 Miro 映射 slice / worker slice 写，也要走单一 commit，别散落多个 `{:set}`**，否则 cap 又得 bump（要带
   `# arch-cap-bump:` 注释 + review）。

2. **uri_query 用 `Ezagent.URI.system` / `with_action`，不手拼 query（uri_query.scan）**。
   现有 Miro 凭证读已是正例：`Ezagent.URI.system("credentials", "miro.yaml")`
   （`apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/miro.ex:29`，行 27 注释明说"运行时从段构造，sanctioned，过 uri_query.scan；
   不在模块属性建——编译期会被 scan 拦"）。入站 dispatch 目标 URI 要用 `Ezagent.URI.with_action(session_uri, :mindmap, :add_node)` 这类
   构造器（参照 feishu `inbound_dispatcher.ex:286` `Ezagent.URI.with_action(session_uri, :session, :send)`），
   **不要字符串拼 `?action=`**。

3. **doc.scan 用 `@doc false`（undocumented_public_defs）**。所有不想计入文档覆盖的 public def（宏展开出的
   handler、内部 helper）标 `@doc false`（mindmap 已大量这么用：`behavior/mindmap.ex:147/170/180/209/213/239/257/269`、
   `mindmap.ex:26/33`）。新增 MiroAdapter / MiroBinding 的 public callback 要么有真 `@doc`，要么 `@doc false`，
   否则 `undocumented_public_defs` 计数涨、撞 cap。

---

## ③ 出/入站各自的 e2e 该断言什么（真实 Miro 往返）

### 出站 e2e（`:push` adapter，真推 Miro 并 GET 复核）
参照 feishu push 链路（`feishu_chat_binding.ex` 是 Binding 实现样板）+ 现有出站证据。断言：

1. **链路经契约、非裸脚本**：`adapters/0` 声明 `{MiroAdapter, MiroBinding}`（对齐 feishu
   `application.ex` 的 `{FeishuAdapter, FeishuChatBinding}`，spec `:537-539`）；编译期 `:ezagent_plugin_check`
   过双向声明（adapter.binding_module == binding 且 binding.adapter_module == adapter，spec `:549`）。
2. **节点树变化 → publisher event → MiroAdapter.event_to_payload/1（纯）→ MiroBinding.publish/2（真调 REST）**。
   `event_to_payload/1` 必须纯无 I/O（`adapter.ex:39-49`）；真正 `POST/PATCH/DELETE .../mindmap_nodes` 在 `publish/2`
   （对齐 `feishu_chat_binding.ex:94-106` 的 publish 折叠 + 4xx/5xx 可恢复语义）。
3. **复用同板 + 增量**：第一次 bind 建/绑定 board，之后**复用同一 board_id 只推 diff**（建/改/删变化的节点），
   GET 复核：变化的节点对、未变的不重建、ez_id↔miro_id 映射稳定。
4. **partial-publish 不静默丢**：多节点一次推时若中途失败，照 feishu `feishu_chat_binding.ex:108-167` 的处置——
   pre-send 失败（sent==0）= 可恢复 `{:error,_,_}`；partial（sent>=1）= **RAISE**，让 Worker 崩 + 重启 + cursor 不越过未处理数据。
5. **per-binding 崩溃隔离**：一个坏 binding 不拖垮兄弟（两层 supervisor，spec `:566-584`）。

### 入站 e2e（轮询 GET + diff → dispatch，真 Miro 往返）
入站没有 external_mirror adapter 回调，走**轮询 + 入站 dispatch**，照 feishu `inbound_dispatcher.ex` 全套样板。断言：

1. **在真 Miro 板上手改一个节点**（改标题 / 加子节点 / 删节点）。
2. **轮询一拍**：`GET .../mindmap_nodes` 与本地映射 diff，识别出"人为改动"。
3. **echo / 回声防护**：自己刚出站推的变化带 origin 标记 / 版本游标，轮询回来识别为"自己推的"则丢弃，
   只处理真人改动（对齐 feishu inbound 的 `_feishu_origin` 标记 `inbound_dispatcher.ex:261`、
   connector design `2026-06-22-mindmap-miro-connector-design.md:64-65`）。断言：纯出站不会触发入站回灌（无 echo 循环）。
4. **身份绑定**：Miro user_id → ezagent user URI + caps，等价 feishu `SenderResolver.resolve`
   （`sender_resolver.ex:39-80`）+ `UserBinding.resolve`（`user_binding.ex:86`）。未绑定 → **扣住 + 提示绑定，不 dispatch**
   （对齐 feishu `{:pending, open_id}` 分支 `inbound_dispatcher.ex:64-76`）。断言：未绑定 Miro 用户的改动不落地。
5. **CapBAC 复核 + 回滚**（P14：入站只走 `Ezagent.Invocation.dispatch/1`）：
   `dispatch` 到 `Ezagent.URI.with_action(mindmap_uri, :mindmap, :<action>)`，`mode: :call` 让 cap-denial 同步返回
   （对齐 `inbound_dispatcher.ex:286-303`、Decision #134）。**Miro 里允许但 ezagent 无权 → 拒绝 + 向 Miro 回推正确状态**
   （ezagent 仍是真相源，connector design `:60-61`）。断言：无权用户在 Miro 的改动被拒 + Miro 被回滚到 ezagent 的正确态。
6. **不静默丢**（P18 + Allen "silent down 不可接受"）：dispatch 失败要有可观测出口（telemetry / 回灌 Miro 提示），
   对齐 feishu 把失败 react/text 回 chat（`inbound_dispatcher.ex:106-171`）。

> 入站真往返的可演示产物 = 一段 stdout：手改 Miro → 轮询日志识别改动 → dispatch 成功/被拒 → `get_tree` 复核树变化或被回滚。

---

## 附 · 关键文件速查

- KIND 轴 + push/pull 契约：`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex:69-316`
- external_mirror 三层设计（publisher/adapter/binding + 生命周期 + 失败语义）：
  `docs/superpowers/specs/2026-05-24-external-mirror-domain.zh_cn.md`
- 出站 Binding 实现样板：`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/feishu_chat_binding.ex`
- 入站全套样板：`inbound_dispatcher.ex` / `sender_resolver.ex` / `user_binding.ex`（同目录）
- Miro 连接器设计（出/入站 + echo + auth 边界）：`docs/superpowers/specs/2026-06-22-mindmap-miro-connector-design.md`
- 现有 Miro REST 客户端：`apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/miro.ex`（凭证读 `:29`）+ `miro/sync.ex`
- 证据写法模板：`docs/superpowers/evidence/2026-06-22-mindmap-{miro-outbound,e2e,increment3}-evidence.md`
- DoD + gate 全集：`.claude/skills/dev-together/references/handoff-standard.md`
