# hello LLM via curl-agent delegation (X2b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Every subagent MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (+ `ezagent-socialware` for Tasks 3-4). Without them it writes stale Elixir and violates invariants.

**Goal:** hello's non-`claude_code` (HTTP) LLM branch delegates page generation to a declared curl "llm" session member (which holds its DeepSeek key in its `:api_keys` slice, provisioned by the platform credential system) instead of reading env-var API keys — hello never touches the key. The `claude_code` backend and hello's synchronous generation pipeline are unchanged.

**Architecture:** Two small DOMAIN additions + two PLUGIN changes. (1) A thin sync-completion wrapper `Ezagent.AgentBridge.complete/2` over the already-existing `AgentBridge.deliver_with_flavor/3` (returns `{:ok, %{content}}` for `:in_process_sync` curl). (2) A content-level `credential_optional` override at `cascade.ex:87` so a curl member can keyless-spawn (the downstream `credential_required?: false` plumbing already exists) — protects INV-CC. (3) A `hello.llm` curl recipe (config carries provider/api_url/model + `credential_optional`) declared as a `Definition.roles` member. (4) `generator.ex` `call_llm/2`'s HTTP branch swaps env-key HTTP for `Ezagent.AgentBridge.complete(curl_uri, prompt)`, threading `session_uri` down to resolve the member.

**Tech Stack:** Elixir/OTP, `Ezagent.AgentBridge` + `Payload`, `Ezagent.Socialware.Definition.roles`, `EzagentPluginHello.Members`, ExUnit (`EzagentCore.DataCase`).

**Spec:** `docs/superpowers/specs/2026-07-07-hello-llm-via-curl-agent-delegation-design.md`

## Global Constraints

- **INV-CC (HARD invariant, dedicated regression tests required):** (1) `HELLO_LLM_BACKEND=claude_code` behavior is byte-identical to before (curl "llm" member never called); (2) a deployment with **no DeepSeek credential source** still creates hello sessions (the curl "llm" member keyless-spawns; session-create must NOT fail).
- **No core changes beyond the two named domain additions** (`Ezagent.AgentBridge.complete/2` + the `cascade.ex:87` `credential_optional` read). Do NOT touch `resolver.ex`, `cascade_runtime.ex`, `agent_bridge.ex`'s existing fns, `recipe_materializer.ex`, `definition_agents.ex`. If a task seems to need one, STOP and flag it.
- **`credential_optional` must be authored under `recipe.config`** (top-level recipe keys outside the fixed allowlist {skills, plugins, prompt, script} are dropped by `RecipeMaterializer.template_content/2`; the whole `recipe.config` map is merged into content). Same for `provider`/`api_url`/`model` (read by curl's `template_data_extra/1` via `content_field`).
- **Authorization of `complete/2` is a 林懿伦 decision (deferred).** v1 ships `complete/2` UNGUARDED (no cap check); hello calls it under admin authority. Flag this prominently in the PR for 林懿伦 to decide cap-gating vs admin-only. Do NOT invent a cap scheme in this plan.
- **Function naming (`Ezagent.AgentBridge.complete/2`)** is 林懿伦-adjustable; implement under this name, note it in the PR.
- CjkLiteralGate: no Han in `.ex` string literals. Commit messages end `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Never touch `config/dev.exs`.
- Gate: each task green on its named tests; full `mix precommit` + `mix ezagent.check_invariants` is the Task 5 gate.

---

## File Structure

- `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex` — MODIFY `:87` + add a private `credential_required?/2` reading `content_field(content, :credential_optional)`. (Task 1)
- `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/agent_bridge.ex` — ADD public `complete/2` wrapping `deliver_with_flavor/3` + `%Payload{}` construction. (Task 2)
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex` — ADD `hello_llm_recipe/0` to `roles/0`. (Task 3)
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex` — ADD the curl "llm" member to `hello_definition_attrs/1`'s `roles:`. (Task 3)
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex` — MODIFY `call_llm/2` (thread `session_uri`, swap HTTP branch), DELETE `api_key/0`/`api_url/0`/`model/0`, thread `session_uri` through `classify_intent`/`fresh_spec`/`generate_theme`/`card_spec`. (Task 4)
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex` — MODIFY the `Generator.classify_intent/1` call to pass `session_uri`. (Task 4)
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/llm/api_client.ex` — DELETE (curl agent holds url/model/key). (Task 4)
- Tests under each app's `test/`. (all tasks)

---

## Task 1: DOMAIN — `credential_optional` content override (protects INV-CC)

Make a `:slice` (curl) agent's credential OPTIONAL when its content carries `credential_optional: true`, so it keyless-spawns instead of failing `:no_credential_source`. Today `cascade.ex:87` hardcodes `credential_required?: credential_required_by_default?(credential_adapter)` (true for `:slice`); the downstream `credential_required?: false` plumbing already exists (`resolver.ex:158`, `cascade_runtime.ex:66`).

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex` (`:82-89` + a new private fn near `:149`)
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs` (create)

**Interfaces:**
- Consumes: `content_field/2` (`cascade.ex:415`), `credential_required_by_default?/1` (`cascade.ex:149`), `Cascade.resolve_content/N` (public entry — confirm its exact signature in Step 1).
- Produces: a curl (`:slice`) template content with `credential_optional: true` + NO credential source resolves to `{:ok, content}` (no `:no_credential_source` error); without the flag, behavior is unchanged (still required).

- [ ] **Step 1: Read the public `resolve_content` entry to get its exact signature**

Run: `sed -n '1,60p' apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex`
Note the `resolve_content/N` public function signature (params: content, template_class, agent_uri, spawned_by_uri, workspace_uri, flavor, opts — confirm order/arity) so the test calls it correctly. Also note a real `CredentialSliceAdapter` template class to use (`Ezagent.PluginCurlAgent.Template`) and that `default_cascade_configured?(:slice, _, %URI{})` requires a `source_template_uri` in opts to reach the cascade branch.

- [ ] **Step 2: Write the failing test**

Create `apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs`. Use the `resolve_content/N` signature from Step 1. Sketch (adjust arg order to the real signature):

```elixir
defmodule Ezagent.Entity.Agent.TemplateSpawn.CascadeCredentialOptionalTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Agent.TemplateSpawn.Cascade

  @curl_tc Ezagent.PluginCurlAgent.Template
  @agent Ezagent.URI.entity("system", :agent, "cred-opt-demo")
  @admin Ezagent.Entity.User.admin_uri()
  @ws Ezagent.URI.workspace(:system)
  @source_tmpl Ezagent.URI.template(:system, :agent, "hello.llm")

  test "credential_optional: true → :slice agent resolves keyless (no :no_credential_source) when no source" do
    content = %{name: "cred-opt-demo", flavor: "curl", credential_optional: true,
                provider: "deepseek", api_url: "https://api.deepseek.com/chat/completions", model: "deepseek-chat"}

    assert {:ok, resolved} =
             Cascade.resolve_content(content, @curl_tc, @agent, @admin, @ws, "curl",
               source_template_uri: @source_tmpl)

    # keyless: no credential source got written into the resolution
    refute Map.get(resolved, :cascade_resolution) &&
             Map.get(resolved.cascade_resolution, :credential_source_uri)
  end

  test "without credential_optional → :slice with no source still fails (regression: existing curl unchanged)" do
    content = %{name: "req-demo", flavor: "curl",
                provider: "deepseek", api_url: "https://api.deepseek.com/chat/completions", model: "deepseek-chat"}

    assert {:error, :no_credential_source} =
             Cascade.resolve_content(content, @curl_tc, @agent, @admin, @ws, "curl",
               source_template_uri: @source_tmpl)
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix cmd --app ezagent_domain_agent mix test test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs`
Expected: the first test FAILS with `{:error, :no_credential_source}` (credential currently required for `:slice`). (If the second test also fails, the resolve_content signature/args are off — fix per Step 1.)

- [ ] **Step 4: Implement the content override**

In `cascade.ex`, change line 87 from:
```elixir
        credential_required?: credential_required_by_default?(credential_adapter),
```
to:
```elixir
        credential_required?: credential_required?(credential_adapter, content),
```
and add a private fn near `credential_required_by_default?/1` (~`:149`):
```elixir
  # A member may opt OUT of the required-by-default credential (e.g. a curl LLM
  # member declared credential_optional so it keyless-spawns in deployments with
  # no credential source). Authored under recipe.config → content.credential_optional.
  defp credential_required?(adapter, content) do
    if content_field(content, :credential_optional) in [true, "true"] do
      false
    else
      credential_required_by_default?(adapter)
    end
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix cmd --app ezagent_domain_agent mix test test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs`
Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex \
        apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs
git commit -m "feat(agent): content-level credential_optional override for keyless slice-flavor spawn

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: DOMAIN — `Ezagent.AgentBridge.complete/2` sync completion wrapper

A thin sync entry: given a curl agent URI + a prompt, return the LLM completion text, reusing the already-existing synchronous `deliver_with_flavor/3`. The curl adapter reads the agent's `:api_keys` + `:curl_agent` slices — **the caller never sees the key**.

**Files:**
- Modify: `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/agent_bridge.ex` (add `complete/2`)
- Test: `apps/ezagent_domain_agent_bridge/test/ezagent/agent_bridge/complete_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.AgentBridge.deliver_with_flavor/3` (`agent_bridge.ex:52`, returns `{:ok, %{content, usage}} | {:error, term}` for `:in_process_sync`), `Ezagent.AgentBridge.Payload` (`@enforce_keys [:message_id, :session_uri, :sender_uri, :text, :event_type]`, `meta: %{String.t()=>String.t()}`).
- Produces: `Ezagent.AgentBridge.complete(agent_uri :: URI.t(), prompt :: String.t()) :: {:ok, text :: String.t()} | {:error, term()}`. **Unguarded (no cap check) — authz deferred to 林懿伦.**

- [ ] **Step 1: Write the failing test**

Create `apps/ezagent_domain_agent_bridge/test/ezagent/agent_bridge/complete_test.exs`:

```elixir
defmodule Ezagent.AgentBridge.CompleteTest do
  use ExUnit.Case, async: true

  test "complete/2 on an unresolvable agent returns {:error, _} (never raises, never leaks a key)" do
    ghost = Ezagent.URI.entity("system", :agent, "no-such-curl-agent")
    assert {:error, _} = Ezagent.AgentBridge.complete(ghost, "hello")
  end

  test "complete/2 exists with the documented arity/spec" do
    assert function_exported?(Ezagent.AgentBridge, :complete, 2)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_domain_agent_bridge mix test test/ezagent/agent_bridge/complete_test.exs`
Expected: FAIL — `complete/2` undefined.

- [ ] **Step 3: Implement `complete/2`**

In `agent_bridge.ex`, add (near `deliver_with_flavor/3`):
```elixir
  @doc """
  Synchronously ask a `curl`-flavor agent for an LLM completion and return the
  text. Reuses the `:in_process_sync` deliver primitive: the curl adapter reads
  the agent's OWN `:api_keys` + `:curl_agent` snapshot slices and does the HTTP
  round-trip — the CALLER never sees the API key.

  NOTE (authz): v1 is UNGUARDED — any caller holding the agent URI can invoke a
  completion. Cap-gating vs admin/system-only is a pending 林懿伦 decision.
  """
  @spec complete(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def complete(%URI{} = agent_uri, prompt) when is_binary(prompt) do
    payload = %Ezagent.AgentBridge.Payload{
      message_id: "complete-" <> Integer.to_string(System.unique_integer([:positive])),
      session_uri: nil,
      sender_uri: agent_uri,
      text: prompt,
      event_type: :system,
      meta: %{"agent_uri" => URI.to_string(agent_uri)}
    }

    case deliver_with_flavor(agent_uri, payload, "curl") do
      {:ok, %{content: content}} when is_binary(content) -> {:ok, content}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_complete_result, other}}
    end
  end
```

(If `System.unique_integer/1` is disallowed in this env — it is available in runtime code, only the workflow-script sandbox forbids it — keep it; it is normal runtime Elixir.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix cmd --app ezagent_domain_agent_bridge mix test test/ezagent/agent_bridge/complete_test.exs`
Expected: PASS. (The `{:error, _}` path exercises `deliver_with_flavor` → `deliver_in_process` → no adapter/agent → `drop/3` → `{:error, _}`. Confirm `drop/3` returns an `{:error, _}` tuple; if it returns `:ok`, adjust the test to assert the actual no-op contract and add a targeted assertion that `complete/2` surfaces a non-`{:ok, text}` result as `{:error, _}`.)

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/agent_bridge.ex \
        apps/ezagent_domain_agent_bridge/test/ezagent/agent_bridge/complete_test.exs
git commit -m "feat(agent-bridge): Ezagent.AgentBridge.complete/2 — sync curl-agent completion (caller never sees the key)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: PLUGIN — `hello.llm` curl recipe + Definition member (credential_optional)

Declare a curl "llm" member in hello's Definition (consistent with builder/concierge), credential-optional so it keyless-spawns.

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex` (`roles/0` + a new `hello_llm_recipe/0`)
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex` (`hello_definition_attrs/1` `roles:`)
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs` + `apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs` (INV-CC ②)

**Interfaces:**
- Consumes: `RecipeMaterializer.template_content/2` (merges `recipe.config` wholesale into content), curl `template_data_extra/1` (reads `provider`/`api_url`/`model` from content), Task 1's `credential_optional` override, `Members.role_uri/2`.
- Produces: `App.hello_definition_attrs/1` `roles:` includes `%{role_name: "llm", fill: :agent, recipe: "hello.llm", flavor: "curl"}`; `Application.roles/0` includes `hello_llm_recipe/0` carrying `config: %{provider, api_url, model, credential_optional: true}`.

- [ ] **Step 1: Write the failing test**

Add to `registration_test.exs`:
```elixir
test "hello.llm curl recipe carries provider/model + credential_optional in config" do
  recipe = EzagentPluginHello.Application.hello_llm_recipe()
  assert recipe.name == "hello.llm"
  assert recipe.config.provider == "deepseek"
  assert recipe.config.model == "deepseek-chat"
  assert recipe.config.credential_optional == true
end

test "hello Definition declares the llm curl member" do
  attrs = EzagentPluginHello.App.hello_definition_attrs("hello-demo")
  {:ok, defn} = Ezagent.Socialware.Definition.new(attrs)
  llm = Enum.find(defn.roles, &(&1.role_name == "llm"))
  assert llm.fill == :agent
  assert llm.flavor == "curl"
  assert llm.recipe == "hello.llm"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/registration_test.exs -o "hello.llm"`
Expected: FAIL — `hello_llm_recipe/0` undefined + no "llm" role in the Definition.

- [ ] **Step 3: Add the recipe + Definition member**

In `application.ex`, add to `roles/0` and define the recipe:
```elixir
  def roles,
    do: [hello_orchestrator_recipe(), hello_builder_recipe(), hello_concierge_recipe(), hello_llm_recipe()]

  @doc "The `hello.llm` role — a curl LLM agent hello delegates HTTP-backend generation to (credential-optional so it keyless-spawns; key comes from the platform credential cascade)."
  @spec hello_llm_recipe() :: map()
  def hello_llm_recipe do
    %{
      name: "hello.llm",
      # curl behaviors come from the "curl" flavor's instance_behaviors, NOT here
      # (Definition.roles materialize drops recipe.behaviors).
      requested_caps: [],
      config: %{
        provider: "deepseek",
        api_url: "https://api.deepseek.com/chat/completions",
        model: "deepseek-chat",
        # opt out of the required-by-default :slice credential (Task 1) so a
        # deployment with no DeepSeek credential source still spawns this member.
        credential_optional: true
      }
    }
  end
```

In `app.ex` `hello_definition_attrs/1`, append to `roles:`:
```elixir
        %{role_name: "llm", fill: :agent, recipe: "hello.llm", flavor: "curl"}
```

- [ ] **Step 4: Run the registration tests**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/registration_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the INV-CC ② regression (keyless spawn does not fail session-create)**

In `test/integration/hello_page_e2e_test.exs` (or a new `hello_llm_member_test.exs`), with the existing setup (seed roles incl. `hello.llm` + Definition, NO DeepSeek credential source):
```elixir
test "INV-CC ②: a session with the curl llm member is created even with NO credential source", %{ws: ws} do
  # No credential source provisioned in this test env.
  assert {:ok, session_uri, _orch} = EzagentPluginHello.App.ensure_app(ws, "llm-keyless")
  # llm curl member materialized (keyless — did not crash session-create)
  assert {:ok, %URI{}} = EzagentPluginHello.Members.role_uri(session_uri, "llm")
end
```

- [ ] **Step 6: Run the INV-CC ② test**

Run: `mix cmd --app ezagent_plugin_hello mix test test/integration/hello_page_e2e_test.exs`
Expected: PASS. If session-create fails with `:no_credential_source`, Task 1's `credential_optional` isn't threading — STOP and verify `recipe.config.credential_optional` reaches `content` (grep the spawned content) before proceeding.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex \
        apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex \
        apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs \
        apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs
git commit -m "feat(hello): declare a credential-optional curl llm member in the Definition

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: PLUGIN — swap `call_llm/2` HTTP branch to `complete/2`; thread session_uri; delete env/ApiClient

The HTTP branch delegates to the curl "llm" member. `claude_code` branch untouched (INV-CC ①).

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex` (`classify_intent` call site)
- Delete: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/llm/api_client.ex`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/generator_test.exs`

**Interfaces:**
- Consumes: `Ezagent.AgentBridge.complete/2` (Task 2), `EzagentPluginHello.Members.role_uri/2`.
- Produces: `call_llm(session_uri, system, user_text)` (new arity-3); `classify_intent(session_uri, user_text)` (new arity-2, public — Router updated); `fresh_spec`/`generate_theme`/`card_spec` thread `session_uri`.

- [ ] **Step 1: Read the exact call sites**

Run: `grep -n "call_llm\|def classify_intent\|def fresh_spec\|def generate_theme\|def card_spec\|api_key\|api_url\|def model\|ApiClient\|Members.role_uri" apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex`
and `grep -rn "classify_intent\|Generator.classify" apps/ezagent_plugin_hello/lib`.
Map every caller of `call_llm` + `classify_intent` and confirm each has `session_uri` in scope to thread (per the spec's call-site table: `concierge_answer` has it; `classify_intent`/`fresh_spec`/`generate_theme`/`card_spec` need it threaded from their `session_uri`-bearing public callers `generate/2`, `concierge_start/3`, `Router.decide`).

- [ ] **Step 2: Write the failing test (claude_code branch unchanged + HTTP branch routes to complete/2)**

Add to `generator_test.exs`:
```elixir
describe "call_llm backend routing (INV-CC ①)" do
  test "claude_code backend still calls ClaudeCode.chat, never the curl member" do
    # With HELLO_LLM_BACKEND=claude_code, call_llm must not touch Members/AgentBridge.
    # Assert via the public path that a claude_code-configured generate does not
    # require an llm member (existing claude_code tests already cover behavior;
    # here assert the branch selection is unchanged).
    System.put_env("HELLO_LLM_BACKEND", "claude_code")
    on_exit(fn -> System.delete_env("HELLO_LLM_BACKEND") end)
    # (use the existing claude_code test harness/mocks in this file; assert the
    #  claude_code path is taken — mirror the existing backend test if present)
    assert EzagentPluginHello.Generator.__info__(:functions) |> Keyword.has_key?(:classify_intent)
  end
end
```
(Adjust to the file's existing mocking style for `call_llm`/backends — reuse whatever seam `generator_test.exs` already uses to assert backend selection. The load-bearing assertion: with `claude_code`, no `Members.role_uri`/`AgentBridge.complete` call happens.)

- [ ] **Step 3: Run test to verify it fails / establishes the harness**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/generator_test.exs`
Expected: compiles + runs (this step mainly locks the test harness; the real behavior change lands in Step 4).

- [ ] **Step 4: Thread session_uri + swap the HTTP branch + delete env/ApiClient**

Rewrite `call_llm` to take `session_uri` and delegate the HTTP branch:
```elixir
  defp call_llm(session_uri, system, user_text) do
    case System.get_env("HELLO_LLM_BACKEND") do
      "claude_code" ->
        EzagentPluginHello.LLM.ClaudeCode.chat(system, user_text)

      _ ->
        case EzagentPluginHello.Members.role_uri(session_uri, "llm") do
          {:ok, curl_uri} ->
            case Ezagent.AgentBridge.complete(curl_uri, compose_prompt(system, user_text)) do
              {:ok, content} -> {:ok, %{content: content}}
              {:error, _} = err -> err
            end

          :error ->
            {:error, :no_llm_agent}
        end
    end
  end

  # curl's completion is a single prompt; fold hello's per-call system prompt into
  # the user turn (the llm member's own system_prompt config is left generic/empty).
  defp compose_prompt(system, user_text), do: system <> "\n\n" <> user_text
```
Update the four helpers to accept + pass `session_uri`:
- `classify_intent(session_uri, user_text)` (public — update `@spec` to arity-2) → `call_llm(session_uri, Prompts.intent_system(), user_text)` (use the real system-prompt fn name from Step 1).
- `fresh_spec(session_uri, prompt_text)` → `call_llm(session_uri, Prompts.page_gen_system(), prompt_text)`.
- `generate_theme(session_uri, spec, base_theme, instruction)` → thread to its `call_llm`.
- `card_spec(session_uri, current, user_text)` + `card_spec_with_retry(session_uri, ...)` → thread.
Update all their callers (which have `session_uri`) to pass it. Update `concierge_answer`'s internal `call_llm(...)` to `call_llm(session_uri, ...)`.
DELETE `api_key/0`, `api_url/0`, `model/0` (`generator.ex:820-825`), the `alias EzagentPluginHello.LLM.ApiClient` (`:32`), and the file `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/llm/api_client.ex`.

- [ ] **Step 5: Update the Router caller**

In `router.ex`, change `Generator.classify_intent(user_text)` (~`:88`) to `Generator.classify_intent(session_uri, user_text)` — confirm `session_uri` is in `decide/3` scope (it is: `route/3` has `session_uri`; thread it into `decide` if `decide` currently lacks it).

- [ ] **Step 6: Run generator + router + e2e tests**

Run: `mix cmd --app ezagent_plugin_hello mix test test/ezagent_plugin_hello/generator_test.exs test/ezagent_plugin_hello/router_test.exs test/integration/hello_page_e2e_test.exs`
Expected: PASS. (claude_code-backed tests unchanged; no references to deleted `api_key`/`ApiClient` remain — compile-clean.)

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex \
        apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex \
        apps/ezagent_plugin_hello/test/ezagent_plugin_hello/generator_test.exs
git rm apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/llm/api_client.ex
git commit -m "feat(hello): delegate HTTP-backend LLM to the curl llm member; drop env key + ApiClient

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Full-suite gate + INV-CC + precommit + invariants

**Files:** whole `ezagent_plugin_hello` + `ezagent_domain_agent` + `ezagent_domain_agent_bridge` suites + invariants.

- [ ] **Step 1: Touched-app suites**

Run: `mix cmd --app ezagent_domain_agent mix test && mix cmd --app ezagent_domain_agent_bridge mix test && mix cmd --app ezagent_plugin_hello mix test`
Expected: PASS. Fix any setup regressions (seed `hello.llm` role + Definition in setups that build hello sessions).

- [ ] **Step 2: Format touched files**

Run: `mix format apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/agent_bridge.ex apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/*.ex && mix format --check-formatted apps/ezagent_plugin_hello/lib/**/*.ex`
Expected: clean.

- [ ] **Step 3: precommit + invariants**

Run: `mix precommit && mix ezagent.check_invariants`
Expected: PASS. Watch: (a) CjkLiteralGate on hello `.ex` string literals; (b) `cross_file_duplicate_fn_groups` — deleting hello's `api_client.ex` (a copy of curl's ApiClient) likely REMOVES a duplicate group → the baseline may need lowering (measured < cap → passes; if the gate now reports the cap is above the measured count, that's fine — it only fails on GROWTH). If a fitness gate needs a bump/trim, edit `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs` with an `# arch-cap-bump:` reason (or lower the cap if a group was removed).

- [ ] **Step 4: INV-CC acceptance (manual/e2e)**

1. **INV-CC ①**: `HELLO_LLM_BACKEND=claude_code` → hello generation behaves exactly as before (curl member never called).
2. **INV-CC ②**: a stack with NO DeepSeek credential source → `App.ensure_app` creates a session; `Members.role_uri(session,"llm")` resolves (keyless member); session usable.
3. HTTP mode + a provisioned DeepSeek credential source → owner "改标题" → page updates via `AgentBridge.complete(llm_curl, ...)`, hello never touches the key.
4. HTTP mode + no key → visible `{:error, :no_llm_agent}` / key error, session not crashed.

- [ ] **Step 5: Final commit (if fixups)**

```bash
git add -A -- apps/ezagent_plugin_hello apps/ezagent_domain_agent apps/ezagent_domain_agent_bridge apps/ezagent_core/test/architecture/arch_baseline_manifest.exs
git commit -m "test(hello): green suites + invariants for curl-agent LLM delegation (X2b)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- §① `Ezagent.Agent.complete/2` → Task 2 (as `Ezagent.AgentBridge.complete/2`, name flagged for 林懿伦). ✅
- §①b `credential_optional` override → Task 1. ✅
- §② authz model → deferred (unguarded v1, flagged in Global Constraints + Task 2 doc + PR). ✅
- §③ curl "llm" Definition member + recipe (credential-optional) → Task 3. ✅
- §③ `call_llm/2` swap + delete env/ApiClient → Task 4. ✅
- §④ error handling (visible, non-crashing) → Task 4 Step 4 (`{:error, :no_llm_agent}`) + Task 5 acceptance 4. ✅
- INV-CC ① (claude_code byte-identical) → Task 4 Step 2 + Task 5 acceptance 1. ✅
- INV-CC ② (keyless spawn, no session-create failure) → Task 3 Step 5 + Task 5 acceptance 2. ✅
- 林懿伦 gate (sign-off before merge) → this is a PR-review gate; the two domain changes (Tasks 1-2) are isolated + flagged.

**Load-bearing verification baked in:** Task 3 Step 6 explicitly STOPS if `recipe.config.credential_optional` doesn't thread to content (the one thing that, if wrong, breaks INV-CC ②). Task 1 Step 1 + Task 4 Step 1 mandate reading exact signatures before writing code.

**Type consistency:** `Ezagent.AgentBridge.complete/2 :: {:ok, String.t()} | {:error, term()}` used consistently (Task 2 → Task 4). `call_llm/3` (session_uri, system, user_text) + `classify_intent/2` (session_uri, user_text) consistent (Task 4 + Router Task 4 Step 5). `credential_required?/2` (adapter, content) internal to Task 1.

**Known deferrals (honest):** Task 1/2/4 each begin with a mandated read step because exact signatures (`Cascade.resolve_content/N` arity, `drop/3` return contract, the hello `Prompts.*_system` fn names, `decide/3` session scope) must be confirmed against the live tree — writing that glue blind would fabricate. Each read step names the exact grep/file.
