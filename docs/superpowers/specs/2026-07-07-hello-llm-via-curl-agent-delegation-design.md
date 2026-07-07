# hello LLM 凭证:从 env-var key 迁到 curl-agent 委派 (X2b) 设计

> **Date:** 2026-07-07 · **Author:** zhangning (via Claude) · **Branch:** `feat/hello-0707`(off latest main,含已 merge 的 #1208 hello substrate 迁移)
> **来源:** 团队线程 item 2(姚升悦 → 张宁),lead 林懿伦 steer "不要在 hello 里要求 API key,通过创建/复用一个 curl agent 来实现"。
> **状态:** 设计提案。**含一处 domain/架构改动(`Ezagent.Agent.complete/2`)+ 新增一条同步 agent 交互路径 → 需要林懿伦 sign-off 才进实施**(grill 文化:暂停→讨论→等 lead)。

## 目标 / scope

hello 的 HTTP LLM 后端目前**要求运维在部署环境 export 一个 key**(`generator.ex:820` `System.get_env("HELLO_LLM_API_KEY") || System.get_env("DEEPSEEK_KEY")`)。每个组合 hello 的 socialware(dealscout 等)都撞这个——它们的部署环境没有本地 Claude 登录态(拿不到免 key 的 `claude_code` 后端),只能走 HTTP 后端,于是被 env-key 卡住(dealscout e2e 因此只能用 seam 假造生成)。

**改法(X2b):** 把 `call_llm/2` 的**非-`claude_code`(HTTP)分支**从"读 env key + 自己 ApiClient 打 HTTP"换成"**委派给一个 curl-flavor agent**"——curl agent 持有自己的 key(在 `:api_keys` slice,由平台凭证系统 provision),hello **全程不碰 key**。

**明确不动的:**
- **`claude_code` 后端一字不改**(`call_llm/2` 的 `"claude_code" ->` 分支 `generator.ex:477`)。默认后端选择机制不变。你现在跑的 server 就是 claude_code,零影响。
- 生成管线保持**同步**(`call_llm/2` 仍返回 `{:ok, %{content}}` → `Spec.extract/validate` → `TurnDriver.drive`)。

**INV-CC(硬不变量,一等验收):claude_code 部署绝对零影响。** 具体可测:(1) `HELLO_LLM_BACKEND=claude_code` 时,所有 LLM 调用行为**与本改动前逐字节一致**(走 `ClaudeCode.chat`,curl 成员从不被调用);(2) **没配 DeepSeek 凭证源的部署,建 hello session 必须照常成功**(curl "llm" 成员 keyless spawn,不得让 session-create 失败)。这条不变量约束了 §①b 的 `credential_optional` 设计。验证隔离依据:`call_llm/2` 的 claude_code 分支走独立的 `ClaudeCode.chat`(自读 `HELLO_CLAUDE_BIN`/`HELLO_LLM_MODEL`,`claude_code.ex:88,95`);`api_key/api_url/model/ApiClient` 只在 HTTP 分支(`generator.ex:482-487`),删除不触及 claude_code(已 grep 证实)。

## 为什么是 X2b(而非 X1 / X2a)

- **X1(hello 读 curl agent 的 key 自己打)** 被否:破坏"key 只在 agent 手里"的凭证边界,hello 会摸到别的 agent 的密钥。
- **X2a(纯插件、异步委派)** 被否:要把 hello 同步生成管线改成有状态异步往返(编排器 slice 存 pending + Router 加分支 + ref_id 对齐),且继承 `:in_process_sync` 的 stale-snapshot 排序限制(`agent/receive.ex:126-196`),全仓库无先例、无 await helper。改动大、踩坑。
- **X2b(暴露已存在的 domain 同步原语)** 选中:**同步补全原语 domain 层已经实现**——`Ezagent.AgentBridge.deliver_with_flavor/3`(`apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge.ex:54-70,288-296`)对 `:in_process_sync` flavor 同步返回 `{:ok, %{content}}`,内部读 agent 的 `:api_keys` slice + 打 HTTP。X2b 只是给它加一层薄封装暴露出来。hello 保持同步、不碰 key、claude_code 零影响。

## 设计

### ① 新增 domain 能力 `Ezagent.Agent.complete/2`(`ezagent_domain_agent`)

```elixir
@spec complete(agent_uri :: URI.t(), prompt :: String.t(), opts :: keyword()) ::
        {:ok, text :: String.t()} | {:error, term()}
def complete(%URI{} = agent_uri, prompt, opts \\ []) when is_binary(prompt) do
  # 1. 构造 flavor-neutral payload(curl adapter 从 meta["agent_uri"] 读目标 agent)
  payload = %Ezagent.AgentBridge.Payload{
    text: prompt,
    meta: %{"agent_uri" => URI.to_string(agent_uri)}
  }
  # 2. 调已存在的 domain 同步 deliver
  case Ezagent.AgentBridge.deliver_with_flavor(agent_uri, payload, "curl") do
    {:ok, %{content: content}} -> {:ok, content}
    {:error, _} = err -> err
    other -> {:error, {:unexpected_complete_result, other}}
  end
end
```

- **复用、零新机制**:curl adapter 的凭证-slice 读(`plugin_curl_agent/bridge_adapter.ex:75-138`,从 snapshot 读 `:api_keys` + `:curl_agent`,deadlock-safe)+ HTTP client(`ApiClient.chat_completion`)。**hello 看不到 key**。
- **flavor 参数**:首版固定 `"curl"`(唯一同步返回真 LLM 补全的 flavor,`plugin_curl_agent/bridge_adapter.ex:111-112`;其它 `:in_process_sync` flavor 的 deliver 只回 echo/routing shape)。将来可从 `AgentFlavorAttributes` 解析,首版不做(YAGNI)。
- **模块位置**:`ezagent_domain_agent`(`Entity.Agent` / `ActionSet.CurlAgent` 同层)。函数名/归属最终由林懿伦定。

### ①b 第二处 domain 改动:content 级 `credential_optional` 覆盖(保 claude_code 零影响的关键)

**背景(验证发现的真风险):** curl 是 `:slice` 凭证 flavor,**凭证默认 required**(`cascade.ex:149` `credential_required_by_default?(:slice)→true`)。Definition.roles 物化给成员穿 `source_template_uri`(`%URI{}`,`definition_agents.ex:211`)→ `default_cascade_configured?(:slice,_,%URI{})→true` → 触发 cascade → 无凭证源时 `resolver.ex:217` `{:error, :no_credential_source}` 冒泡 → **curl 成员 spawn 失败 → session-create 失败**。**没配 DeepSeek key 的 claude_code 部署会因此建 session 直接崩**——违反"claude_code 绝对零影响"硬约束。

**改法(小):** credential-optional 的**下游管线其实已经通**——`resolver.ex:158` 与 `cascade_runtime.ex:66` 都已尊重 `credential_required?: false`。**唯一写死的是 `cascade.ex:87`** 那一行 `credential_required?: credential_required_by_default?(credential_adapter)`。只需让它读一个 content 级覆盖(如 `content_field(content, :credential_optional) == true → false`,`content_field` helper 已存在)。**~1-2 行 domain 改动**,不动下游。

**为什么放心:** 覆盖后无源 → `resolver` 返回 `{:ok, nil}`(不报错)→ `put_default_cascade_if_source_present` 的 `%{secret_source: nil}` 分支(`cascade.ex:110-118`)→ `{:ok, content}` 无 cascade_resolution → `materialize_credential_slice` `:skip`(`curl_agent.ex:61-63`)→ keyless 成员正常起。全程无报错、claude_code 模式下它永不被调用。

### ② 授权模型 —— 林懿伦 拍板项(X2b 引入的新授权面)

`complete/2` 绕过 session/dispatch 直接问 agent 的 transport,是**第三条 agent 交互路径**(T2 只有 dispatch + chat-delivery)。谁有权让一个 agent 补全?两个候选,请林懿伦定:

- **(A) cap-gated**:caller 出示 `:agent` 轴上的一个 cap(如 `{:agent, Entity.Agent, :complete, <agent-scope>}`),`complete/2` 在 chokepoint 校验。跟 CapBAC 一致、可委派可收缩。
- **(B) system/admin-only**:`complete/2` 仅接受 admin-genesis / system 权威调用。最简,但把它变成"只有平台内部能用"的能力。

hello 的 Generator 已在 admin 权威下跑(`TurnDriver` 用 `admin_genesis_cap`),(B) 直接可用;(A) 更"正",但要设计 cap 主体 + 授予路径。**这是 spec 的核心 open question。**

### ③ hello 侧:声明一个 curl "llm" 成员 + 换 `call_llm/2` 的 HTTP 分支(纯插件)

**声明成员**(复用 B'-direct 的 `Definition.roles` + `Members.role_uri`):
- hello 的 Definition.roles 增加一项 `%{role_name: "llm", fill: :agent, recipe: "hello.llm", flavor: "curl"}`。
- 新写一个 curl recipe `hello.llm`(`Application.roles/0`),含 `config: %{provider: "deepseek", api_url: ..., model: ...}`(`RecipeMaterializer.template_content` 会 thread `config`,Explore 证实)。curl 行为来自 `"curl"` flavor 的 `instance_behaviors`(`curl_behaviors`),不放 recipe.behaviors(Definition.roles 路径丢弃)。
- **成员声明为 `credential_optional`(见 §①b + INV-CC)** —— 这样没配 DeepSeek key 的部署(claude_code 部署正是这种)也能 keyless spawn,不会把 session-create 搞崩。
- 成员的 **key**:有源时,由 #17 credential cascade 在物化时从平台 credential 源(user-default / workspace-shared 的 DeepSeek 凭证)拷进它的 `:api_keys` slice(`CredentialSliceAdapter.materialize_credential_slice`,`curl_agent.ex:60-76`)。**运维在平台凭证面板配一次,不再 export env。** 无源时 `materialize_credential_slice` 优雅 `:skip`(`curl_agent.ex:61-63`),成员空 `:api_keys` slice 正常起、休眠。

**换 call_llm/2**(`generator.ex:476-498`,只改非-claude_code 分支):
```elixir
defp call_llm(system, user_text) do
  case System.get_env("HELLO_LLM_BACKEND") do
    "claude_code" ->
      EzagentPluginHello.LLM.ClaudeCode.chat(system, user_text)   # 不动

    _ ->
      case EzagentPluginHello.Members.role_uri(current_session_uri(), "llm") do
        {:ok, curl_uri} ->
          Ezagent.Agent.complete(curl_uri, compose(system, user_text))
        :error ->
          {:error, :no_llm_agent}
      end
  end
end
```
- 删掉 `api_key/0` / `api_url/0` / `model/0`(`generator.ex:820-825`)+ hello 那份拷贝来的 `ApiClient`(`llm/api_client.ex`,curl agent 持有 url/model/key)。
- `compose/2`:curl 的补全接口是单 prompt(system+user 合并),hello 现有 `call_llm` 传 system+user 两段——需要把 system prompt 折进 curl 的 `system_prompt` config 或合并进 prompt。**实施细节**(curl agent config 有 `system_prompt` 字段 `curl_agent.ex:101-109`,可把 hello 各场景的 system 放那儿,或每次合并)。
- `current_session_uri()`:Generator 各入口已带 `session_uri`(`generate/2`、`concierge_answer/3` 等),透传即可。

### ④ 错误处理(不静默)

- 没 llm 成员 → `{:error, :no_llm_agent}`;没配 key(cascade 无源)→ curl adapter 返回 key 错误 → `{:error}` 冒泡。
- 复用现有 `:no_api_key` 那条错误呈现路径(Generator 已有 error 分支)。可见错误 + telemetry,绝不返回 `:ok` 而啥也没生成(Ezagent "谁会知道失败"原则)。

## 复用 vs 新增(证据)

| 部分 | 状态 | 证据 |
|---|---|---|
| 同步补全原语 | **已存在** | `AgentBridge.deliver_with_flavor/3` → `deliver_in_process/3` 同步返回 `{:ok, result}`,`agent_bridge.ex:54-70,288-296` |
| curl 凭证-slice 读 + HTTP | **已存在** | `plugin_curl_agent/bridge_adapter.ex:73-138` |
| 无 env 的 key provision | **已存在** | #17 cascade `CredentialSliceAdapter.materialize_credential_slice`,`curl_agent.ex:60-76` |
| 按 role_name 解析成员 | **已存在**(#1208) | `EzagentPluginHello.Members.role_uri/2` |
| credential-optional 下游管线 | **已存在** | `resolver.ex:158`、`cascade_runtime.ex:66` 已尊重 `credential_required?: false` |
| `Ezagent.Agent.complete/2` | **新增(domain,薄封装)** | 本 spec ① |
| content 级 `credential_optional` 覆盖(`cascade.ex:87`) | **新增(domain,~1-2 行)** | 本 spec ①b |
| curl recipe `hello.llm` + Definition 成员(credential-optional) | **新增(插件)** | 本 spec ③ |
| `call_llm/2` HTTP 分支改写 + 删 env/ApiClient | **改(插件)** | 本 spec ③ |

## 林懿伦 sign-off gate(实施前必过)

两处 domain 改动都要过你:

1. **`Ezagent.Agent.complete/2` 这条"同步问 agent 拿结果"的 domain 路径可接受吗?**(T2 是异步 doctrine;这条正交、T2 自己不提供同步选项,但它是新增交互面,归你的 agent 模型。)
2. **授权模型选 (A) cap-gated 还是 (B) admin/system-only?**(§②)
3. **§①b 的 content 级 `credential_optional` 覆盖(`cascade.ex:87`)可接受吗?** 这是保 INV-CC(claude_code 部署 keyless spawn 不崩)的关键。下游管线已支持 `credential_required?: false`,只差这一个覆盖入口。命名/形状你定。
4. 函数归属/命名(`Ezagent.Agent.complete/2` vs 别的),你定。
5. 这是否该做成**全平台共享能力**(dealscout 等都用),还是先 hello-local?(倾向共享——item 2 的痛是所有组合方共有的。)

## 验收(e2e)

1. 平台凭证面板配一个 DeepSeek 凭证源(不 export env)→ 新建的 hello session 的 "llm" curl 成员 `:api_keys` slice 有 key。
2. `HELLO_LLM_BACKEND` **不设** claude_code → owner 发"改标题" → hello 经 `Agent.complete(llm_curl, ...)` 拿到补全 → 页面更新(Surface put_version)。**全程无 env key、hello 不碰 key。**
3. **INV-CC ①**:`HELLO_LLM_BACKEND=claude_code` → 行为**与本改动前完全一致**(回归;curl 成员从不被调用)。
4. **INV-CC ②(关键回归)**:**没配任何 DeepSeek 凭证源**的部署 → 建 hello session **照常成功**,"llm" curl 成员 keyless 起、`:api_keys` 空、不报错、session 可用。**这条专门守住"claude_code 部署零影响"。**
5. HTTP 模式但没配 key(keyless llm 成员被调用)→ 可见 `{:error}`,不静默、不崩 session。
6. `mix precommit` + `mix ezagent.check_invariants` 绿(注意 CjkLiteralGate、cross_file_duplicate:删掉 hello 的 ApiClient 拷贝反而**减**一个重复组,可能要下调 baseline)。

## 风险 / 待实施核实

1. **curl 成员经 Definition.roles 物化时,config(provider/url/model)+ `credential_optional` 标记是否真的 thread 到 cascade content**——`RecipeMaterializer` thread `config`,但 curl 的 config_schema 要求 provider/api_url/model 必填(`curl_agent.ex:101-128`);且 `credential_optional` 要从 recipe 一路 thread 到 `cascade.ex:87` 读到的 content(`content_field`)。要确认 Definition.roles 路径(非 Template instantiate 路径)会应用这两者。**这是实施第一步就要验的**(否则 INV-CC ② 保不住)。
2. **system prompt 折叠**:hello 多场景各有 system prompt(page-gen / concierge / classify / theme / card),curl 单 prompt 接口——是每次合并进 prompt,还是给这个 llm 成员的 `system_prompt` config 设一个通用值 + 各场景 prompt 前缀。实施时定。
3. **删 ApiClient 影响面**:确认没有别处依赖 hello 的 ApiClient / 三个 env 读。
4. **credential 源前提**:X2b 的"免 env"依赖平台先配好一个 DeepSeek credential 源(user-default/workspace-shared);没源则 cascade skip、curl 无 key。这是运维一次性动作,doc 要写清。

## 不做(YAGNI)

- 不改 claude_code 后端。
- 不做 X2a 异步改造。
- `complete/2` 首版只支持 curl flavor(不做多 flavor 解析)。
- 不做编排器动态增删 llm 成员(声明式够用)。
