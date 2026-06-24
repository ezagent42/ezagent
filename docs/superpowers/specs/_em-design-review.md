# 对抗式审查：mindmap ↔ Miro external_mirror 设计

> 审查对象：`2026-06-22-mindmap-miro-externalmirror-design.md`
> 立场：对抗式，不因为是设计就放水。逐条对照真实代码（file:line 已复核）。
> 结论先行：**整体方向对，但出站（Phase A）的可行性前提被设计严重低估——`:push` adapter 路径在当前 EM 域里是 session-硬编码的，mindmap 这种非-session Kind 走不通，除非改 EM 域（设计 L8/U1 自己禁止的事）。这不是一个"unverified 角落"，是 Phase A 的地基。**

---

## 判定总表

| 维度 | 判定 | 依据 |
|---|---|---|
| ① 出站"树变→自动推"事件接法是否真存在 | **不成立（设计低估）** | mindmap Kind 当前**不发** publisher event，也**不是** Publisher；要补的不止"实现 4 callback"，而是整条 EM 域的 session 解耦 |
| ② 入站轮询器身份/caps/echo-loop | **基本站得住**，但有 2 个未验 API + 1 个被略过的活体步骤 | `list_caps_for` 真存在；echo-loop 逻辑自洽；但漏了 user Kind auto-spawn |
| ③ DoD e2e 本地可跑性 | **半可跑**：出站被①卡死跑不了；入站可跑但依赖 U2 未实现端点 | — |
| ④ core/world/P14 越界 | **出站必然越界 EM 域**（非 core/world，但仍是设计自己划的红线）；入站 P14 干净 | Gates/Worker/Session.behaviors 全 session 耦合 |
| ⑤ 最大落地风险 | **U1 被低估**：它是 Phase A 的阻塞前提，不是收尾项 | 见下 |

---

## ① 出站：事件接法不存在，且 U1 远比设计说的严重（最关键）

### 1a. mindmap 现在发不发 publisher event？——**不发。而且补法是整条链路改造，不是"加个 impl"。**

- mindmap Kind 用 `use Ezagent.Lifecycle`（`behavior/mindmap.ex:27`），写全走 `commit/1` → `{:set,:tree,_}`（`:404`）。
  Lifecycle 是 `use Ezagent.Behavior` 的薄封装（`lifecycle.ex:16-17`），写 slice **会**触发 core 的 `SliceChange.emit`（`kind/server.ex:727`）。所以"slice 变 → SliceChange 广播"这一截**真存在**。
- 但 SliceChange ≠ Publisher event。EM 域**不订阅 SliceChange**（`behavior/publisher.ex:9-18` 明说："ExternalMirror consumes Publishers; it does NOT directly observe raw SliceChange"）。要让 mindmap 成为 push 源，必须让 mindmap Kind 实现 `@behaviour Ezagent.Behavior.Publisher`——这部分设计认知正确（§2.2）。
- **设计漏的**：Publisher 不是"在 mindmap 里加 4 个函数"。参照实现 `SessionImpl` 是**一个独立的 Kind-Behavior**（`session_impl.ex:1-15`，`use Ezagent.Lifecycle, state_slice: :publisher`），它有自己的 `:publisher` slice、ring、cursor、subscribers/monitors transient、`activated/2` 的 `:publisher_alive` reachability 广播（`session_impl.ex:46-52`）。mindmap 要照搬这一整套 Kind-Behavior + 注册进 `Mindmap.behaviors/0`（现在只有 14 个 action behavior，`application.ex:41-58`，**没有** Publisher）。这是个**新 Kind-Behavior + 一条新 slice**，工作量级远超设计 §2.2 的"照抄"措辞。

### 1b. U1 不是"角落 unverified"，是 Phase A 的硬阻塞——EM 域**全栈** session 耦合

设计 §④ U1 只说"Worker subscribe 把被镜像 Kind 钉成 session_uri + cap 钉死 SessionImpl"。**实测：耦合点不止 Worker，是从 bind facade 到 Worker 到 Gate 到 Session.behaviors 的每一层：**

1. **bind facade 签名就是 session**：`Ezagent.ExternalMirror.bind(session_uri, adapter_id, ...)`（`external_mirror.ex:152`）。设计 §2.7 写 `bind(mindmap_uri, "miro", ...)`——参数位是对的（facade 不强校验 URI 是 session 形状），但下游全按 session 解释。
2. **Gate 1/2 造的是 `kind: :session` cap**：`gates.ex:166`（`check_session_bind_cap` → `kind: :session`）、`gates.ex:210`（`check_adapter_allow_cap` 同样 `kind: :session`）。mindmap 的 cap 是 `kind: :mindmap`（`mindmap.ex:166` `cap(:mindmap,...)`）。**bind mindmap 时这两个 gate 要么查不到 cap 直接 `:unauthorized`，要么得给 mindmap owner 发一个 `kind: :session` 的假 cap**——后者是 cap 模型污染。设计完全没提这层。
3. **Worker 通篇 `:session_uri`**：args key `session_uri`（`external_mirror_worker.ex:178`）、ctx read `:session_uri`（`:362/:397/:696`）、subscribe 目标 `session_uri`（`:872-916`），且 subscribe cap **硬编码** `Ezagent.Behavior.Publisher.SessionImpl`（`:990-993`）+ `granted_by: user(:system,:admin)`。
4. **`:bind`/`:unbind`/Publisher 这套 action 注册在 `Ezagent.Entity.Session.behaviors/0`**（`session.ex:56-60,75-76`），**不是**可插拔的、按被镜像 Kind 动态选的。mindmap Kind 的 `behaviors/0` 里压根没有 `ExternalMirror` / Publisher behavior。

**结论**：设计 L1/§2 把出站描述成"mindmap 实现 Publisher + 写 adapter/binding + 声明 adapters/0 即可"。真实情况是：**要么 mindmap 伪装成 session URI 形状并完整实现 SessionImpl 形状的 Publisher 契约（hacky、且 cap 仍是 `:session` kind 污染），要么把 EM 域从"Session 专用"泛化成"任意 Publisher Kind 可镜像"（改 `external_mirror_worker.ex` 去 session 化、Gate 去 `:session` 硬编码、bind facade 泛化、可能动 `Session.behaviors` 的注册模型）。** 后者就是设计 L8 明令"暂停问 Allen"的"改 external_mirror 域"。**所以 Phase A 在第一步（A2/A3 之前）就撞墙，A5"解决 U1"被排在最后是顺序倒置——U1 必须最先和 Allen 敲定，否则 A2-A4 全部白做。**

> 这一条单独就足以判定：**Phase A 不能按现设计直接开工**。必须先和 Allen 决策 EM 域是否泛化、还是 mindmap 走另一条出站路（例如不复用 EM 域，自己起一个订阅 SliceChange 的进程——但那违反 P11/Publisher 封装，也要 Allen 拍）。

---

## ② 入站：基本站得住，但 3 个细节要补

- **身份/caps 真存在**：`Ezagent.Identity.list_caps_for/1` 真有（`sender_resolver.ex:74` 在用），设计 L4/§3.2 引对了。✔
- **P14 干净**：入站走 `Ezagent.Invocation.dispatch/1`（`invocation.ex:84-88` 存在）+ `with_action` 构造目标，零 PubSub.broadcast 到入站 topic。✔ 这条是设计最扎实的部分。
- **echo-loop 防护逻辑自洽**：last-pushed 基线 + 顺序锁 + no-op 过滤三层，论证成立（§3.3）。但**强依赖出站基线存在**——而出站被①卡死，基线无从产生。所以"入站依赖出站"（L6）在当前状态=**入站也连带阻塞**，除非先用 `miro/sync.ex` 现有的 v1 push（建新板那版）凑一个临时基线，但那版每次建新板（`sync.ex:9`），跟"复用同板"前提冲突。
- **漏掉的活体步骤**：feishu sender_resolver 在读 caps **前**先 `KindRegistry.lookup` + 冷则 `SpawnRegistry.spawn` 把 user Kind 拉活（`sender_resolver.ex:65-72`），否则 `list_caps_for` 返回空集 → 误判 `:unauthorized`。设计 §3.2 只 ensure_live 了 **mindmap** 实例（L7/§3.1 步骤 5），**没 ensure 板 owner user Kind 活体**。冷启动后板 owner user 大概率没被 spawn → caps 空 → 所有入站改动被拒。**必改**。
- **方案 A 的板 owner entity 是否存在（U4）**：真未验，且与上一条叠加——不仅要存在，还要在轮询拍时是活的。

---

## ③ DoD e2e 本地可跑性（有 Miro token、无公网）

- **入站轮询是 GET 拉模型**（`miro.get_nodes`，`miro.ex:68-76` 已实测），**不需要公网回调**——这点设计选对了（对比 feishu webhook 必须公网）。所以"无公网"对入站**不构成阻碍**。✔
- **但 U2 是硬伤**：出站增量 diff 依赖 update/delete/move 三个端点，`miro.ex` 里**确认只有 create_board/create_node/get_nodes，update/delete/move 完全不存在**（grep 零命中）。设计 A1 把"探活 U2"列为 Phase A 第一步是对的，但：experimental 端点若不支持 update/move，fallback=delete+recreate 会丢 miro_id 稳定性 → **直接打穿 echo-loop 防护的"ez_id↔miro_id 映射稳定"前提**（§3.3 基线对比靠映射稳定）。U2 不只是出站问题，它会反噬入站 echo 防护。
- **出站 e2e 跑不起来**：因①，bind mindmap→miro 在 facade/gate/worker 层就过不去。DoD 出站断言 1（"`adapters/0` 声明双向 + 编译期 check 过"）能过，但断言 2-6（真链路走通）全部依赖 U1 先解决。
- **诚实声明 umbrella 既有红**：设计 §⑤ 末尾的处理（本插件绿 + umbrella 编译干净）符合项目惯例，OK。

---

## ④ core/world/P14 越界

- **不碰 core/world**：设计声明的"所有新代码在 plugin_mindmap"——**对入站成立**，**对出站不成立**。出站要么改 `apps/ezagent_domain_external_mirror`（worker/gates/facade），要么改 `apps/ezagent_domain_session`（behaviors 注册模型）。这两个都是 **domain 层**（不是 core/world，所以不直接违反"不碰 core/world"字面），但 §④"所有新代码在 plugin_mindmap"这句**是错的**，且 L8 已自承"改 EM 域要暂停问 Allen"。
- **P14**：入站设计干净。出站 `:publish` 走 Router self-dispatch（`external_mirror_worker.ex:927-953`）也合规——前提是能 bind 起来。
- **system:// north star**：方案 A 不新增 system:// principal，合规。✔（注意 Worker 自身 subscribe cap 仍 `granted_by: user(:system,:admin)`，但那是既有代码、不是本设计引入。）

---

## 必改清单（按阻塞优先级）

1. **【阻塞·先于一切】把 U1 从 §④ 末尾的"unverified 收尾"提到 Phase A **第 0 步**，并明确它是 EM 域级决策**：现设计把"解决 U1"放 A5、A2-A4 在前，顺序倒置。实际必须先和 Allen 敲定：EM 域是否泛化支持非-session Publisher Kind？还是 mindmap 出站不复用 EM 域？**在此决策前，Phase A 的 A2/A3/A4 不应动工**（否则按 session 形状写的 Publisher impl 可能整段重写）。

2. **【阻塞】把"出站 = 纯 plugin 改动、不碰 EM 域"这个前提作废**。设计 §④"所有新代码在 plugin_mindmap"对出站是假的。Gate1/2 的 `kind: :session` 硬编码（`gates.ex:166/210`）、Worker 的 `:session_uri` + SessionImpl cap 硬编码（`:872-993`）、`:bind` 注册在 `Session.behaviors`——任一条都要求改 domain 层。必须如实写明出站的真实 blast radius + 触发 Allen review。

3. **【必改】入站补板 owner user Kind 的活体保证**：抄 `sender_resolver.ex:65-72`——读 `list_caps_for` 前先 `KindRegistry.lookup` 冷则 `SpawnRegistry.spawn(板owner_uri)`。现设计 §3.2 只 ensure 了 mindmap 实例，漏了 user，冷启动必然 caps 空 → 全量 `:unauthorized`。

4. **【必改】U2 端点缺失要前置探活并把"映射稳定性"风险写进 echo 防护**：update/delete/move 在 `miro.ex` 完全不存在；若 experimental 只能 delete+recreate，miro_id 不稳定会同时打穿出站增量 + 入站 echo 基线对比（§3.3 依赖映射稳定）。U2 的结论会决定 echo 防护是否还成立，不能留到 A6。

5. **【建议】入站"依赖出站基线"（L6）在出站被阻塞时的退路**：现 `miro/sync.ex` v1 是"每次建新板"（`sync.ex:9`），与"复用同板做基线"冲突。在出站 U1 未解前，入站拿不到稳定基线，B 阶段也连带阻塞——需要一个临时基线方案或显式承认 A、B 强串行且都卡在 U1。

---

## 一句话给 Allen

设计的**入站**部分（轮询 GET + dispatch + echo 防护 + 身份）工程上扎实、P14 干净、本地无公网可跑；但**出站**部分把"`:push` adapter 复用"想得太轻——当前 external_mirror 域从 bind facade、Gate cap、Worker 到 Session.behaviors 注册是**全栈 session 硬编码**，mindmap 这种非-session Kind 根本插不进去，U1 是 Phase A 的地基阻塞而非收尾项，必须先决策 EM 域是否泛化。
