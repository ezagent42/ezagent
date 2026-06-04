# 4-agent comprehensive e2e — operator runbook

> Per Allen Feishu 2026-05-23 spec — `user → @cc → @curl → @np → user`,
> validating the multi-agent orchestration pipeline through real
> claude (cc) + real DeepSeek (curl) + real numpy/sympy (np).

The CI / dev test `apps/ezagent_plugin_np/test/integration/comprehensive_4agent_e2e_test.exs`
runs the same flow with a `FakeCcAgent` stand-in + a Bandit-hosted
Plug mock for DeepSeek; it proves the orchestration in ~3 s without
external dependencies.

This runbook describes the **manual smoke through the full real stack**
— operator-driven, no shortcuts. Run it when you've changed something
in the multi-agent dispatch path and want a real-world sign-off.

## Preconditions

| Tool / artifact                  | Used by              |
|----------------------------------|----------------------|
| `uv` on `$PATH`                  | np-agent + cc bridge |
| `python3` on `$PATH`             | cc-agent             |
| Anthropic API key (claude)       | cc-agent             |
| `claude` CLI                     | cc-agent             |
| DeepSeek API key                 | curl-agent           |

```sh
which uv python3 claude   # all three must exist
```

Set the keys (one-time per shell):

```sh
export ANTHROPIC_API_KEY=sk-ant-...
export DEEPSEEK_API_KEY=sk-deepseek-...
```

The admin user is bootstrapped at boot (`entity://user/system/admin`).
You'll seed the DeepSeek key on it via the admin UI in step 4 below.

## 1. Start the umbrella

```sh
cd /Users/h2oslabs/Workspace/esr-ng
mix ezagent.bootstrap            # idempotent — DB migrate + plugin install
iex -S mix phx.server
```

Open `http://127.0.0.1:4000/login`, sign in as admin.

## 2. Create the cc-agent (real claude binary)

In iex, or via `/admin/templates`:

```elixir
{:ok, _} = Ezagent.Workspace.add_template(
  URI.new!("workspace://default"),
  "cc-orchestrator",
  %{
    "class" => "cc.agent",
    "agent_uri" => "entity://agent/default/cc_orchestrator",
    "cwd" => "/tmp/cc-orchestrator-cwd",   # mkdir this first
    "claude_config_dir" => "/tmp/cc-orchestrator-claude-dir"
  }
)
```

(See `docs/runbook/cc-agent-config.md` for the full cc-agent template
shape + sandbox knobs.)

## 3. Create the curl-agent (real DeepSeek endpoint)

```elixir
{:ok, _} = Ezagent.Workspace.add_template(
  URI.new!("workspace://default"),
  "curl-translator",
  %{
    "class" => "curl.agent",
    "agent_uri" => "entity://agent/default/curl_translator",
    "provider" => "deepseek",
    "api_url" => "https://api.deepseek.com/chat/completions",
    "model" => "deepseek-chat",
    "system_prompt" =>
      "You translate LaTeX expressions into numpy-compatible Python " <>
      "expressions. Reply with ONLY the numpy expression — no prose, " <>
      "no markdown, no code fences. Example: input '\\int_0^1 x dx' " <>
      "→ output 'sympy.integrate(x, (x, 0, 1))'.",
    "max_history" => "5",
    "owner_uri" => "entity://user/system/admin"
  }
)
```

## 4. Seed the DeepSeek API key on the admin user

UI: `/admin/users/<admin_uri>/api-keys` → add `provider="deepseek"`,
`key=$DEEPSEEK_API_KEY`. The curl-agent's `:receive` path will
dispatch `identity.get_api_key` against the admin User to fetch this.

## 5. Create the np-agent (real Python subprocess)

```elixir
{:ok, _} = Ezagent.Workspace.add_template(
  URI.new!("workspace://default"),
  "np-calculator",
  %{
    "class" => "np.agent",
    "agent_uri" => "entity://agent/default/np_calculator",
    "cwd" => "/tmp",
    "timeout_ms" => "30000"
  }
)
```

The first instantiate may take ~30 s as uv downloads numpy + sympy.
Subsequent boots are cached.

Verify the Python subprocess is alive:

```elixir
agent_uri = URI.new!("entity://agent/default/np_calculator")
true = Ezagent.Domain.Python.alive?(agent_uri)
{:ok, %{"ok" => true}} = Ezagent.Domain.Python.call(agent_uri, "ping", %{}, 5_000)
```

## 6. Create the orchestration session + add routing rules

```elixir
session_uri = URI.new!("session://default/default/4agent-orchestration")
{:ok, _} = Ezagent.SpawnRegistry.spawn(session_uri)
:ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://default"))

# Join all four members
admin = Ezagent.Entity.User.admin_uri()
cc    = URI.new!("entity://agent/default/cc_orchestrator")
curl  = URI.new!("entity://agent/default/curl_translator")
np    = URI.new!("entity://agent/default/np_calculator")

for m <- [admin, cc, curl, np] do
  Ezagent.Invocation.dispatch(%Ezagent.Invocation{
    target: URI.new!("#{URI.to_string(session_uri)}?action=chat.join"),
    mode: :cast,
    args: %{member: m},
    ctx: %{caller: m, caps: Ezagent.Entity.User.admin_caps(), reply: :ignore}
  })
end

# Per-sender chain rules (admin→cc, cc→curl, curl→np, np→admin)
alias Ezagent.Routing.{Matcher, RuleStore}
table = EzagentDomainInstanceMessage.Routing.MentionRouting

for {from, to} <- [
  {admin, cc}, {cc, curl}, {curl, np}, {np, admin}
] do
  {:ok, _} = RuleStore.add(
    table,
    Matcher.from(from),
    [URI.to_string(to)],
    URI.to_string(admin),
    workspace_uri: "workspace://default"
  )
end
:ok = RuleStore.load_into_registry(table)
```

## 7. Send a real compute request

In the `/sessions/.../4agent-orchestration` LV, type:

```
Please integrate x dx from 0 to 1 and tell me the value
```

…and submit. Watch the chat stream:

  1. cc-agent receives, asks Claude → reply containing the LaTeX
     `\int_0^1 x \, dx`.
  2. curl-agent receives, calls DeepSeek → reply containing the
     numpy expression `sympy.integrate(x, (x, 0, 1))` (or
     `(0+1)/2` or similar — DeepSeek's choice).
  3. np-agent receives, evaluates → reply `= 1/2` (or `= 0.5` if
     the expression evaluates numerically).

## 8. Verify + tear down

```elixir
# Confirm np's reply landed
session_topic = Ezagent.Behavior.Chat.session_events_topic(session_uri)
:ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)
# (the events stream already has the reply if you watched it live)

# Tear-down (idempotent)
:ok = Ezagent.Domain.Python.stop(np)
```

## Common failure modes

| Symptom                                | Likely cause                                                |
|----------------------------------------|-------------------------------------------------------------|
| `:not_alive` from np `Python.call`     | uv install of numpy/sympy failed; check `~/.openclaw/logs/` |
| cc-agent never replies                 | claude binary missing OR Anthropic key invalid              |
| curl-agent surfaces `:no_api_key`      | DeepSeek key not seeded on admin user (step 4)              |
| np replies `compute error: parse rejected` | DeepSeek emitted prose with the expression — tighten the system_prompt |
| All four members joined but no replies | Per-sender routing rules missing (step 6); without them only `$mentions` routes — but cc / curl / np replies have no `mentions` field |

## Why this complements the unit + integration tests

  * Unit tests (`test/ezagent/`): per-Kind contract — Kind /
    Behavior / Template Class validation, slice shape, etc.
  * Plugin contract integration test
    (`test/integration/plugin_contract_test.exs`): plugin authoring
    contract (boot, declarations, registry publication).
  * Comprehensive 4-agent e2e
    (`test/integration/comprehensive_4agent_e2e_test.exs`): the
    deterministic orchestration round-trip via FakeCcAgent + Bandit
    mock DeepSeek + real Python.
  * THIS runbook: the full real stack — real Claude, real DeepSeek,
    real numpy/sympy — exercised once by hand when something
    significant changes upstream in any of the three agent
    integrations.
