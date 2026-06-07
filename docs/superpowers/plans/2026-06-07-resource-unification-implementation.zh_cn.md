# Resource-unification — 实施计划 (P0–P3, Codex 交接)

> **致 agentic worker:** 必需子技能 —— 在改动任何 `apps/**/*.ex` 之前加载
> `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`,并按
> `superpowers:executing-plans` / `superpowers:test-driven-development` 逐任务执行。
> 步骤使用复选框 (`- [ ]`) 语法。**本计划可由 Codex 在 loose-audit 交接模式下自主执行**
> (作者负责 review + E2E + 提 issue)。P0 / P0.5 / P1 / P3 绿灯自合;**P2 由 Allen 把关 —— 禁止自动合并。**

日期: 2026-06-07
分支(本计划): `plan/resource-unification`
SPEC: `docs/superpowers/specs/2026-06-07-resource-unification-spec.md` (已批准, 已锁定)
SPEC (zh): `docs/superpowers/specs/2026-06-07-resource-unification-spec.zh_cn.md`
英文计划: `docs/superpowers/plans/2026-06-07-resource-unification-implementation.md`

---

## 目标

将**租户作用域、内容形态的工件**的磁盘寻址统一到 `Ezagent.UriQuery` 接缝之后,复用现有的
`resource://<ws>/<type>/<name>` scheme,并**锁死裸 `Home.path` 表面**以防迁移回退。
`Ezagent.Home` 退化为加固解析器背后的**默认后端**——不再是前门。启动 / config-eval /
operator mix-task / OS 句柄工件(db、cookie、pty-pids、codex socket)保留在受认可的
裸 `Home`(精确锚点扫描豁免)。

## 架构

`ezagent_core` 新增模块 `Ezagent.Resource.FsResolver`,泛化已验证的 socialware 模式
(`config_projection.ex` 的 `assert_workspace_authority!/2`):**封闭的 per-`<type>` 白名单**、
`Path.join` **之前**拒绝 `.`/`..`/分隔符/NUL、以及**携带授权**的 `resolve(uri, scope)`——
在任何后端解析**之前**运行 per-`<type>` 的 `authority/2`,断言 `uri.<ws> == scope.workspace`。
`mix ezagent.uri_query.scan` 新增扫描门类 `home_path_in_runtime_code`,针对行锚定基线 +
**精确 `Module.function/arity`** 豁免(无通配符)**硬失败新增**的运行时应用代码 `Home.path` 调用。
两个剩余租户作用域族按风险升序迁移:**per-agent config-dir**(P1,字节一致),然后是
**uploads**(P2,先做下载契约 + 签名 token 授权,再搬字节)。P3 把基线烧到空。
凭据 cascade / `Ezagent.Agent.Materializer` 热路径**不动**(解析后传值)。

## 技术栈

Elixir/OTP umbrella。`Ezagent.UriQuery`(ETS `attr → resolver/1`,`{:no_resolver,_}` 大声失败,
`:none ≠ {:error,_}`)。`Ezagent.URI`(6-scheme 白名单,workspace-first 的
`resource(ws, type, name)`,3 段权威)。`Ezagent.Home`(EZAGENT_HOME 路径助手)。
`Ezagent.UriQuery.Scan` + `Mix.Tasks.Ezagent.UriQuery.Scan`(AST/文本扫描器,已解析
`--fail-category`)。测试:resolver + scanner 用 `EzagentCore.DataCase` / 纯 `ExUnit`;
uploads 用 Phoenix controller 测试。签名 token(P2):`Phoenix.Token` / `Plug.Crypto`
对 URI + TTL 做 MAC。

---

## 文件结构(创建 / 修改)

```
apps/ezagent_core/
├── lib/ezagent/resource/fs_resolver.ex                       ← 新增 (P0) 通用 resource:// FS 解析器
├── lib/ezagent/uri_query/scan.ex                             ← 改 (P0.5) 加 home_path_in_runtime_code 门类
├── lib/ezagent/uri_query/scan/home_path_exceptions.ex        ← 新增 (P0.5) 精确 Module.function/arity 锚点
├── lib/ezagent/uri_query/scan/home_path_baseline.ex          ← 新增 (P0.5) 行锚定烧减基线
├── lib/ezagent/sandbox/config_dir.ex                         ← 改 (P1) 构造+解析 resource:// URI
└── test/ezagent/{resource/fs_resolver_test.exs,
                  uri_query/scan_home_path_test.exs,
                  sandbox/config_dir_parity_test.exs}          ← 新增 (P0/P0.5/P1)

apps/ezagent_domain_instance_message/.../uri_query_resolvers.ex ← 改 (P1) 重指 resource 子句
apps/ezagent_plugin_liveview/.../admin_live.ex                  ← 改 (P2b) 经解析器写入
apps/ezagent_web/lib/ezagent_web/uploads/upload_token.ex        ← 新增 (P2a) 签名 token 铸造/校验
apps/ezagent_web/.../controllers/uploads_controller.ex          ← 改 (P2) token + ws 段授权,经解析器读
apps/ezagent_web/.../router.ex                                  ← 改 (P2a) token 路由(+ 兼容窗口)
docs/superpowers/plans/2026-06-07-resource-unification-implementation{,.zh_cn}.md
```

---

## 仓库事实(在 `origin/spec/resource-unification` 上核实,避坑)

- `Ezagent.UriQuery.register/2` 要求 **1 元** resolver(`is_function(resolver, 1)`),且每 attr 单一所有者
  (`:ets.insert_new`)。`resolve/2` 归一化 `{:ok,_} | :none | {:error,_}`,否则 `{:invalid_resolver_return,_}`。
  `{:no_resolver,_}` 大声失败。**因此 `FsResolver` 是普通模块 API,不是 `UriQuery` attr**——它取 2 个参数
  `(uri, scope)`;`:config_dir` 所有者通过把 `{uri, scope}` 作为 1 元载荷委派给它(P1)。
- `Ezagent.URI.resource(ws, type, name)` 是 **workspace-first** 的——经 `per_tenant/4` → `segment!/1`
  (`uri.ex:425,456-477`)。`segment!/1` 拒绝空段 + 含 `/` 的段;`validate_3seg_shape!/2` 拒绝空 `<ws>` host
  (`uri.ex:490-495`)——**但二者都不拒绝 `.`/`..`/NUL,且 `<type>` 无约束。** 这是 codex-HIGH 缺口,
  P0 在解析器里关闭(不动 `URI`,避免触碰 6-scheme 核心)。
- 访问器:`workspace_name/1`、`type/1`、`name/1` 返回 `{:ok, str}` | `:error`(`uri.ex:697,741,768`);`new!/1` 解析字符串。
- `EzagentDomainInstanceMessage.UriQueryResolvers.resolve_config_dir/1` 是 **唯一 `:config_dir` 所有者**;
  其 `resource` 子句委派给 `Ezagent.UriQuery.resolve(:socialware_config_dir, resource_uri)`
  (`uri_query_resolvers.ex:105-107`)。P1 重指此子句;socialware 自己的解析器
  (`config_projection.ex:130`,attr `:socialware_config_dir`)不动。
- `Ezagent.Sandbox.ConfigDir.path/2`(`config_dir.ex:30-36`)算出 **裸**
  `Path.join([Home.path("<ns>-agents"), <ws>, <name>])`;docstring 保证 `"cc"` 字节一致布局。
  cascade 调 `UriQuery.resolve(:config_dir,…)`——但对 `entity`/`template` URI 返回**已存**字符串,
  故 cascade 不受 `resource` 迁移影响(D4)。
- uploads 写:`admin_live.ex:701` `mkdir_p(Home.path("uploads"))`,`:731`
  `Path.join(Home.path("uploads"), stored_name)`(仅文件名,**无 `<ws>`**);句柄在 `:734` 经
  `URI.resource(workspace_name, :uploads, stored_name)` 铸造(装饰性)。读:`uploads_controller.ex:108`,
  授权 `caller_in_attaching_messages?/2`,路由 `GET /files/:filename`。
- `Mix.Tasks.Ezagent.UriQuery.Scan` 已按 `Ezagent.UriQuery.Scan.known_categories/0` 解析 `--fail-category`
  (`ezagent.uri_query.scan.ex:64-79`);把门类原子加入 `@known_categories`(`scan.ex:28-37`)即可立即使用。
  `@default_globs = ["apps/**/*.ex"]`——故 `config/runtime.exs` / `config/dev.exs` **不在扫描范围**
  (无需为其设豁免;在异常模块里仅为完整性列出)。
- **不变量 CI 门:** `mix ezagent.check_invariants` 与 `mix ezagent.check_invariants.lifecycle`。每个 PR 都保持二者绿灯。

---

## 锁定契约(不再争论——SPEC 已批准)

1. `FsResolver` **仅注册**,**封闭 per-`<type>` 白名单**;未注册 `<type>` 返回 **`:none`**(无隐式 Home 兜底,R-1)。
2. `resolve/2` **携带授权**:**无 `resolve/1`** 跳过权威。`scope.workspace` 始终来自调用方已认证上下文,
   **绝不**来自被解析的 URI(R-3)。
3. 不安全段拒绝发生在**任何 `Path.join` 之前**(R-2)。`Home.path` 仅在成功路径上以注册的 `backend_component` 触达(R-4)。
4. P0 注册**零**真实类型(休眠);P1 加 config-dir;P2b 加 uploads。
5. 扫描门从落地 PR 起**硬失败新增**(无 warn-then-flip);豁免是**精确 `Module.function/arity` 锚点——无通配符、无目录前缀**;
   基线**只缩不增**(S-1..S-3)。
6. **D4 —— 不动**凭据 cascade / `Ezagent.Agent.Materializer` 热路径。解析后传值;绝不把 URI 推进去。
7. **P1 路径与今日 `Sandbox.ConfigDir.path/2` 输出字节一致。**
8. **无 `home://`(第 7 个 scheme)。** 不迁 db/cookie/pty/codex-socket。

---

## Codex 协同(对齐 #25 unify-uri-query 协议)

- **每阶段一个 `resource-unification` tracking issue**(`gh issue create`,标签 `resource-unification`):
  P0、P0.5、P1、P2、P3——各链接本计划 + 其 SPEC 节。P2 的 issue 标题前缀 **`[Allen-gated]`**。
- **每阶段一个 PR**,PR body 里写明该阶段的**验收门**,从 `origin/main` 拉分支。
- **每个 PR 运行 `/codex:adversarial-review`**(static-only,跳过 mix —— `feedback_codex_companion_no_mix`:
  companion 的 `MIX_HOME` 无依赖)**+** 扫描门(P0.5 起 `--fail-category home_path_in_runtime_code`)**+**
  `mix ezagent.check_invariants` **+** `mix ezagent.check_invariants.lifecycle`——全绿。
- **自合策略(loose-audit):** **P0 / P0.5 / P1 / P3 绿灯可自合。** **P2 留给 Allen**——开 PR、跑全门绿、
  请 Allen review、在 PR + 飞书贴 `[Allen-gated]` 提示,然后**停**。
- **仅 TEST DB。** 绝不对 dev/prod 跑 `mix ecto.migrate`;绝不碰 dev/prod docker。绝不在 live 节点做 hack。
- **Codex 子步骤粒度**(`feedback_codex_substeps_not_whole_prs`):若 Codex 把整 PR 任务孤儿化,
  作者拥有该 PR 并把有界可验证的子步骤交给 Codex;绝不卡住。

---

## P0 — 加固的通用 `resource://` FS 解析器(仅注册)

**Issue:** `resource-unification: P0 generic FS resolver`。**绿灯自合。**

- [ ] **P0.1** 失败测试:未注册类型 → `:none`(R-1)。新建 `fs_resolver_test.exs`(英文版含完整测试代码)。
  跑 `cd apps/ezagent_core && MIX_ENV=test mix test test/ezagent/resource/fs_resolver_test.exs` → **预期失败**(模块不存在)。
- [ ] **P0.2** 最小实现:`fs_resolver.ex`(ETS per-`<type>` 注册表 + SPEC §5.1 解析算法 1–5 步;
  英文版含完整源码)。跑测试 → R-1 通过。`mix format`。
  > Codex 注:P0 用懒建 ETS 即可(休眠+测试驱动);P1 注册真实类型时把建表移到 `EzagentCore.EtsOwner`(标为 P1 子任务)。
- [ ] **P0.3** 失败测试:R-2 遍历/NUL/分隔符在任何 FS 触达前拒绝(用裸 `%URI{}` 构造,绕过 `segment!`)。**预期全绿。**
- [ ] **P0.4** 失败测试:R-3 权威(`uri.<ws> != scope.workspace` 大声失败,非 `:none`;`refute resolve/1 存在`)+ R-4 成功路径 +
  完整性不变量(每个已注册类型都有 `authority/2`)。**预期全绿。** 提交:`feat(resource): hardened registration-only resource:// FS resolver (P0)`。

**P0 验收门:** R-1..R-4 绿;无生产调用点使用解析器(休眠);`check_invariants(.lifecycle)` + 既有 `uri_query.scan` 不变且绿;
`/codex:adversarial-review` 干净。**自合。**

---

## P0.5 — 扫描门脚手架:`home_path_in_runtime_code`(硬失败新增 + 基线)

**Issue:** `resource-unification: P0.5 home_path scan gate`。**绿灯自合。**

- [ ] **P0.5.1** 精确锚点豁免模块 `home_path_exceptions.ex`(每条 `{path, "Module.function/arity", line, reason}`,
  **绝无通配符/目录前缀**;含 `any_glob_or_prefix?/0` 供 S-2 守卫)。
  > Codex 机械子任务:从活树枚举 operator mix-task 锚点(`Mix.Tasks.Ezagent.Home.Init.run/1` 等,SPEC §5.2 表),每个调用点一个精确锚点。
- [ ] **P0.5.2** 行锚定基线 `home_path_baseline.ex`(`grep` 普查减去豁免;每条 `{path, line, call}`)。
  > Codex 子任务:落地前在 PR 分支重跑普查,行号必须与活树一致。
- [ ] **P0.5.3** 失败测试 S-1:fixture 中的新增未基线化 `Home.path` 调用被标 `:home_path_in_runtime_code`。**预期失败**(门类尚未注册)。
- [ ] **P0.5.4** 实现:`scan.ex` 加门类原子 + AST 查找(匹配 `Ezagent.Home.path|profile_dir|home`,
  含 `alias Home` 形式——按 `List.last(mods) == :Home and fun in [:path,:profile_dir,:home]`);减去基线 + 豁免。**预期通过。**
- [ ] **P0.5.5** S-2(豁免皆精确锚点,无通配符)+ S-3(活树绿:基线+豁免覆盖所有调用点)。**预期全绿。**
- [ ] **P0.5.6** 把 `mix ezagent.uri_query.scan --fail-category home_path_in_runtime_code` 接入 CI(task 已支持该 flag,无需改 task 代码)。
  提交:`feat(scan): home_path_in_runtime_code hard-fail-new gate + baseline (P0.5)`。

**P0.5 验收门:** 新门类在当前树绿(S-3);故意加未基线化调用变红(S-1);豁免皆精确锚点(S-2);CI 已接入;`check_invariants(.lifecycle)` 绿;`/codex` 干净。**自合。**

---

## P1 — 把 per-agent config-dir 迁到经 `resource://<ws>/<config-type>/<name>` 解析

**Issue:** `resource-unification: P1 config-dir via resolver`。**绿灯自合。**(config-dir 先于 uploads:正是 cascade 上已有的 socialware 接缝形态;风险更低;cascade 已 URI 化,D4。)

- [ ] **P1.1** 失败测试:字节一致 parity(钉住当前精确输出 `Home.path("cc-agents")/<ws>/<name>`)+ foreign-`<ws>` 权威大声失败。
  parity 在当前实现上**应通过**(基线);权威测试**失败**(类型未注册)。
- [ ] **P1.2** 注册 config-dir 类型 + 把 `FsResolver` 建表移到 `EzagentCore.EtsOwner`;在 `application.ex` 启动期为在用命名空间(`cc`、`codex`…)注册 `"<ns>-agents"`,`backend_component` = `"<ns>-agents"`(保字节一致)。
- [ ] **P1.3** 重写 `config_dir.ex:30-36` 经接缝构造+解析;`scope.workspace` = agent 自身权威 workspace(cascade 的已认证主体,非攻击者提供)。**字节一致 → parity 保持绿。**
- [ ] **P1.4** 重指 `uri_query_resolvers.ex:105-107` 的 `resource` 子句:先试通用 `FsResolver`,`:none` 回落到 `:socialware_config_dir`;`{:error,_}` 传播不吞。
  > Codex 注(D4 守卫):不改 `cascade_runtime.ex` / `materializer.ex`;PR 清单断言这两文件 0 改动行。
- [ ] 从基线移除 `config_dir.ex:32`;把 `fs_resolver.ex` 加入扫描器 `@default_excluded_paths`(它是解析器本体)。
- [ ] **P1.5** 跑 parity + resolver + 既有 config_dir/cascade 测试 + 扫描门(基线已缩)。提交:`feat(resource): per-agent config-dir resolves via resource:// seam, byte-identical (P1)`。

**P1 验收门:** parity 绿;foreign-`<ws>` 权威大声失败;cascade/Materializer 测试不变且绿(`git diff` 这两文件 0 行——D4);基线缩 1;config-dir 的 `Home.path` 调用从运行时应用代码消失;`check_invariants(.lifecycle)` 绿;`/codex` 干净。**自合。**

---

## P2 — 把 uploads 迁到经解析器 STORE —— 先做下载契约  ⚠️ ALLEN 把关

> **🔒 ALLEN 把关 —— 禁止自动合并。** 开 PR、跑全门绿、请 Allen review、在 PR + 飞书贴 `[Allen-gated]` 提示,然后**停**。本阶段改动安全边界(下载授权 → 签名 token)。

**Issue:** `[Allen-gated] resource-unification: P2 uploads via resolver + signed token`。

> **契约变更先于字节搬迁**(SPEC §6 P2)。今日字节落 `Home.path("uploads")/<stored_name>`(仅文件名,**无 `<ws>`**),`show/2` 按 session 参与授权(非按 `<ws>`)。

### P2a — 下载契约 + workspace 段授权(暂不搬字节)

- [ ] **P2a.1** 失败测试:签名 token 的 TTL/绑定/重放/过期(`upload_token_test.exs`,英文版含完整代码)。**预期失败**(模块不存在)。
- [ ] **P2a.2** 实现 `upload_token.ex`:`Phoenix.Token.sign/verify`,`max_age` = TTL,载荷 = URI stable key;短 TTL(默认 5 分钟),绑定单一 URI,授权后才铸造,MAC 签名。**预期通过。**
  > Codex 注 TTL:让 `mint!(ttl: -1)` 的过期测试确定性通过;记录所选方案。
- [ ] **P2a.3** 在 `FsResolver` 注册 `uploads` 类型(后端 `"uploads"`,`authority/2` = `uri.<ws> == scope.workspace`)。
- [ ] **P2a.4** 铸造时授权 + serve 时重校验:内部(operator/session)铸造时活 cap 检查;外部 customer-feed(#601/#603,无 session/caps 的访客)按 **approved-only** 可见性把关;serve 时(a)校 token(MAC+TTL),(b)取出绑定 URI,(c)以 request-mount scope 跑 `authority/2`,(d)feed 重确认仍 approved(TTL 之外的撤销杠杆)。
  并修文档漂移(SPEC §6 P2a):`capability.ex:556` / `admin_live.ex` 注释把 `resource://<type>/<workspace>/<name>` 改为 workspace-first。
- [ ] **P2a.5** `GET /files/:filename` 兼容窗口(唯一受认可的 shim,N6)+ 新 token 路由并存;测同名两 workspace。提交:`feat(uploads): signed-token download contract + ws-segment authz, doc-drift fix (P2a)`。

### P2b — 经解析器搬字节

- [ ] **P2b.1** 失败测试:同名两 ws 隔离 + foreign-ws 拒绝(403) + 往返 + 兼容链接窗口内可解析。**预期失败。**
- [ ] **P2b.2** 写:`admin_live.ex:701,731` 改为经 `FsResolver.resolve(...)` → `{:ok, dest}`(`mkdir_p(dirname)` + `cp!`);读:`uploads_controller.ex:108` 改为校 token 后经解析器,保留既有 `safe`/`.`/`..` 守卫作纵深防御。从基线移除三处 uploads 条目。**预期通过。** 扫描门绿。提交:`feat(uploads): store+read bytes through resolver, ws-scoped layout (P2b)`。
  > OI-2(已定):解析器返回 **path**(uploads 本就是磁盘文件);仅当出现大上传流式需求再议。

**P2 验收门:** 所有 upload/download 测试绿;授权按 `<ws>` 段(签名 token + 解析器 `authority/2`);token 测试(TTL/绑定/重放/过期)绿;字节落 `…/uploads/<ws>/<name>`;兼容链接窗口内可解析;基线缩 uploads;`check_invariants(.lifecycle)` 绿;`/codex` 干净。**🔒 留给 Allen —— 禁止合并。**

---

## P3 — 烧掉锁死基线

**Issue:** `resource-unification: P3 baseline burn-down`。**绿灯自合。**

> **OI-3(已定):无宽泛豁免;唯一豁免轴是启动顺序,不是"无 `<ws>`"。** 仅当调用方在 SchemeRegistry/UriQuery ETS 表存在**之前**运行(config-eval / pre-`Application.start`)才豁免。其余全走 UriQuery:租户内容 → `resource://<ws>/<type>/<name>`;系统/全局 → **`system://<type>`**(复用 system scheme,仍经 UriQuery——非豁免)。

- [ ] **P3.1** 逐条迁移剩余 population-3 调用:`agent_bridge/token_store.ex:120`(per-agent token,租户)→ `resource://`;`domain/python/server.ex:708`(per-agent log,租户)→ `resource://`;`plugin_feishu` 各处(全局/inbox/插件配置)→ `system://` 或精确锚点豁免(若确属启动顺序);`domain_identity/application.ex:143`(smtp_config)——**核实启动顺序:** 若在 registry seeding 之前于 `Application.start/2` 读凭据,则属真启动顺序豁免(精确锚点+理由),否则迁 `system://`(SPEC §10 OI-3 标记的唯一待核项)。
- [ ] **P3.2** 把已迁条目从 `HomePathBaseline` 移除;真启动顺序/OS 句柄者移到 `HomePathExceptions` 作精确锚点+理由。**目标:`HomePathBaseline.all() == []`。** 更新 S-3 测试断言基线为空(完成不变量)。提交:`feat(resource): burn down home_path baseline to empty; lockdown complete (P3)`。

**P3 验收门:** `HomePathBaseline.all() == []`;剩余运行时 `Home.path` 调用皆已迁或精确锚点豁免(带理由);identity-app 启动顺序已核实+记录;扫描门绿;`check_invariants(.lifecycle)` 绿;`/codex` 干净。**自合。**

### 到此为止。

db / runtime cookie / codex socket / pty-pids 保留在**受认可的裸 `Home`**(D2,精确锚点豁免)。全局凭据延期(D5)。无 `home://`(D3)。

---

## 各阶段 PR 汇总

| 阶段 | PR 范围 | 验收门 | 合并策略 |
|---|---|---|---|
| **P0** | `FsResolver`(仅注册,休眠) | R-1..R-4 绿,无生产调用 | **自合** |
| **P0.5** | `home_path_in_runtime_code` 扫描门 + 基线 | S-1..S-3 绿,CI 接入 | **自合** |
| **P1** | config-dir 经解析器(字节一致) | parity 绿,D4 不动,基线 −1 | **自合** |
| **P2** | uploads:签名 token 契约 + 字节搬迁 | token+ws 授权绿,基线 −uploads | **🔒 ALLEN 把关** |
| **P3** | population-3 烧减 | 基线空,identity 顺序已核实 | **自合** |

每个 PR:`/codex:adversarial-review`(static-only)+ 扫描门 + `mix ezagent.check_invariants` + `mix ezagent.check_invariants.lifecycle` 绿。仅 TEST DB;不对 dev/prod migrate;不碰 dev/prod docker。

## 本计划刻意不碰

- `Ezagent.Credential.CascadeRuntime` / `Ezagent.Agent.Materializer`(`atomic_replace`/rollback/`recover_orphaned`/`copy_secret_relpaths`)—— D4,解析后传值。P1 PR 清单断言此处 0 改动行。
- `Ezagent.URI` 6-scheme 核心 —— `.`/`..` 拒绝在解析器里做,不动 `segment!/1`(避免触碰不变量 #11)。
- db / cookie / pty-pids / codex socket —— 受认可的裸 `Home`(D2)。
- 第 7 个 `home://` scheme(D3);全局凭据(D5)。
