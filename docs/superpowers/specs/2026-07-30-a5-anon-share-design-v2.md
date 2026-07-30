# A5 — 匿名分享（link_anon）接线（v2，去 Mount、对齐 cap-as-truth）

- **status**: proposed — design-first。v1（2026-07-29）基于 `Mount.mount`；本 v2 按 XY 复核后的**确定方向**重写：**不用 Mount**。
- **task**: A5（Group A / URI-share 收尾件）
- **base**: main（A1 #1594 已合）
- **依赖**: A1（`ShareSetting`/`ShareToken`，已合）· `CompositionCaps.mint_cap`（发钥匙唯一 chokepoint）· 现成 anon infra（`Installation.anon_view_caps`/`AnonAdmission`）

---

## 0. 方向定论（为什么 v1 错了）

v1 用 `Ezagent.Socialware.Mount.mount/6` 把 R 挂进匿名 session。**这与 infra 方向相反、要被删**：

- kanban #1474（`feat/kanban-collab-round2`，commit `4c1550eca`）的 thesis = **Mount + MountRow 整删**：「发钥匙统一走 `CompositionCaps.mint_cap`（不落表，cap 自身 durable）、撤销走 `revoke_all_to`、可见性/access 从 cap 反推」。**MountRow 是"第二真相源"、多余**（reconcile 从它重铸会复活被撤钥匙）。这条 refactor 正是**建在 URI-share/cap-as-truth infra 之上**、证明业务插件能纯化到这套 infra。
- 且 **A5 的匿名 view 权限本来就不从 Mount 来**——从 `Installation.anon_view_caps/1`（`installation.ex:315`，按 session 已装 definition 声明的 views 派生 `<view>_render` cap）。Mount 那步是多余的误解。

→ **A5 锚在 cap-as-truth 方向本身**：`mint_cap`（发）+ `anon_view_caps`（匿名 view，definition 派生）+ `revoke_all_to`（撤）。**不碰 Mount/MountRow。**

## 1. 定位（A1 两层的匿名档）

| 档 | 谁能进 | 拿到什么 | 机制 |
|---|---|---|---|
| `link_login` | 登录用户持链接 | 具名 person cap（活现算 `shared_to?`，A1 已做） | ShareToken + `/socialware/claim` |
| `link_anon` | 任何人（匿名） | **view-only 渲染** | **本设计 A5** |

**link_anon 不用 ShareToken**（那是具名档的）。匿名档 = 复用现成 `web_anon_access` publish + `AnonAdmission`（anon 只拿 `<view>_render` cap = 只读结构性）。

## 2. 现成机制（全复用，file:line）

- `Installation.web_anon_access?/1`（`installation.ex:285`）= session 上任一已装 definition `visibility_policy.web_anon_access==true` 即公开。
- `Installation.anon_view_caps/1`（`installation.ex:315`）= 按 public definition 声明的 views 派生 `<view>_render` cap（`installation.ex:335` `cap(:session, view_module, action, instance, ws)`）。**anon 只拿 render cap、永不 operate**。
- `AnonUser.mint_for_public_session/1`（`anon_user.ex:118`）门口查 `web_anon_access?`，anon born with `join_cap` + `anon_view_caps`。
- `AnonAdmission.admit_anonymous_participant/2`（`anon_admission.ex:28`）：mint anon → spawn → bind → join。
- `SessionInstaller.install/…`（装 definition）；`AnonIngress`（web 匿名入口）；`AnonUser.GC`（回收）。
- **`CompositionCaps.mint_cap/4`**（`composition_caps.ex`，发钥匙唯一 chokepoint，granter = target data_owner）—— Mount 删后**它是唯一"发指向 R 的 cap"的路**。
- **撤销** = `Cap.revoke_all_to/2`（cap-epoch generation bump，#1470 unmount 作废）。

## 3. link_anon 全流程（去 Mount 版）

**A. owner 开启**（`ShareSetting.enable(R, owner, behavior, actions, visibility: :link_anon)`，现 fail-closed，A5 接通）：
1. 验 owner（A1 `assert_current_owner`：owner ≡ R 当前 data_owner）。
2. **幂等 provision 专属公开 session `S_R`**（`session://<workspace_of(R)>/anon-share/<stable_key(R)>`，deterministic per-resource → 幂等）。owner = R 的 data_owner（决策 1）。
3. **install 一个 `web_anon_access:true` 的通用 `AnonShareView` definition 进 S_R**，声明 R 的 behavior 的**只读 view(s)** → S_R 成 anon-public，`anon_view_caps(S_R)` 会给 anon 这些 render cap。
4. **让 R 在 S_R 内可读**：用 `CompositionCaps.mint_cap`（granter = R 的 data_owner）铸一个**只读** cap（`access: :read`）让 S_R 的渲染路能读 R 的 slice——**这一步取代 v1 的 Mount，走唯一发钥匙 chokepoint、cap 自身 durable、不落任何 MountRow**。（**开放细节**见 §4 决策 4：读 cap 的 holder 是 S_R 自身 principal 还是随 anon born-with，待实现期实证 render 授权路 `SessionView.authorize_view/3` 要谁持 cap。）
5. `ShareSetting` 记 `visibility=link_anon` + `anon_session_uri=S_R`，返回 `{:ok, %{share_url: anon_ingress_url(S_R)}}`。

**B. 匿名访客**（`GET <anon_ingress_url(S_R)>`）：走现成 `AnonIngress` → `AnonAdmission.admit_anonymous_participant(S_R)` → mint read-only anon（born with join + `anon_view_caps`）→ **只看到 R 一个资源只读**，天然隔离（每资源自己的分享页）。零新匿名代码。

**C. owner 撤销**（`ShareSetting.disable(R)` / visibility 改回）：**`Cap.revoke_all_to`** 撤掉 §3-4 铸的读 cap（cap-epoch）+ 退休 S_R + `AnonUser.GC` reap S_R 的 anon。**不 unmount**（无 MountRow 可 unmount）。

## 4. 待定案决策（交 Allen）

1. **S_R owner = R 的 data_owner**（推荐；分享是 owner 行为，撤销/GC 归 owner）vs 系统 principal。
2. **workspace = `workspace_of(R)`**；不跨 workspace。
3. **`AnonShareView` view 集**：behavior 静态声明可匿名 view（推荐）vs enable 按 actions 参数化。
4. **§3-4 读 cap 的 holder**：S_R 自身 principal 持（渲染以 session 身份读 R）vs 随 anon born-with。实证 `SessionView.authorize_view/3` + `anon_view_caps` render 路要谁持 cap 后定。（约束：一律 `mint_cap`，绝不 Mount。）

## 5. 安全 / 对齐

- 只读结构性（anon = read-only + 只 `anon_view_caps` render，永不 operate）；隔离结构性（每资源专属 S_R）。
- **发/撤全走 cap-as-truth**：`mint_cap`（唯一 chokepoint，granter = data_owner）+ `revoke_all_to`（generation），零 MountRow → 与 #1474 方向一致，不制造第二真相源。

## 6. DoD

- `enable(link_anon)` provision S_R + install AnonShareView + `mint_cap` 只读 cap + 记 anon_session_uri，返 share_url。
- 匿名访客经 AnonIngress **只看到 R 只读**、看不到别的资源（隔离 e2e）。
- `disable`/R 删 → `revoke_all_to` 撤读 cap + S_R teardown + anon reap（撤销 e2e）。
- anon 永远拿不到 operate cap（安全回归）。
- **零 `Mount`/`MountRow` 引用**（grep 回归，锁死方向）。
- 闸 + per_tenant（若 S_R/AnonShareView 加表）全绿。

## 7. 依赖与次序

A1（已合）；`mint_cap`（在）；anon infra（在）。**A4 Mount 已从依赖里移除**（v1 曾依赖，v2 去掉）。impl 前建议先做 §4-4 的 render-授权实证，定读 cap holder。
