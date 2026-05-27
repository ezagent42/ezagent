# SPEC — Agent Bridge Domain Extraction

**Status:** r2 (codex brainstorm 4 HIGH + 8 MED + 3 LOW + 5 missed items addressed). 2026-05-27.

**r2 revision log (codex brainstorm findings):**
- CRIT-1: §3.7 dual-mount/dual-topic adapter resolution made safe — `Ezagent.AgentBridge.Channel.join/3` MUST verify the topic URI segment matches `socket.assigns.agent_uri` (the token-authenticated URI), reject mismatches.
- HIGH-1: Payload `event_type` enum trimmed to `:chat_send | :mention_failed | :system` — `slice_change` and audit push are NOT on the bridge channel today; orchestrator MCP transport is out of scope per §7.
- HIGH-2: Adapter callback `handle_reply/2` replaced with `handle_client_event/3` to match Phoenix.Channel `handle_in/3` shape — `(event :: String.t(), params :: map(), socket :: Phoenix.Socket.t()) :: {:reply, {:ok | :error, map()}, socket} | {:noreply, socket}`.
- HIGH-3: `Ezagent.Plugin.agent_flavors/0` adapter field renamed to OPTIONAL `bridge_adapter` (default `nil`) so existing echo/curl/np declarations don't break. cc + future codex set it; non-bridge flavors leave it nil.
- HIGH-4: Field name corrected — `flavor: "cc"` (matches `ezagent_core/lib/ezagent/plugin.ex`), not `prefix: "cc_"`. Agent URI prefix derived from flavor by convention (`"cc_*"` ↔ `flavor: "cc"`).
- MED-2: §3.8 grep replaced with AST scan via `Code.string_to_quoted!/1` walking each domain `lib/**/*.ex` and flagging `alias` + `Module.Foo` references that point at `EzagentPluginCc.*`. Excludes moduledocs / `@doc` comments / string literals.
- MED-6: §4 PR sequence: PR-F (Domain.Agent PTY-detection) marked as parallel to B→E (no dependency); revised dependency graph in §4.1.
- MED-7: PR-B made the SoT for Registry/TokenStore promotion; PR-C (Socket/Channel) can run in parallel with PR-D (chat.ex rewrite) AFTER PR-B lands.
- MED-8: §12 added — "Adapter author checklist" with skeleton.
- Missed items addressed: §3.9 BridgeRegistry PubSub topic rename plan; §3.10 McpConfigWriter `/cc_socket/websocket` → `/agent_bridge/websocket` switchover; §3.11 Python compatibility matrix; §3.12 app boot order race + AdapterRegistry deferred-registration; §3.13 multi-connection semantics (single agent URI = single channel).
**Tier:** Multi-tier — extract bridge primitives from `ezagent_plugin_cc` into a new domain app `ezagent_domain_agent_bridge`; rewrite `Ezagent.Behavior.Chat` Entity.Agent receiver branch to use the domain facade; close the `ezagent_domain_chat → ezagent_plugin_cc` layer-violation.
**Trigger:** Allen 2026-05-27 03:25 directive — codex plugin (codex TUI agent) needs to share the bridge infrastructure with cc plugin. Today, `EzagentPluginCc.{BridgeRegistry,TokenStore,Socket,Channel}` are cc-specific by name AND by call-site coupling — domain_chat reaches into them via `# layer-violation-exempt` marker. Future codex plugin would either re-implement the same surface or take a transitive cc dependency. Both fail the plugin-isolation north star.
**Companion:** `2026-05-27-agent-bridge-domain-extraction.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Parent / related:**
- `docs/reviews/2026-05-27-plugin-codex-architecture-review.md` (Claude main-agent review, in `.worktrees/plugin-codex/`) — the 10 risks (R1-R10) + 7-PR decomposition recommendation that drove this SPEC.
- `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md` — the declarative `Ezagent.Plugin` behaviour that this SPEC's new `agent_flavors/0` field extends.
- `docs/superpowers/specs/2026-05-21-domain-pty-architecture.md` — the precedent for promote-to-domain pattern (PTY was extracted out of cc plugin into `Ezagent.Domain.Pty` exactly the same way this extracts the Bridge).

**Predecessor memories:**
- `feedback_let_it_crash_no_workarounds` — backward-compat alias for `cc:bridge:*` topic is the ONLY shim (justified by R2: in-flight Python sidecars on live cc agents); everything else is structural.
- `feedback_north_star_plugin_isolation` — the entire point.
- `feedback_subagent_must_load_project_skills` — impl subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_review_every_pr` — every PR in the 7-PR sequence gets `/codex:adversarial-review`.

---

## 1. Problem in one paragraph

`Ezagent.Behavior.Chat` Entity.Agent receiver branch at `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:531` directly calls `EzagentPluginCc.BridgeRegistry.lookup/1` and sends `{:to_claude, %{"content" => _, "meta" => _}}` — a cc-specific message + payload shape. `apps/ezagent_domain_chat/mix.exs:55-56` declares `{:ezagent_plugin_cc, in_umbrella: true}` with a `# layer-violation-exempt` marker. `apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_socket.ex:43` aliases `EzagentPluginCc.TokenStore` for orchestrator socket auth. `apps/ezagent_domain_chat/lib/ezagent/domain/agent.ex:84-131` hardcodes the flavor string `"cc"` to delegate lifecycle to Domain.Pty. All four are structural debts that block adding a second agent flavor (codex) without either re-implementing the same bridge surface or taking a transitive cc dep — both violate the plugin-isolation north star.

## 2. Goals

1. **Promote the bridge surface to Domain layer**: `Ezagent.AgentBridge.{Registry, TokenStore, Socket, Channel, Adapter}` lives in a new umbrella app `ezagent_domain_agent_bridge` at Domain tier.
2. **Generic payload schema**: `Ezagent.Behavior.Chat` Entity.Agent receiver constructs a flavor-neutral payload struct; the per-flavor adapter (registered via the plugin's `agent_flavors/0` declaration) converts to the flavor-specific WS push payload.
3. **Remove the `ezagent_plugin_cc` dep from `ezagent_domain_chat`**: `mix.exs` loses the `# layer-violation-exempt` line; `layer_purity_test` strengthened to grep-check in-code `EzagentPluginCc.*` references.
4. **Flavor-by-behavior, not flavor-by-string**: `Domain.Agent.lifecycle_status/1` detects PTY-alive via `Ezagent.Domain.Pty.alive?/1`, not flavor-string switch. Any PTY-backed agent (cc, codex, future) gets terminal UI for free.
5. **Backward-compat for in-flight cc bridges**: existing Python sidecars connected to `/cc_socket` joining `cc:bridge:<uri>` continue working via a deprecation-window alias. New connections use `/agent_bridge` + `agent_bridge:<flavor>:<uri>`.

## 3. Design

### 3.1 New umbrella app: `apps/ezagent_domain_agent_bridge/`

Three-tier placement: Tier-2 Domain. Depends only on `ezagent_core` + (potentially) other `ezagent_domain_*` apps. NO plugin deps.

```
apps/ezagent_domain_agent_bridge/
├── lib/
│   ├── ezagent_domain_agent_bridge.ex            (facade)
│   ├── ezagent_domain_agent_bridge/
│   │   └── application.ex                        (supervisor for Registry, TokenStore, Socket endpoint)
│   └── ezagent/
│       └── agent_bridge/
│           ├── registry.ex                       (ETS-backed agent_uri → channel_pid lookup)
│           ├── token_store.ex                    (per-agent connect tokens persisted to YAML — same on-disk shape as today's cc-channels.yaml, just module location promoted)
│           ├── socket.ex                         (Phoenix.Socket entry point at /agent_bridge)
│           ├── channel.ex                        (Phoenix.Channel hosting per-agent topic)
│           ├── adapter.ex                        (@behaviour for per-flavor adapter — Plugin author implements)
│           ├── adapter_registry.ex               (flavor → adapter module, populated from Ezagent.Plugin's agent_flavors/0)
│           └── payload.ex                        (the generic payload struct + builders)
```

### 3.2 Generic payload struct (`Ezagent.AgentBridge.Payload`)

```elixir
defmodule Ezagent.AgentBridge.Payload do
  @moduledoc """
  Flavor-neutral message envelope from Ezagent → Agent's TUI bridge.
  The flavor-specific adapter converts this to (claude channel notification | codex turn/start | etc.).
  """

  @enforce_keys [:message_id, :session_uri, :sender_uri, :text, :event_type]
  defstruct [
    :message_id,         # binary — UUID
    :session_uri,        # %URI{} — source session
    :sender_uri,         # %URI{} — sender (user/agent URI)
    :text,               # binary — message text content
    :event_type,         # :chat_send | :mention_failed | :system  (codex r2 trimmed; slice_change + audit NOT on bridge today; orchestrator MCP out of scope §7)
    attachments: [],     # [%{path: String.t(), mime: String.t()}] — flat Records per Invariant #3 (no nested values)
    meta: %{}            # %{String.t() => String.t()} — flat string-keyed Record per Invariant #3
  ]

  @type t :: %__MODULE__{...}
end
```

**Invariant #3 (Channel meta is Record<string, string>)**: the `meta` field MUST be a flat string-keyed map of string values. The cc adapter relies on this — Claude TUI silently drops notifications with nested meta. Future codex adapter must accept the same constraint OR document an explicit relaxation.

### 3.3 The Adapter behaviour (`Ezagent.AgentBridge.Adapter`)

Each plugin that ships an agent flavor implements:

```elixir
defmodule Ezagent.AgentBridge.Adapter do
  @moduledoc "Per-flavor adapter that converts generic AgentBridge.Payload to the flavor-specific TUI push."

  @callback flavor() :: String.t()                 # e.g. "cc", "codex" — matches agent_flavors/0 field
  @callback agent_uri_prefix() :: String.t()       # e.g. "cc_", "codex_" — used to derive flavor from URI
  @callback deliver(payload :: Ezagent.AgentBridge.Payload.t(), channel_pid :: pid()) :: :ok | {:error, term()}
  # codex r2 HIGH-2: replaces `handle_reply/2`. This matches Phoenix.Channel's
  # `handle_in/3` shape — adapter receives ALL client-side events (the
  # "reply" tool from cc/codex, plus future custom events) and returns the
  # Phoenix reply tuple. Channel module owns no event-type knowledge.
  @callback handle_client_event(event :: String.t(), params :: map(), socket :: Phoenix.Socket.t()) ::
              {:reply, {:ok | :error, map()}, Phoenix.Socket.t()}
              | {:noreply, Phoenix.Socket.t()}
  @callback socket_path() :: String.t()            # e.g. "/cc_socket" (backward-compat) or "/agent_bridge" (new)
  @callback channel_topic_prefix() :: String.t()   # e.g. "cc:bridge:" (backward-compat) or "agent_bridge:cc:" (new)

  @optional_callbacks [socket_path: 0, channel_topic_prefix: 0]
end
```

Plugin's `agent_flavors/0` declaration (per the `Ezagent.Plugin` authoring contract) gains an OPTIONAL `bridge_adapter` field. codex r2 HIGH-3 correction: existing flavors (echo/curl/np) already declare `agent_flavors/0` WITHOUT a bridge — the new field MUST be optional (default `nil`) so they don't break.

```elixir
@impl Ezagent.Plugin
def agent_flavors do
  [
    %{
      flavor: "cc",                                  # codex r2 HIGH-4: field is `flavor`, NOT `prefix`
      kind: Ezagent.Entity.Agent,
      template_class: Ezagent.PluginCc.Template.CcAgent,
      bridge_adapter: EzagentPluginCc.BridgeAdapter  # ← NEW optional field; nil for non-bridge flavors
    }
  ]
end
```

The framework reads `agent_flavors/0` at plugin boot. For each entry where `bridge_adapter != nil`, register `flavor → adapter_module` in `Ezagent.AgentBridge.AdapterRegistry`. For `nil` entries (echo/curl/np), skip silently. No imperative `register/2` calls.

### 3.4 `Chat.invoke(:receive, Entity.Agent, ...)` rewritten

Today (`chat.ex:531`):

```elixir
payload = %{"content" => text_with_hint, "meta" => meta}
case EzagentPluginCc.BridgeRegistry.lookup(ctx.self_uri) do
  {:ok, channel_pid} -> send(channel_pid, {:to_claude, payload})
  :error -> Logger.warning(...)
end
```

After SPEC:

```elixir
payload = %Ezagent.AgentBridge.Payload{
  message_id: msg.id,
  session_uri: msg.session_uri,
  sender_uri: msg.sender,
  text: text_with_hint,
  event_type: :chat_send,
  meta: meta  # already string-keyed Record<string, string>
}

Ezagent.AgentBridge.deliver(ctx.self_uri, payload)
```

`Ezagent.AgentBridge.deliver/2` (in the new app's facade) handles registry lookup + adapter resolution + delivery + telemetry. No `EzagentPluginCc.*` reference in `chat.ex` after this change.

### 3.5 cc Plugin shrinks to plugin-specific surfaces

After SPEC, `ezagent_plugin_cc/lib/` contains ONLY:
- `EzagentPluginCc.Template.CcAgent` — cc Template Class (unchanged, but its `instantiate/3` now resolves the adapter via `AgentBridge.AdapterRegistry`)
- `EzagentPluginCc.McpConfigWriter` — cc-specific `.mcp.json` writer (unchanged)
- `EzagentPluginCc.BridgeAdapter` (NEW) — `@behaviour Ezagent.AgentBridge.Adapter` impl that:
  - converts `Payload` to `%{"content" => _, "meta" => _}` shape Claude TUI expects
  - sends to channel pid via `send(pid, {:to_claude, _})`  
  - handles `reply` action from the WS (the existing `EzagentPluginCc.Channel.handle_in("reply", ...)` logic)
- `apps/ezagent_plugin_cc/python/ezagent_mcp_bridge.py` — cc Python sidecar (unchanged for backward-compat; new versions can target `/agent_bridge` directly)

Files DELETED from `ezagent_plugin_cc/lib/`:
- `EzagentPluginCc.BridgeRegistry` — promoted to `Ezagent.AgentBridge.Registry`
- `EzagentPluginCc.TokenStore` — promoted to `Ezagent.AgentBridge.TokenStore` (same YAML file path, same module API — just renamed)
- `EzagentPluginCc.Socket` — promoted to `Ezagent.AgentBridge.Socket`
- `EzagentPluginCc.Channel` — promoted to `Ezagent.AgentBridge.Channel`

### 3.6 `Domain.Agent.lifecycle_status/1` behavior-detection

Today (`agent.ex:84-131`):

```elixir
defp delegate_alive_status("cc", agent_uri) do
  # only "cc" flavor queries Domain.Pty
  if Code.ensure_loaded?(Ezagent.Domain.Pty) do
    case Ezagent.Domain.Pty.lookup(agent_uri) do ...
```

After SPEC:

```elixir
defp delegate_alive_status(_flavor, agent_uri) do
  # Behavior detection: any flavor whose agent has a live PTY is PTY-backed.
  if Code.ensure_loaded?(Ezagent.Domain.Pty) and Ezagent.Domain.Pty.alive?(agent_uri) do
    {:ok, pid} = Ezagent.Domain.Pty.lookup(agent_uri)
    %{phase: :alive, flavor: derive_flavor(agent_uri), detail: Ezagent.Domain.Pty.Server.status(pid)}
  else
    %{phase: :alive, flavor: derive_flavor(agent_uri), detail: %{}}
  end
end
```

Codex agents (`entity://agent/<ws>/codex_<name>`) automatically appear with PTY status in admin LV — no per-flavor `defp` clause needed.

### 3.7 Backward-compat: `/cc_socket` + `cc:bridge:*` alias

The cc Python sidecar at `apps/ezagent_plugin_cc/python/ezagent_mcp_bridge.py` hard-codes the WS URL `/cc_socket` and the topic `cc:bridge:<agent_uri>`. Running cc agents have persistent WS connections via this path. If the refactor changes the path, every running agent's bridge breaks until its Python sidecar restarts.

**Strategy**: Phoenix Socket supports multiple `channel` route definitions on the same socket module. The new `Ezagent.AgentBridge.Socket` defines:

```elixir
channel "agent_bridge:cc:*", Ezagent.AgentBridge.Channel
channel "cc:bridge:*", Ezagent.AgentBridge.Channel   # ← backward-compat alias; deprecate over 2 releases
```

The Phoenix endpoint mounts BOTH the new path `/agent_bridge` AND the legacy `/cc_socket` for one deprecation window:

```elixir
socket "/agent_bridge", Ezagent.AgentBridge.Socket
socket "/cc_socket", Ezagent.AgentBridge.Socket     # ← legacy alias
```

**CRIT-1 (codex r2)**: `Channel.join/3` MUST verify that the topic's URI segment matches `socket.assigns.agent_uri` (set by `Socket.connect/3` via TokenStore.lookup_by_token/1). This closes the spoof vector where a forged Channel could join a topic for a DIFFERENT URI than the token authenticates. Concretely:

```elixir
@impl true
def join("agent_bridge:" <> rest, _params, socket) do
  with [_flavor, uri_str] <- String.split(rest, ":", parts: 2),
       {:ok, %URI{} = topic_uri} <- URI.new(uri_str),
       true <- URI.to_string(topic_uri) == URI.to_string(socket.assigns.agent_uri) do
    # ... legitimate join
  else
    _ -> {:error, %{reason: :topic_uri_does_not_match_authenticated_agent}}
  end
end

@impl true
def join("cc:bridge:" <> uri_str, params, socket) do
  # legacy topic shape — same URI verification, just different prefix split
  with {:ok, %URI{} = topic_uri} <- URI.new(uri_str),
       true <- URI.to_string(topic_uri) == URI.to_string(socket.assigns.agent_uri) do
    # ... legitimate join (delegates to cc flavor adapter)
  else
    _ -> {:error, %{reason: :topic_uri_does_not_match_authenticated_agent}}
  end
end
```

The adapter resolution from topic prefix becomes safe because: (a) topic prefix maps to a registered flavor, (b) URI in topic matches authenticated URI, (c) adapter `flavor/0` matches the flavor segment. Any mismatch → `:error` at join. After 2 release cycles + operator notification, the legacy mount + topic are removed.

### 3.8 Layer purity test strengthened — AST scan, not regex

codex r2 MED-2 correction: regex `EzagentPluginCc\.|alias\s+EzagentPluginCc` matches moduledocs, `@doc` strings, and string literals. False positives. r2 uses AST scanning via `Code.string_to_quoted!/1`:

```elixir
test "domain apps do not reference EzagentPluginCc in lib/ code" do
  for app <- list_apps(~r/^ezagent_domain_/) do
    lib_files = Path.wildcard("apps/#{app}/lib/**/*.ex")
    
    offending = Enum.filter(lib_files, fn path ->
      ast = path |> File.read!() |> Code.string_to_quoted!()
      ast_references_module?(ast, EzagentPluginCc)
    end)
    
    assert offending == [], "Domain app #{app}: #{inspect(offending)}"
  end
end

defp ast_references_module?(ast, module_root) do
  module_root_str = inspect(module_root)
  {_, found?} = Macro.prewalk(ast, false, fn
    {:__aliases__, _, segments}, _ ->
      alias_str = "Elixir." <> Enum.map_join(segments, ".", &to_string/1)
      {nil, alias_str == module_root_str or String.starts_with?(alias_str, module_root_str <> ".")}
    node, acc -> {node, acc}
  end)
  found?
end
```

This catches `alias EzagentPluginCc.X`, `EzagentPluginCc.Y`, `EzagentPluginCc.Z.f(...)` — all real code references. Misses doc-string mentions (which is correct — operators / comments can reference the deprecated module's history).

### 3.9 BridgeRegistry PubSub topic rename plan (codex r2 missed item)

Today `EzagentPluginCc.BridgeRegistry` broadcasts PubSub events on cc-named topics (e.g. `cc_bridge_registry:events`). LV consumers (admin/bridges panel) subscribe.

After PR-B promotion: topic becomes `ezagent_agent_bridge_registry:events`. LV consumers update accordingly. cc-flavor doesn't need to know — the registry is generic.

Deprecation window: PubSub broadcasts go to BOTH topics for 2 release cycles to give LV consumers time to migrate.

### 3.10 McpConfigWriter switchover

Today `EzagentPluginCc.McpConfigWriter.write_with_token!/1` produces a `.mcp.json` referencing `ws://.../cc_socket/websocket` + topic `cc:bridge:<agent_uri>`. After PR-C dual-mount:

- **New agent spawns** (Templates spawned AFTER PR-C lands): MCP config points to `/agent_bridge/websocket` + topic `agent_bridge:cc:<agent_uri>`.
- **Existing agent .mcp.json files**: not regenerated. Python sidecars continue using legacy path via the deprecation-window alias.
- **Operator-driven regeneration**: `mix ezagent.cc.regenerate_mcp_configs` mix task forces all `.mcp.json` files to be re-rendered with the new path. Optional.

The Template's `instantiate/3` reads the adapter's `socket_path/0` + `channel_topic_prefix/0` callbacks (per §3.3) to decide which path/topic to bake into the `.mcp.json`. cc's adapter returns the legacy values during the deprecation window; codex's adapter returns the new values from day one.

### 3.11 Python bridge compatibility matrix

| Python sidecar version | Server PR-C state | Behavior |
|---|---|---|
| Pre-PR-C (cc legacy: `/cc_socket` + `cc:bridge:*`) | Pre-PR-C | Works (unchanged) |
| Pre-PR-C (legacy) | Post-PR-C (dual-mount) | Works via backward-compat alias |
| Pre-PR-C (legacy) | Post-2-release-deprecation (alias removed) | BROKEN — sidecar must be updated |
| Post-PR-G (codex sidecar: `/agent_bridge` + `agent_bridge:codex:*`) | Post-PR-C | Works |
| Post-PR-G (codex) | Pre-PR-C | BROKEN — codex agent can't spawn on pre-AgentBridge code |

cc Python sidecars work continuously through the deprecation window. Operator scripts that spawn new cc agents post-PR-C can choose to regenerate `.mcp.json` to the new path (§3.10).

### 3.12 App boot order race — `AdapterRegistry` deferred registration (codex r2 missed item)

`Ezagent.AgentBridge.AdapterRegistry` is a GenServer started in `ezagent_domain_agent_bridge`'s supervisor at boot. cc plugin's `Application.start/2` registers cc adapter into it.

Race window: if a cc agent's PtyServer starts before cc plugin's `Application.start/2` completes, the adapter isn't registered yet. Then `AgentBridge.deliver/2` returns `{:error, :no_adapter}` for that cc agent until the adapter registers.

**Fix**: AdapterRegistry buffers `deliver/2` calls for unregistered flavors (bounded queue, 5s TTL). When the adapter registers, drain the buffer. After 5s without registration, drop with telemetry + log.

This is the canonical pattern from the existing `Ezagent.PendingDelivery` (cap-grant race fix from PR #408). Same mechanism, different actor type.

### 3.13 Multi-connection semantics

Today: one Phoenix.Channel pid per (Socket connection, topic) pair. If the same agent URI tries to open TWO bridges (e.g. cc + codex simultaneously), they'd share the same `agent_uri` but DIFFERENT topic prefixes (`agent_bridge:cc:<uri>` vs `agent_bridge:codex:<uri>`). Registry would have 2 entries for the same `agent_uri`.

**Decision**: one agent URI = one bridge connection. An agent is EITHER cc-flavor OR codex-flavor, never both. The URI prefix (`cc_*` vs `codex_*`) encodes the flavor (per §3.3 adapter `agent_uri_prefix/0`). AgentBridge.Registry rejects a second bind for the same URI.

`Channel.join/3` enforces this by checking the existing Registry entry for the URI on join — if a different flavor's pid is already bound, reject with `{:error, :uri_already_bound_to_different_flavor}`.

### 3.8 Layer purity test strengthened

`apps/ezagent_core/test/invariants/layer_purity_test.exs` gains a grep-based test:

```elixir
test "domain apps do not reference EzagentPluginCc.* in lib/ code" do
  for app <- list_apps(~r/^ezagent_domain_/) do
    lib_files = Path.wildcard("apps/#{app}/lib/**/*.ex")
    
    offending = Enum.filter(lib_files, fn path ->
      File.read!(path) =~ ~r/EzagentPluginCc\.|alias\s+EzagentPluginCc/
    end)
    
    assert offending == [],
           "Domain app #{app} references EzagentPluginCc in lib/ — promote to a Domain abstraction. Files: #{inspect(offending)}"
  end
end
```

After PR-D this test passes WITHOUT the `# layer-violation-exempt` mechanism — the test's exemption is removed for plugin_cc.

## 4. PR decomposition

7 PRs, in strict order. Each builds on the previous + ships independently green.

| PR | Title | Scope |
|---|---|---|
| **PR-A** | SPEC + adapter behaviour + new app shells | this doc + `Ezagent.AgentBridge.Adapter`/`AdapterRegistry`/`Payload` (empty implementations); `agent_flavors/0` adapter field declarable but unused yet. Zero behavioral change. |
| **PR-B** | Promote `TokenStore` + `Registry` from cc plugin to new domain app | move modules + tests; cc-side keeps thin shims delegating to new modules (backward-compat); YAML file path UNCHANGED (`~/.ezagent/<profile>/credentials/cc-channels.yaml` stays — just module location promoted). |
| **PR-C** | Promote `Socket` + `Channel`; wire dual-mount for backward-compat | new `/agent_bridge` + alias `/cc_socket`; new `agent_bridge:cc:*` topic + alias `cc:bridge:*`. Existing Python sidecars continue working. |
| **PR-D** | Rewrite `Chat.receive(Agent)` to use `AgentBridge.deliver/2` + cc plugin's `BridgeAdapter` impl | the chat.ex:531 site; new `EzagentPluginCc.BridgeAdapter` module implementing `@behaviour AgentBridge.Adapter`; existing chat-receive e2e still works (cc-agent inbound). |
| **PR-E** | Remove `{:ezagent_plugin_cc, ...}` dep from `domain_chat/mix.exs`; strengthen `layer_purity_test` | mix.exs delete the line; layer_purity_test add the grep check; remove `# layer-violation-exempt` for plugin_cc; `Orchestrator.McpSocket` aliases `Ezagent.AgentBridge.TokenStore` not `EzagentPluginCc.TokenStore`. |
| **PR-F** | Refactor `Domain.Agent.lifecycle_status/1` from flavor-string to PTY-alive detection | `domain/agent.ex` collapse the 4 `defp delegate_alive_status/2` clauses into one PTY-detection clause; tests for cc/echo/curl/future-flavor coverage. |
| **PR-G** | `ezagent_plugin_codex/` plugin app | new app: Template Class, BridgeAdapter, agent_flavors declaration, Python codex bridge script. Acceptance: spawn `entity://agent/system/codex_test1`; open `/terminal/<uri>`; live codex TUI. |

### 4.1 Dependency graph (codex r2 MED-6 + MED-7 correction)

```
        PR-A (SPEC + skeletons)
            │
            ├─────────┬───────────┬──────────┐
            ▼         ▼           ▼          ▼
          PR-B      PR-F         (PR-G       (any time after A)
       (Registry  (PTY-detect    starts
        TokenStore)  lifecycle)  after
            │         │           PR-E)
            ├─────────┴─...
            ▼         
          PR-C, PR-D ────► PR-E (mix.exs unrigging — needs C+D done)
       (parallel after B)        │
                                 ▼
                               PR-G (codex feature)
```

- **PR-A** unblocks all others. Just the SPEC + new app shells + Adapter behaviour. No behavior change.
- **PR-B** SoT for Registry + TokenStore promotion. PR-C and PR-D depend on B (Socket needs Registry; chat.ex needs Registry).
- **PR-C and PR-D parallel after B**: Socket/Channel promotion (C) and Chat.receive rewrite (D) don't conflict — one touches plugin_cc lib + new app, other touches domain_chat lib.
- **PR-E** depends on both C + D done — mix.exs unrigging only safe when all chat.ex references to EzagentPluginCc are gone.
- **PR-F** independent of B→E chain. Can land any time after PR-A. Just the lifecycle_status refactor in domain/agent.ex.
- **PR-G** depends on PR-E (otherwise codex would also need the layer-violation-exempt marker).

This gives more parallelism than a strict A→G chain. Implementer / Codex can ship PR-A first, then C+D in parallel branches after B lands.

## 5. Acceptance criteria

**Cross-PR (must hold after each)**:
- C-1: umbrella compiles green
- C-2: `mix test --include integration` for touched apps has zero NEW failures vs baseline (the 17 pre-existing domain_chat sandbox flakes are baseline)
- C-3: `mix test apps/ezagent_core/test/invariants/layer_purity_test.exs` passes — at PR-E and later WITHOUT relying on `ezagent_plugin_cc`'s `layer-violation-exempt` marker; the new grep check finds zero `EzagentPluginCc.*` in domain_* lib/
- C-4: every PR carries `Co-Authored-By: Claude Opus 4.7 (1M context)` line
- C-5: every PR gets `/codex:adversarial-review` before merge

**Per-PR (THE merge gates)**:

PR-B: `Ezagent.AgentBridge.{TokenStore, Registry}` exist with full test coverage; `EzagentPluginCc.{TokenStore, BridgeRegistry}` are `@deprecated` thin shims delegating to new modules. YAML path unchanged. Existing cc agents continue working without restart.

PR-C: dual-mount Phoenix routes (`/agent_bridge` + `/cc_socket`); dual-topic Channel routes (`agent_bridge:cc:*` + `cc:bridge:*`); legacy Python sidecars connect successfully to the new Socket module via the legacy path.

PR-D: `chat.ex` Entity.Agent branch has zero `EzagentPluginCc.*` reference (grep verified); existing cc e2e (Feishu inbound → cc agent receives → replies via outbound mirror) still passes.

PR-E: `domain_chat/mix.exs` has zero `{:ezagent_plugin_cc, ...}`; `domain_chat/lib/**/*.ex` has zero `EzagentPluginCc.*` (grep -rn returns zero); the new layer_purity_test passes.

PR-F: A test creating a `codex_*` (or any non-cc/echo/curl) agent and asserting `Domain.Agent.lifecycle_status/1` returns `:alive` with PTY detail — without flavor-string special-casing. All existing tests pass.

PR-G: `mix ezagent workspace create_agent --flavor codex --name test1 ...` works; `/terminal/entity://agent/system/codex_test1` shows live codex TUI in xterm.js; codex agent receives a Feishu message + replies back (full e2e per `feedback_esr_e2e_standards`).

## 6. Files affected (estimated)

**New app** (`ezagent_domain_agent_bridge/`):
- `mix.exs`, `lib/ezagent_domain_agent_bridge.ex` (facade), `lib/ezagent_domain_agent_bridge/application.ex`
- `lib/ezagent/agent_bridge/{registry,token_store,socket,channel,adapter,adapter_registry,payload}.ex`
- `test/ezagent_domain_agent_bridge/...` (mirror structure)

**Moved/promoted** (cc plugin → new app):
- `EzagentPluginCc.BridgeRegistry` → `Ezagent.AgentBridge.Registry`
- `EzagentPluginCc.TokenStore` → `Ezagent.AgentBridge.TokenStore`
- `EzagentPluginCc.Socket` → `Ezagent.AgentBridge.Socket`
- `EzagentPluginCc.Channel` → `Ezagent.AgentBridge.Channel`

**Modified**:
- `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` — Entity.Agent receiver branch rewritten
- `apps/ezagent_domain_chat/lib/ezagent/domain/agent.ex` — flavor-string switch → PTY-alive detection
- `apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_socket.ex` — alias updated
- `apps/ezagent_domain_chat/mix.exs` — `{:ezagent_plugin_cc, ...}` line + `# layer-violation-exempt` REMOVED
- `apps/ezagent_plugin_cc/mix.exs` — depends on `ezagent_domain_agent_bridge`
- `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/{bridge_registry,token_store,socket,channel}.ex` — replaced with thin `@deprecated` shims for one deprecation window
- `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/bridge_adapter.ex` (NEW) — `@behaviour Ezagent.AgentBridge.Adapter` impl
- `apps/ezagent_core/test/invariants/layer_purity_test.exs` — new grep check + exemption-removal

**Tests**:
- New tests in `ezagent_domain_agent_bridge/test/` for the new modules
- Updates in `ezagent_plugin_cc/test/` for the shim layer + adapter behaviour conformance
- Integration test: existing cc e2e (Feishu → cc agent → Feishu) MUST continue working unchanged

## 7. Out of scope (deferred to follow-up SPECs)

- **Orchestrator MCP transport** (`Ezagent.Orchestrator.McpSocket` + `McpChannel`): a SEPARATE Phoenix Channel for the 7 orchestration tools. NOT moved by this SPEC. Only the TokenStore reference is updated (R5 from the review doc).
- **Codex Python bridge script**: PR-G work, but the codex-specific `ezagent_codex_bridge.py` is NOT designed in this SPEC — that's PR-G's responsibility.
- **Multi-tenant credential isolation**: today, cc agents share the operator's `~/.claude/.credentials.json` (per task #47 mitigation). Multi-user credential isolation is a separate concern; this SPEC doesn't address it.
- **`agent_bridge` cap subjects**: this SPEC doesn't introduce new caps; the existing `Behavior.Chat :send/:receive` caps still gate the dispatch flow. If a future SPEC needs per-bridge caps, that's separate.

## 8. Failure modes considered

| Failure | Behavior |
|---|---|
| Cc Python sidecar still connecting to `/cc_socket` after PR-C | Backward-compat alias accepts it; sidecar continues working. Deprecation warning logged. |
| TokenStore YAML file format mismatch between cc-shim and new TokenStore | The shim reads via new TokenStore; same file path; format unchanged. No mismatch. |
| Adapter for codex flavor not registered when codex agent spawns | `AgentBridge.deliver/2` returns `{:error, :no_adapter}`; logged as warning (Invariant #9 — no silent drop); admin LV surfaces a notification. |
| Layer purity test new grep check finds in-code references in transit | PR-E lands AFTER PR-D removes those references; if PR-E sequence is broken (PR-E merged before PR-D), the test fails immediately + reverts. CI gate. |
| Phoenix dual-mount socket misroutes | Phoenix Channel topic-prefix matching is deterministic; ambiguous topic would fail at Channel.join/3 with `{:error, :unknown_topic}`. Test coverage for both legacy + new topic shapes. |
| Codex agent flavor uses different on-disk YAML for tokens (multi-tenancy concern) | TokenStore module signature accepts the per-agent URI; the YAML key is the URI string. Different agent flavors with non-overlapping URI prefixes have non-overlapping tokens automatically. |

## 9. Codex brainstorm questions

This is the SPEC's brainstorm draft. Codex should probe:

1. **Payload schema completeness**: does the `%Ezagent.AgentBridge.Payload{}` shape cover ALL message types currently flowing across `cc:bridge:*` (chat_send, mention, reply, slice_change notification, audit push, orchestrator MCP tool round-trip)? Or am I missing categories?
2. **Adapter `handle_reply/2` callback**: today `EzagentPluginCc.Channel.handle_in("reply", ...)` is called when the cc agent SENDS BACK via the WS. The new Adapter behaviour models this as `handle_reply/2`. Is the signature right? Should it be one callback per message type the WS can send back, or a single dispatch on message type?
3. **`Ezagent.Plugin agent_flavors/0` adapter field addition**: extending the existing declarative `agent_flavors/0` (per `2026-05-22-plugin-authoring-contract.md`) with an `adapter` field — is this a backward-compat break for any plugin already declaring `agent_flavors/0`? Today only cc declares it; future codex will. So no live break. Confirm.
4. **Backward-compat alias deprecation window**: 2 release cycles seems reasonable; should it be configurable per operator (env var to disable legacy mount earlier)? Or hard-coded?
5. **`Ezagent.AgentBridge.deliver/2` failure mode**: if no adapter is registered for the URI's flavor prefix, what should the facade return? `{:error, :no_adapter}` and the caller logs + telemetry, OR raise (let-it-crash)?
6. **Cap subject for the new app**: `Behavior.AgentBridge :deliver` — should it exist as a Behavior action with required cap, or is the deliver call internal-only (called only from Chat.receive)?
7. **Domain.Pty.alive?/1 dependency**: PR-F lifecycle_status detection uses `Domain.Pty.alive?/1`. This adds a dep `ezagent_domain_chat → ezagent_domain_pty` (if not already). Is that dep already in place? If not, PR-F adds it.
8. **Orchestrator MCP TokenStore split**: today `Orchestrator.McpSocket` aliases `EzagentPluginCc.TokenStore` for ITS auth (separate from cc bridge but using the same TokenStore). After PR-B promotes TokenStore, the McpSocket alias updates. Is there any cc-specific token-mint semantics the TokenStore promotion would lose?
9. **`layer_purity_test` grep check robustness**: `EzagentPluginCc\.` would also match comments + docstrings + test fixtures. Should the grep be restricted to non-comment lines? Or accept the false positives and add inline `# noqa` markers?
10. **PR sequencing flexibility**: codex's brainstorm — can PR-F (lifecycle_status PTY-detection) run in parallel with PR-B/C/D, or must it strictly follow PR-E? My current ordering has PR-F after E, but PR-F is independent — could shift earlier.

## 10. Open questions for Allen

1. **Worktree of bridge cred files**: today `~/.ezagent/<profile>/credentials/cc-channels.yaml`. After PR-B, should it rename to `agent-bridge-tokens.yaml`? Or keep the historical name with a docstring noting it's now flavor-agnostic? Recommend keep the name (history + operator muscle memory).
2. **Deprecation timeline for `/cc_socket` legacy mount**: 2 release cycles? 6 months? On-deploy?
3. **codex_<name>` URI prefix**: codex agents will have URIs `entity://agent/<ws>/codex_<name>`. Codex's `agent_flavors/0` `prefix: "codex_"`. Confirm OK.
4. **Multi-tenancy and credential file**: today the YAML is per-profile per-host. For multi-user codex (different users running codex agents), should the YAML key be `<flavor>::<agent_uri>` to avoid collision across flavors with overlapping naming? Or assume URI is globally unique (it is, per Phase 9 3-segment authority).

## 12. Adapter author checklist (codex r2 MED-8)

A future plugin author adding a bridge-backed agent flavor (e.g. codex, gemini-cli, future) follows:

1. Add to plugin's `agent_flavors/0`:
   ```elixir
   %{
     flavor: "codex",
     kind: Ezagent.Entity.Agent,
     template_class: MyPlugin.Template.CodexAgent,
     bridge_adapter: MyPlugin.BridgeAdapter
   }
   ```

2. Implement `MyPlugin.BridgeAdapter` adopting `@behaviour Ezagent.AgentBridge.Adapter`:
   ```elixir
   defmodule MyPlugin.BridgeAdapter do
     @behaviour Ezagent.AgentBridge.Adapter

     @impl true
     def flavor, do: "codex"

     @impl true
     def agent_uri_prefix, do: "codex_"

     @impl true
     def deliver(%Ezagent.AgentBridge.Payload{} = payload, channel_pid) do
       # Convert generic payload to codex-specific WS push.
       codex_specific = %{
         "turn_start" => %{
           "text" => payload.text,
           "session" => URI.to_string(payload.session_uri),
           "sender" => URI.to_string(payload.sender_uri)
         }
       }
       send(channel_pid, {:to_codex, codex_specific})
       :ok
     end

     @impl true
     def handle_client_event("turn_response", %{"text" => text, "session_uris" => sessions}, socket) do
       # codex sent back a response — dispatch into ezagent.
       Process.send(self(), {:dispatch_response, sessions, text}, [])
       {:reply, :ok, socket}
     end

     def handle_client_event(_unknown_event, _params, socket) do
       {:reply, {:error, %{reason: "unknown_event"}}, socket}
     end

     @impl true
     def socket_path, do: "/agent_bridge"

     @impl true
     def channel_topic_prefix, do: "agent_bridge:codex:"
   end
   ```

3. Plugin's Python (or Node, or any) sidecar connects to `socket_path()` + joins `<channel_topic_prefix><agent_uri>`.

4. Run `mix ezagent_plugin_check` — the compile-time check verifies the adapter conforms to the behaviour, the `agent_flavors/0` declaration includes `flavor` + `kind` + `template_class` + `bridge_adapter`, and the URI prefix matches the `agent_uri_prefix/0` return.

5. Write a unit test conformance suite extending `Ezagent.AgentBridge.Adapter.ConformanceTest` (TBD in PR-A) — pin the adapter's `deliver/2` behavior on a synthetic payload.

That's the complete plugin-author surface for a new bridge-backed agent flavor. No imperative registry calls; no core knowledge; declarative + behaviour-conforming.

## 11. Rollback plan

7-PR sequence; each is independently revertable. The most consequential rollback is PR-E (mix.exs unrigging) — if PR-E goes wrong and breaks cc agent operation, revert PR-E specifically: `domain_chat/mix.exs` regains the `{:ezagent_plugin_cc, ...}` dep + `layer-violation-exempt` marker. cc plugin's BridgeRegistry/TokenStore/Socket/Channel shims (post-PR-B/C) still work because they delegate to `Ezagent.AgentBridge.*` — but `Chat.receive(Agent)` reverts to calling them via the cc-prefixed module names. No data loss.

---

## Appendix A — Decision rationale per review doc risk

| Review-doc risk | SPEC resolution |
|---|---|
| R1 (payload schema must be SPEC'd) | §3.2 + §9.1 enumeration |
| R2 (in-flight cc bridge cutover) | §3.7 dual-mount alias + §9.4 deprecation timeline |
| R3 (TokenStore YAML migration) | §6 + §10.1 — keep file path, promote module |
| R4 (adapter registration contract) | §3.3 — single `agent_flavors/0` declaration with new `adapter` field |
| R5 (orchestrator MCP vs agent bridge) | §7 — orchestrator MCP stays put; only TokenStore alias updated |
| R6 (Python bridge generality) | §3.5 — cc Python sidecar unchanged; codex has its own |
| R7 (Invariant #3 string-meta) | §3.2 — generic Payload's `meta` is flat string Record |
| R8 (layer_purity_test strengthening) | §3.8 — grep check + exemption removal |
| R9 (codex plugin scaffolding) | §4 PR-G uses existing `Ezagent.Plugin` declarative contract |
| R10 (where AgentBridge lives) | §3.1 — new app `ezagent_domain_agent_bridge/` |
