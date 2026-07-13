# Kanban Chat-Centric 改版 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 把 kanban 改成"chat 中心"模型:plugin 只给 board 工具、sw 自带脑配方(干净参考)、看板可见性按 CBAC 权属收敛、板可在运行时动态授权(解锁 chat 建板 / 装 sw≠板 / 跨房间拉板)。

**Architecture:** main 上授权模型已完整(#1362:owner-gated 精确 operate 边 + consent + `Cap.issue` 可复用 0 core),sw/plugin 分离已做(sw=manifest 经 ezagent_web umbrella `ManifestSeed.scan_all!` 播种)。本改版全是**业务逻辑**:复用现成授权原语,不动 CBAC 核心。

**Tech Stack:** Elixir/OTP umbrella;RecipeRegistry / ManifestSeed(域 session)/ CompositionCaps+Cap.issue(域 session,授权)/ RecipeResolver(域 agent)/ world kanban_data+kanban_render(plugin world)。

## Global Constraints

- mise pin:所有 mix 走 `mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- mix ...`(裸 mix 落 brew OTP28 毁验证)。CI 跑 1.19/OTP28。
- TDD:先写失败测试 → 跑红 → 最小实现 → 跑绿 → commit。
- 改 manifest/baseline 类文件用 Edit 精准替换(不用 sed)+ 全套 arch 重测(`mix test apps/ezagent_core/test/architecture/`)。
- 不撞 gate:I12(cap self-store)/ RF-6(passive 跳 join)/ no-wildcard / arch baseline。授 cap 一律走 `Cap.issue`+absorb。
- 分支 `feat/kanban-progress-board`。每件独立可测、独立 commit。
- 只认真实工具输出,不在真实结果后编内容。

---

### Task 1: 提纯 —— sw 自带 recipe,plugin 只留 board 工具

**Files:**
- Create: `apps/ezagent_web/priv/socialware_seed/kanban/recipes.yaml`(两个脑数据配方)
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex`(`import_manifest_path`:发布 manifest 前注册同目录 recipes.yaml)
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:85`(`roles/0` 删两个脑,只留 `kanban_manager_recipe()`;删 `kanban_assistant_recipe/0`、`dev_together_recipe/0`、两个 persona 函数)
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/manifest_seed_recipes_test.exs`(新)
- Modify test: `apps/ezagent_plugin_kanban/test/kanban_role_test.exs:120-138`(不再断言两个脑在 plugin)

**Interfaces:**
- Produces:两个脑配方(`"kanban-assistant"`/`"dev-together"`)在 boot 后经 sw seed 注册到 `RecipeRegistry`,name-ref 可解析(kanban manifest 发布 conformance #3 通过)。
- Consumes:`Ezagent.Agent.RecipeRegistry.seed_role_if_absent/2`(接受完整 data-role 体:`%{name, skills, prompt, behaviors: [], requested_caps: []}`,有 `validate_data_role_recipe/1`);`ManifestYaml.parse/1`。

- [ ] **Step 1: 写失败测试** —— sw seed 目录带 recipes.yaml,scan 后脑注册可解析。
```elixir
# apps/ezagent_domain_session/test/ezagent/socialware/manifest_seed_recipes_test.exs
defmodule Ezagent.Socialware.ManifestSeedRecipesTest do
  use EzagentCore.DataCase, async: false
  alias Ezagent.Agent.RecipeRegistry

  @tag :integration
  test "sw seed 目录的 recipes.yaml 在 manifest 发布前被注册" do
    dir = Path.join(System.tmp_dir!(), "sw_seed_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    sw = Path.join(dir, "demo-team"); File.mkdir_p!(sw)
    File.write!(Path.join(sw, "recipes.yaml"), "recipes:\n  - name: demo-brain\n    skills: [demo-skill]\n    prompt: \"demo brain\"\n")
    File.write!(Path.join(sw, "manifest.yaml"), "name: demo-team\nversion: \"0.1.0\"\nbases: [Ezagent.ActionSet.Session]\nroles:\n  - {role_name: brain, fill: agent, recipe: demo-brain, flavor: cc-headless}\n")
    Ezagent.Socialware.ManifestSeed.scan_dir!(dir, deploy_dir: dir)
    assert {:ok, %{name: "demo-brain"}} = RecipeRegistry.lookup(Ezagent.URI.workspace(:system), "demo-brain")
  end
end
```
- [ ] **Step 2: 跑红** — `mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- mix test apps/ezagent_domain_session/test/ezagent/socialware/manifest_seed_recipes_test.exs` → FAIL(recipes.yaml 未读,demo-brain 未注册)。
- [ ] **Step 3: 最小实现** — `import_manifest_path` 的 with 链首加 `:ok <- seed_sibling_recipes(path)`:
```elixir
defp seed_sibling_recipes(manifest_path) do
  rp = Path.join(Path.dirname(manifest_path), "recipes.yaml")
  with true <- File.exists?(rp),
       {:ok, yaml} <- File.read(rp),
       {:ok, %{"recipes" => list}} when is_list(list) <- Ezagent.Socialware.ManifestYaml.parse(yaml) do
    Enum.each(list, fn r ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(%{
        name: r["name"], skills: r["skills"] || [], prompt: r["prompt"] || "",
        behaviors: [], requested_caps: []})
    end); :ok
  else
    false -> :ok
    {:error, reason} -> raise "recipes.yaml seed failed #{rp}: #{inspect(reason)}"
  end
end
```
并 Create kanban `recipes.yaml`(把 application.ex:112/135 两个脑体+persona 全文搬进去);Modify application.ex:85 `def roles, do: [kanban_manager_recipe()]` + 删两个脑函数+persona 函数。
- [ ] **Step 4: 跑绿 + kanban 套件** — `mix test apps/ezagent_domain_session/test/ezagent/socialware/manifest_seed_recipes_test.exs apps/ezagent_plugin_kanban/test`(新绿;kanban 仍 87/0,改 kanban_role_test.exs:120-138 断言)。
- [ ] **Step 5: 全套 arch + commit** — `mix test apps/ezagent_core/test/architecture/`;`git commit -m "refactor(kanban): sw 自带脑 recipe,plugin 只留 board 工具"`。

---

### Task 2: 发现按 cap 收敛 + admin 视图

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex:78`(`list_instances/1` 加 cap 过滤)
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban_render.ex`(`boards_for/1` 同款收敛,穿 caller)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/kanban_data_scope_test.exs`(新)

**Interfaces:** Consumes `Ezagent.Identity.list_caps_for/1` / `CapabilityRegistry.data_owner_of/2` / `AdminAuthority.admin?/2`(authority.ex:108)/ `ctx[:caller_uri]`/`ctx[:caller_caps]`。Produces:`list_instances(ctx)` 只返回 caller own/持 board cap 的板;admin 返回全 ws。

- [ ] **Step 1: 失败测试** — 非 admin 只见 own,admin 见全部(board/ctx 造法照 kanban_data 现有测试)。
- [ ] **Step 2: 跑红** — `mix test .../kanban_data_scope_test.exs` → FAIL(现 fail-open)。
- [ ] **Step 3: 实现**:
```elixir
def list_instances(ctx) do
  "kanban-manager"
  |> Ezagent.Agent.RecipeResolver.list_by_recipe(workspace_scope(ctx))
  |> Enum.filter(&visible?(&1, ctx))
  |> Enum.map(fn %URI{} = uri -> %{"uri" => encode_uri(uri), "name" => uri_name(uri), "path" => detail_path(uri)} end)
rescue _ -> [] end

defp visible?(board_uri, ctx) do
  caller = ctx[:caller_uri]; caps = ctx[:caller_caps] || MapSet.new()
  Ezagent.AdminAuthority.admin?(caller, caps) or owns_or_holds_cap?(caller, caps, board_uri)
end
```
`owns_or_holds_cap?`:`data_owner_of(Ezagent.ActionSet.Kanban, instance(board_uri)) == caller` OR caps/`list_caps_for` 里有 cap 实例指向该 board。`boards_for/1` 同穿 caller。
- [ ] **Step 4: 跑绿** — `mix test apps/ezagent_plugin_world/test apps/ezagent_plugin_kanban/test`。
- [ ] **Step 5: commit** — `git commit -am "feat(kanban): 看板发现按 CBAC 权属收敛(非 admin 只见有权,admin 见全 ws)"`。

---

### Task 3: 运行时"发钥匙"业务函数(解锁 4/5)

**Files:** Create `apps/ezagent_domain_session/lib/ezagent/socialware/board_grant.ex`;Test `.../board_grant_test.exs`。

**Interfaces:**
- Produces:`Ezagent.Socialware.BoardGrant.grant(assistant_uri, board_uri, opts)` → 给 assistant 铸指向 board 的 `kanban.<action>` operate cap(默认全 20 动作 / `opts[:actions]` 指定),granter=板 `data_owner_of`(走 consent),`{:ok, minted}`/`{:error, reason}`。**0 行 core**:内部 `Cap.issue({:held_by, owner}, assistant_uri, cap)` + `Identity.absorb_cap`,或 `GrantRecipeCaps.grant_recipe_caps/4` instance_overrides `%{Ezagent.ActionSet.Kanban => board_uri}`。
- Consumes:`CapabilityRegistry.data_owner_of/2`、`Cap.issue/3`、`Identity.absorb_cap/2`、`URI.instance/1`。
- 越权保证:cap 实例精确;dispatch step 5.5 天然拒别的 board。

- [ ] **Step 1: 失败测试** — grant 后 assistant 持该 board operate cap;dispatch 到该 board 成功、到无关 board 拒(造法照 `grant_recipe_caps_board_scope_test.exs`)。
- [ ] **Step 2-5**:跑红 → 实现 BoardGrant.grant → 跑绿 + **invariants(I12 `cap_self_store_paradigm_lock` 绿)** → commit。
> 这一件落地上一轮终验说的"运行时入口"(0 core),同时补上缺的单条跨-instance dispatch e2e。

---

### Task 4: chat 建板 + 装 sw ≠ 自动生板(依赖 Task 3)

**Files(接口定死,精确 TDD 步骤在 Task 3 `BoardGrant.grant/3` 签名落地后展开):**
- Modify: kanban `manifest.yaml`(删 `board` role slot + assistant 20 条 `operates` 边 → 装 sw 不自动生板/install 期铸 cap)
- Create/Modify: "建板" orchestrator/assistant 可 dispatch 动作(包 `Workspace.create_agent(role: "kanban-manager", flavor: native)`,现只在 world `kanban_actions.ex:277`)
- 建板成功后调 `BoardGrant.grant(assistant_uri, new_board_uri)`(Task 3)

**Interfaces:** Consumes `BoardGrant.grant/3`(T3)、`Workspace.create_agent/3`。Produces:装 kanban-team 只出脑;chat 建板 → board + 当场发钥匙。关键:assistant board cap 从 install 期铸 → 建板后动态铸。

- [ ] 步骤(T3 后补):① manifest 删 board role+operates(Edit+arch 重测)② 建板动作(测:chat 建板 → board 存在 + assistant 持该板 cap)③ 装 sw e2e(测:只出 assistant+dev-together 无 board;建板后能操作)。

---

### Task 5: 跨房间拉看板(依赖 Task 3)

**Files(接口定死):**
- Create/Modify:"引入看板"动作 —— 从 Task 2 收敛列表挑一块**已存在**的 board → `BoardGrant.grant(this_session_assistant, chosen_board)`(板主人 consent)。跨 session:board_uri 是别 session 的板,同 workspace 可寻址。

**Interfaces:** Consumes `BoardGrant.grant/3`(T3)+ T2 收敛列表。Produces:session B assistant 持指向 session A board 的 operate cap → 能操作(跨 session 共享,board 不进群、URI 寻址)。

- [ ] 步骤(T3 后补):① 引入动作(测:挑别 session 板 → 本 session assistant 持该板 cap)② 跨 session dispatch e2e ③ 越权(没引入的板拒)。

---

## Self-Review

- **Spec coverage**:提纯 T1 / 发现收敛+admin T2 / 发钥匙 T3 / chat 建板+装 sw≠板 T4 / 跨房间拉板 T5 —— 齐。
- **依赖链 / 执行序**:T3 是 T4/T5 地基;T1/T2 独立。序 = T1→T2→T3→T4→T5。
- **无占位**:T1-T3 完整测试+实现;T4-T5 精确步骤**显式依赖 T3 的 `BoardGrant.grant/3` 签名**(真实依赖,非占位),T3 落地后展开。
- **类型一致**:`BoardGrant.grant/3`(T3 定义)被 T4/T5 消费,签名一致。
- **gate**:授 cap 走 `Cap.issue`+absorb(I12);passive board 跳 join(RF-6);cap 实例精确(no-wildcard);改 manifest/plugin 后 arch baseline 重测。
