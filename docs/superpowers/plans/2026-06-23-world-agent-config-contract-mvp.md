# World Agent Config — Contract MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-shape the existing world agent create/detail page to the agent-contract: a real create with the backend-supported fields, honest failure feedback, a labeled read-only detail page, and a read-only "Contract coverage" list for the not-yet-wired fields — no backend create_agent/3 change.

**Architecture:** world plugin 3-layer UI (per `references/ui-contract.md`): React island (`Identities.tsx`) ← server-built state (`identity_data.ex`) ← LiveView dispatch (`world_live.ex`). All changes are additive to these three files (+ their tests). The submittable form carries ONLY `{flavor, name, cwd, with_pty, caps}` — exactly what `Workspace.create_agent/3` + `grant_initial_caps/3` accept today.

**Tech Stack:** Elixir/Phoenix LiveView, React 18 island (Vite, TypeScript), Tailwind/shadcn tokens.

## Global Constraints

- **No backend create path change.** `coerce_create_args/1` reads only `:flavor/:name/:cwd/:with_pty/:from` (`agent_create.ex:64`) — do NOT add fields to the create payload; unwired contract fields are read-only coverage, never inputs (silent-drop trap).
- **No new route, no nav change, no `styles.css` restyle.** Reuse `/identities/agents/new` + `/identities/agents/:uri`.
- **No CapBAC / AgentManifest schema change** (discuss-first per handoff §6).
- **No JS test runner exists** (only `vite build` + `tsc`). Verify React via `pnpm exec tsc --noEmit` + `pnpm build` + headless screenshot through **agent-browser** (repo convention `feedback_agent_browser_debug`; remote URL host `100.64.0.27`). Verify Elixir via `mix test`.
- **`pnpm` not `npm`; `uv run` not `python`.** Format only touched files (`mix format <file>`).
- **URI shape is workspace-first** `entity://<workspace>/agent/<name>` (`uri.ex` `agent/2`).
- Branch: `socialware-creator-agent-config`. Spec: `docs/superpowers/specs/2026-06-23-socialware-creator-agent-config-prd.md`.

---

### Task 1: Fix the React preview-URI bug

`previewAgentUri` builds a **type-first** URI (`entity://agent/<ws>/<name>`), contradicting `uri.ex` (workspace-first) and the correct server value `state.preview_uri` (`identity_data.ex preview_agent_uri`). Fix the order.

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Identities.tsx:508-511`

**Interfaces:**
- Produces: `previewAgentUri(workspaceUri, name) -> "entity://<workspace>/agent/<name>"` (now matches backend).

- [ ] **Step 1: Correct the URI segment order**

```tsx
function previewAgentUri(workspaceUri: string | null | undefined, name: string) {
  const workspace = workspaceUri?.replace("workspace://", "") || "system"
  return `entity://${workspace}/agent/${name}`
}
```

- [ ] **Step 2: Typecheck + build**

Run: `cd apps/ezagent_plugin_world/assets && pnpm exec tsc --noEmit && pnpm build`
Expected: no type errors; build succeeds.

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_plugin_world/assets/src/components/Identities.tsx
git commit -m "fix(world): agent preview URI is workspace-first (was type-first)"
```

---

### Task 2: Add flavor-required-cwd metadata to the create-form state

The form must mark `project_cwd` required only for the flavors that need it (cc/codex always; echo only with PTY; curl/np never — `agent_create.ex:144-157`). Expose this as state so the React label is correct and can't be hand-guessed.

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex:88-96` (the `agent_new_form` builder)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs`

**Interfaces:**
- Produces: `agent_new_form` state gains `"cwd_required_flavors" => ["cc", "codex"]` and `"cwd_required_with_pty_flavors" => ["echo"]` (string lists the React form reads).

- [ ] **Step 1: Write the failing test**

```elixir
# in apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs
test "agent_new_form state advertises which flavors require project_cwd" do
  ws = Ezagent.URI.workspace("acme")
  state = Ezagent.World.IdentityData.build(%{component: "agent_new_form"}, ws, ws, MapSet.new())

  assert "cc" in state["cwd_required_flavors"]
  assert "codex" in state["cwd_required_flavors"]
  assert "echo" in state["cwd_required_with_pty_flavors"]
  refute "curl" in state["cwd_required_flavors"]
end
```

> If `IdentityData.build/4`'s arity/signature differs, open `identity_data.ex` and match the existing public builder entrypoint used by other `*_test.exs` cases; keep the assertions.

- [ ] **Step 2: Run it, expect fail**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs -k "require project_cwd"`
Expected: FAIL (keys absent).

- [ ] **Step 3: Add the metadata in the builder**

```elixir
# identity_data.ex — agent_new_form clause (currently lines 88-96)
defp component_state(%{component: "agent_new_form"}, base, workspace_uri, _caller, _caps) do
  flavors = list_flavors()
  default_flavor = if "cc" in flavors, do: "cc", else: List.first(flavors) || "cc"

  base
  |> Map.put("flavors", flavors)
  |> Map.put("default_flavor", default_flavor)
  |> Map.put("preview_uri", preview_agent_uri(workspace_uri, ""))
  # Mirrors validate_cwd_for_flavor/3 in agent_create.ex:144-157 (UI hint only;
  # the authoritative check is server-side on submit / fail-closed).
  |> Map.put("cwd_required_flavors", ["cc", "codex"])
  |> Map.put("cwd_required_with_pty_flavors", ["echo"])
end
```

- [ ] **Step 4: Run the test, expect pass**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs -k "require project_cwd"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
mix format apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex
git add apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs
git commit -m "feat(world): advertise flavor-required project_cwd in agent_new_form state"
```

---

### Task 3: Re-shape AgentNewForm — supported fields + requested-caps + Contract coverage list

Relabel CWD→`project_cwd` with the flavor-aware required marker; relabel caps "Requested caps" with light client validation; add a read-only Contract coverage list. The submit payload key stays `cwd`/`caps` (backend contract unchanged).

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Identities.tsx:51-77` (state type), `:294-356` (AgentNewForm)

**Interfaces:**
- Consumes: `state.cwd_required_flavors`, `state.cwd_required_with_pty_flavors` (Task 2), `state.create_error` (Task 4).
- Produces: submit payload unchanged `{flavor, name, cwd, caps, with_pty}`.

- [ ] **Step 1: Extend the state type**

```tsx
// add to IdentitiesState (Identities.tsx:51-77)
  cwd_required_flavors?: string[]
  cwd_required_with_pty_flavors?: string[]
  create_error?: string
```

- [ ] **Step 2: Replace AgentNewForm body**

```tsx
function AgentNewForm({state, onCreateAgent}: {state: IdentitiesState; onCreateAgent?: (payload: Record<string, unknown>) => void}) {
  const [form, setForm] = React.useState({
    flavor: state.default_flavor || state.flavors?.[0] || "cc",
    name: "",
    cwd: "",
    caps: "",
    with_pty: false,
  })
  const preview = form.name ? previewAgentUri(state.workspace_uri, form.name) : state.preview_uri || "<agent-uri>"
  const fieldLabel = "grid gap-1 text-xs font-medium text-muted-foreground"

  const cwdRequired =
    (state.cwd_required_flavors || ["cc", "codex"]).includes(form.flavor) ||
    (form.with_pty && (state.cwd_required_with_pty_flavors || ["echo"]).includes(form.flavor))

  // Light client validation; the authoritative parse runs server-side on submit.
  const capTokens = form.caps.split(",").map((c) => c.trim()).filter(Boolean)
  const capsInvalid = capTokens.some((t) => !/^[a-z_]+\.[a-z_]+$/.test(t))

  return (
    <section className={surfaceClass} data-world-component="agent_new_form" aria-labelledby="agent-new-title">
      <SectionHeader eyebrow="Provision" title="New agent" />
      {state.create_error && (
        <p className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive" role="alert">
          {state.create_error}
        </p>
      )}
      <form
        id="world-agent-new-form"
        className="grid gap-3 sm:grid-cols-2"
        onSubmit={(event) => {
          event.preventDefault()
          onCreateAgent?.(form)
        }}
      >
        <label className={fieldLabel}>
          <span>Flavor</span>
          <Select value={form.flavor} onChange={(event) => setForm({...form, flavor: event.target.value})}>
            {(state.flavors || [form.flavor]).map((flavor) => (
              <option key={flavor} value={flavor}>{flavor}</option>
            ))}
          </Select>
        </label>
        <label className={fieldLabel}>
          <span>Name *</span>
          <Input value={form.name} onChange={(event) => setForm({...form, name: event.target.value})} placeholder="storefront-greeter" />
        </label>
        <label className={fieldLabel}>
          <span>project_cwd {cwdRequired ? "*" : "(optional for this flavor)"}</span>
          <Input value={form.cwd} onChange={(event) => setForm({...form, cwd: event.target.value})} placeholder="/srv/acme/storefront" />
        </label>
        <label className={fieldLabel}>
          <span>Requested caps</span>
          <Input value={form.caps} onChange={(event) => setForm({...form, caps: event.target.value})} placeholder="chat.send, workspace.read" />
          <span className={capsInvalid ? "text-xs text-destructive" : "text-xs text-muted-foreground"}>
            {capsInvalid ? "格式应为 behavior.action（逗号分隔）" : "请求 → 系统按 CapBAC 授予（详情页显示 granted）"}
          </span>
        </label>
        <label className="flex items-center gap-2 text-sm text-foreground">
          <input type="checkbox" checked={form.with_pty} onChange={(event) => setForm({...form, with_pty: event.target.checked})} />
          <span>With PTY</span>
        </label>
        <div className="flex items-center justify-between gap-3 sm:col-span-2">
          <code className={codeClass}>{preview}</code>
          <Button type="submit" disabled={!form.name || (cwdRequired && !form.cwd) || capsInvalid}>
            <Plus aria-hidden="true" />
            Create
          </Button>
        </div>
      </form>
      <ContractCoverage />
    </section>
  )
}

function ContractCoverage() {
  const pending: Array<[string, string]> = [
    ["soul · skills · tools · lifecycle", "Pending backend approval"],
    ["executor extras (settings/mcp/model/provider)", "Pending backend approval"],
    ["fork (parent template)", "Deferred"],
  ]
  return (
    <div className="space-y-2 border-t border-border pt-3">
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Contract coverage (read-only)</p>
      <ul className="space-y-1">
        {pending.map(([field, badge]) => (
          <li className="flex items-center justify-between gap-3 text-sm text-muted-foreground" key={field}>
            <span>{field}</span>
            <span className="rounded-full border border-border bg-muted/50 px-2 py-0.5 text-xs">{badge}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}
```

- [ ] **Step 3: Typecheck + build**

Run: `cd apps/ezagent_plugin_world/assets && pnpm exec tsc --noEmit && pnpm build`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_plugin_world/assets/src/components/Identities.tsx
git commit -m "feat(world): contract-shaped agent create form + read-only coverage list"
```

---

### Task 4: Surface create failures as visible operator messages (no silent drop)

Today the create-error reason is only written to `data-last-dispatch` on `#world-root` (`world_live.ex:396`) — not shown in the form. Map the reason to a friendly message and feed it back into the `agent_new_form` state so the re-rendered form shows it.

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex` (add `create_error_message/1` + thread `create_error`)
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:365-402` (error branch)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs`

**Interfaces:**
- Produces: `IdentityData.create_error_message(reason) -> String.t()`; `agent_new_form` state includes `"create_error"` when present.

- [ ] **Step 1: Confirm the re-render channel**

Run: `grep -nE "build_world_state|world_state|IdentityData|agent_new_form|current_create_error" apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex | head`
Confirm how the route's world_state is rebuilt on the error re-render, and that a socket assign can reach the `agent_new_form` builder. If the builder cannot receive a socket value directly, pass it via the `base` map the builder already receives (the route assigns flow into `base`).

- [ ] **Step 2: Write the failing test for the mapping**

```elixir
test "create_error_message maps backend reasons to operator-facing text" do
  assert Ezagent.World.IdentityData.create_error_message(:cwd_required_for_cc) =~ "project_cwd"
  assert Ezagent.World.IdentityData.create_error_message(:cwd_required_for_codex) =~ "project_cwd"
  assert Ezagent.World.IdentityData.create_error_message({:bad_name, "x y"}) =~ "name"
  assert Ezagent.World.IdentityData.create_error_message({:bad_flavor, "zz"}) =~ "zz"
  assert Ezagent.World.IdentityData.create_error_message({:already_exists, "entity://acme/agent/g"}) =~ "已存在"
  assert is_binary(Ezagent.World.IdentityData.create_error_message({:weird, :tuple}))
end
```

- [ ] **Step 3: Run it, expect fail**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs -k "operator-facing"`
Expected: FAIL (function undefined).

- [ ] **Step 4: Implement the mapping (public fn in identity_data.ex)**

```elixir
@doc "Map a create_agent/grant failure reason to an operator-facing message."
@spec create_error_message(term()) :: String.t()
def create_error_message(:cwd_required_for_cc), do: "cc 需要 project_cwd（工作目录）"
def create_error_message(:cwd_required_for_codex), do: "codex 需要 project_cwd（工作目录）"
def create_error_message(:cwd_required_for_echo_with_pty), do: "echo + PTY 需要 project_cwd"
def create_error_message({:cwd_not_a_dir, cwd}), do: "project_cwd 不是有效目录：#{cwd}"
def create_error_message(:flavor_required), do: "请选择 flavor"
def create_error_message(:name_required), do: "请填写 name"
def create_error_message({:bad_name, name}), do: "name 不合法（字母数字开头，仅 字母/数字/-/_）：#{name}"
def create_error_message({:bad_flavor, flavor}), do: "不支持的 flavor：#{flavor}"
def create_error_message({:already_exists, uri}), do: "同名 agent 已存在：#{uri}"
def create_error_message({:bad_workspace_uri, _}), do: "无效的 workspace"
def create_error_message(other), do: "创建失败：#{inspect(other)}"
```

- [ ] **Step 5: Thread it into the form state**

In the `agent_new_form` builder, read an optional create_error carried in `base` (set by world_live on the error re-render) and surface it:

```elixir
# append inside the agent_new_form clause, before the closing
|> then(fn s ->
  case Map.get(base, :create_error) do
    nil -> s
    reason -> Map.put(s, "create_error", create_error_message(reason))
  end
end)
```

In `world_live.ex` `dispatch_agent_create/2` error branch, stash the reason so the route rebuild includes it (assign name per the channel confirmed in Step 1), e.g.:

```elixir
{:error, reason} ->
  {:noreply,
   socket
   |> assign(:agent_create_error, reason)
   |> assign(:last_dispatch_status, "error:#{reason_to_string(reason)}")}
```

and include `:agent_create_error` in the `base` map handed to `IdentityData` for the `agent_new_form` route (drop it on success / navigation).

- [ ] **Step 6: Run the mapping test, expect pass**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs -k "operator-facing"`
Expected: PASS.

- [ ] **Step 7: Typecheck React, build, commit**

```bash
cd apps/ezagent_plugin_world/assets && pnpm exec tsc --noEmit && pnpm build && cd -
mix format apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex
git add apps/ezagent_plugin_world/lib apps/ezagent_plugin_world/test
git commit -m "feat(world): surface agent-create failures as operator messages (no silent drop)"
```

---

### Task 5: Detail page — labeled readable fields + requested/granted, replacing the JSON dump

Replace the `<pre>{JSON.stringify(...)}` block (`Identities.tsx:287-289`) with labeled fields, and add granted caps + project_cwd + config_dir + template/version to the `agent_detail` state.

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex:75-86` (agent_detail builder)
- Modify: `apps/ezagent_plugin_world/assets/src/components/Identities.tsx:275-292` (AgentDetail)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs`

**Interfaces:**
- Produces: `agent_detail` state gains `"granted_caps" => [%{...}]`, `"project_cwd" => string|nil`, `"config_dir" => string|nil`, `"source_template" => string|nil`.

- [ ] **Step 1: Write the failing test**

```elixir
test "agent_detail state includes granted caps + executor fields (labeled, not raw dump)" do
  # build a real cc agent via the create path, then read its detail state
  {:ok, agent_uri} = TestSupport.create_cc_agent("detail-probe")  # helper used by sibling tests
  state = Ezagent.World.IdentityData.build(%{component: "agent_detail", entity_uri: agent_uri}, nil, nil, MapSet.new())

  assert is_list(state["granted_caps"])
  assert Map.has_key?(state, "project_cwd")
  assert Map.has_key?(state, "config_dir")
end
```

> Match the actual public `build/4` signature + an existing agent-creation test helper in this file's sibling tests; keep the assertions on the three new keys.

- [ ] **Step 2: Run it, expect fail**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs -k "labeled"`
Expected: FAIL (keys absent).

- [ ] **Step 3: Extend the agent_detail builder**

```elixir
defp component_state(%{component: "agent_detail", entity_uri: agent_uri}, base, _workspace, caller, caps) do
  base
  |> Map.put("agent_uri", encode_uri(agent_uri))
  |> Map.put("agent_status", agent_status(agent_uri))
  |> Map.put("bridge", bridge_entry(agent_uri))
  |> Map.put("granted_caps", list_entity_caps(agent_uri, caller, caps))
  |> Map.put("project_cwd", agent_template_field(agent_uri, "project_cwd"))
  |> Map.put("config_dir", agent_template_field(agent_uri, "config_dir"))
  |> Map.put("source_template", agent_template_uri(agent_uri))
end
```

Add private helpers `agent_template_field/2` (reads the registered per-agent template's content field, returns nil if direct-spawn) and `agent_template_uri/1` (returns the template URI string or nil), guarded with `rescue -> nil`, reusing the same read path other builders use (`list_entity_caps/3` is already private here). Where the template read path is unclear, mirror `list_api_keys/3`'s dispatch shape against the agent's template registry; if no template is registered (curl/np), return nil — that's the "direct-spawn" case the UI renders.

- [ ] **Step 4: Replace the AgentDetail render**

```tsx
function AgentDetail({state}: {state: IdentitiesState}) {
  const status = (state.agent_status || {}) as Record<string, unknown>
  const caps = Array.isArray(state.caps) ? state.caps : []
  const grantedCaps = (state as Record<string, unknown>).granted_caps as CapRow[] | undefined
  const rows: Array<[string, string]> = [
    ["Phase", String(status.phase || "unknown")],
    ["Flavor", String(status.flavor || "unknown")],
    ["project_cwd", String((state as Record<string, unknown>).project_cwd || "—")],
    ["config_dir", String((state as Record<string, unknown>).config_dir || "—")],
    ["Version / template", String((state as Record<string, unknown>).source_template || "direct-spawn (no template)")],
    ["Bridge", state.bridge ? "connected" : "not connected"],
  ]
  return (
    <section className={surfaceClass} data-world-component="agent_detail" aria-labelledby="agent-detail-title">
      <SectionHeader eyebrow="Agent" title="Agent detail" />
      <code className={uriClass}>{state.agent_uri}</code>
      <dl className="grid grid-cols-1 gap-2 sm:grid-cols-2">
        {rows.map(([label, value]) => (
          <div className="flex justify-between gap-3 rounded-md border border-border bg-background px-3 py-2" key={label}>
            <dt className="text-xs font-medium text-muted-foreground">{label}</dt>
            <dd className="text-sm text-foreground">{value}</dd>
          </div>
        ))}
      </dl>
      <div>
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Granted caps (CapBAC)</p>
        <div className="flex flex-wrap gap-2 pt-1">
          {(grantedCaps || []).map((c, i) => (
            <span className="rounded-md border border-border bg-muted/50 px-2 py-0.5 font-mono text-xs" key={i}>
              {[c.behavior, c.action].filter(Boolean).join(".")}
            </span>
          ))}
          {(grantedCaps || []).length === 0 && <span className="text-sm text-muted-foreground">none</span>}
        </div>
      </div>
      <p className="text-xs text-muted-foreground">
        派生/编译配置（CLAUDE.md · settings.json · system_prompt）只读，由 flavor.compile 生成（G-INV-2 / G-INV-5）。
      </p>
    </section>
  )
}
```

- [ ] **Step 5: Run test, typecheck, build**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs -k "labeled"`
Expected: PASS.
Run: `cd apps/ezagent_plugin_world/assets && pnpm exec tsc --noEmit && pnpm build`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
mix format apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex
git add apps/ezagent_plugin_world/lib apps/ezagent_plugin_world/test apps/ezagent_plugin_world/assets/src/components/Identities.tsx
git commit -m "feat(world): labeled agent detail (granted caps + executor) replacing JSON dump"
```

---

### Task 6: E2E verification + DoD screenshots

Prove the real create loop for two flavors, a real failure message, and capture the screenshots the handoff DoD requires.

**Files:** none (verification + assets under `docs/superpowers/notes/`).

- [ ] **Step 1: Full focused test + build gate**

Run: `mix test apps/ezagent_plugin_world/test/ezagent/world/identity_data_test.exs && cd apps/ezagent_plugin_world/assets && pnpm exec tsc --noEmit && pnpm build`
Expected: all green.

- [ ] **Step 2: Start the server, drive the UI via agent-browser**

Run the dev server (`iex -S mix phx.server`), open `/identities/agents/new` via agent-browser (host `100.64.0.27`). Create a **cc** agent with a valid `project_cwd` → expect redirect to the detail page; capture the agent URI/status. Create a **curl** (or echo) agent with empty cwd → expect success (cwd not required). Screenshot both create form + detail page.

- [ ] **Step 3: Capture a real failure message**

Submit a cc create with empty `project_cwd` (bypass the disabled button by clearing cwd after typing) → expect the visible "cc 需要 project_cwd" message, no navigation, no silent drop. Screenshot.

- [ ] **Step 4: Save evidence + commit**

```bash
# save screenshots under docs/superpowers/notes/2026-06-23-agent-config-mvp-evidence/
git add docs/superpowers/notes/2026-06-23-agent-config-mvp-evidence
git commit -m "docs(world): agent-config MVP E2E evidence (create cc+curl, failure feedback, detail)"
```

- [ ] **Step 5: DoD checklist (from spec §7)** — confirm each: create-page screenshot ✓; real create for two flavors ✓; failure messages visible (no silent drop) ✓; detail labeled (not JSON) + requested/granted distinct ✓; coverage list with no submittable inputs ✓; no derived-config editable ✓; no new route / no schema/CapBAC change ✓; focused tests green ✓.

---

## Self-Review

**Spec coverage:** §6 MVP bullets → Task 3 (supported-only form + coverage), Task 2+3 (flavor-required cwd), Task 3 (requested-caps parse/validate + requested/granted label), Task 4 (failure feedback no-silent-drop), Task 5 (labeled detail replacing JSON dump + granted caps), Task 1 (React URI fix), Task 6 (two-flavor real create + screenshots). §7 DoD → Task 6 Step 5. §5 extension (E1–E4) → intentionally OUT (handed to Allen). No gaps.

**Placeholders:** none — every code step has concrete code; the two builder-helper reads (Task 5 Step 3) and the re-render channel (Task 4 Step 1) are explicit investigation steps with a named fallback, not "implement later."

**Type consistency:** payload keys stay `{flavor,name,cwd,caps,with_pty}` end-to-end (form → `onCreateAgent` → `world:dispatch` → `dispatch_agent_create` → `create_agent/3`); new state keys `cwd_required_flavors`, `create_error`, `granted_caps`, `project_cwd`, `config_dir`, `source_template` are produced in `identity_data.ex` and consumed in `Identities.tsx` with matching names.
