# cc-headless SDK Sidecar Implementation Plan

Date: 2026-06-23
Branch: `agent-flavor-headless-cc-headless-impl`

## Goal

Implement the real `cc-headless` runtime using a Claude Code Python SDK sidecar, not a PTY and not `claude -p`.

This replaces the current stub in `CcHeadlessAgent` with a supervised no-TTY runtime that can receive Ezagent session messages and return Claude-backed replies.

## Production Evidence

`/mnt/d/Work/h2os.cloud/AutoService-dev-a` already runs a production SDK pool:

- dependency: `claude-agent-sdk>=0.2.94,<0.3`
- implementation: `autoservice/cc_pool.py`
- key runtime facts:
  - one SDK client must serialize `query() + receive_response()` with a lock;
  - sticky `session_id` is used for multi-turn continuity;
  - `ClaudeAgentOptions` carries cwd, env, permission/tool policy, model, MCP, hooks;
  - E2E evidence exists for real SDK subprocess operation and concurrent pool use.

Therefore this Ezagent implementation should extract the narrow runtime pattern, not rebuild the whole AutoService pool.

## Architecture

### Components

1. `apps/ezagent_plugin_cc/priv/python/ezagent_cc_sdk_worker.py`
   - Python worker run by `uv run --script` or `python3`.
   - Owns one `ClaudeSDKClient`.
   - Reads JSON lines on stdin.
   - Writes JSON result lines on stdout.
   - Serializes SDK turns with an `asyncio.Lock`.
   - Uses `CLAUDE_CONFIG_DIR` for Ezagent per-agent credential home isolation.

2. `EzagentPluginCc.SdkSidecar`
   - GenServer per `cc-headless` agent.
   - Starts the Python worker as an Elixir Port.
   - Sends one JSON request per turn and waits for the matching JSON response.
   - Tracks pending callers by request id.
   - Lives under plugin-owned `Registry` + `DynamicSupervisor`.

3. `EzagentPluginCc.CcHeadlessBridgeAdapter`
   - Changes transport from `:subprocess_ws` to `:in_process_sync`.
   - Extracts `agent_uri` from `payload.meta["agent_uri"]`.
   - Calls `SdkSidecar.query/3`.
   - Returns `{:ok, %{content, usage}} | {:error, reason}` to the Agent receive sync seam.

4. `Ezagent.Behavior.CcHeadlessAgent`
   - Plugin-declared behavior bound to `Ezagent.Entity.Agent`.
   - Owns the `:cc_headless_sync_result` action for `cc-headless`.
   - `Agent.Receive` routes cc-headless sync delivery to this action because
     `CapabilityRegistry` does not allow multiple behaviors to claim the same
     `{Ezagent.Entity.Agent, :sync_result}` tuple.
   - Persists conversation/error/token metadata.
   - Dispatches the assistant reply back to the source session.

5. `CcHeadlessAgent` template
   - Keeps the existing credential cascade.
   - Starts `SdkSidecar` after credential revalidation.
   - Stores `config_dir`, `cwd`, `claude_session_id`, and runner options in respawn data.
   - `ensure_subprocess_alive/2` becomes `ensure_sidecar_alive/2`.

## Scope Delta From 3B

The earlier 3B and 3B-variant estimates assumed `cc-headless` could remain a
plugin-local transport change: keep the existing Claude Code bridge semantics,
remove the PTY, and let the existing async bridge/session reply path carry the
assistant response. Under that assumption, core/domain changes were expected to
be unnecessary.

Validation changed that premise. Claude Code 2.1 does not keep
`server:esr-bridge` alive without a TTY, and `claude -p` does not provide the
same long-running bridge process. The selected SDK sidecar route is therefore
not an async WebSocket bridge variant; it is an in-process synchronous agent
flavor similar to curl, with the Python SDK returning a result directly to
`Agent.Receive`.

That changes the required integration boundary:

- `Agent.Delivery` must preserve the resolved flavor in sync delivery results,
  because both curl and cc-headless use `:in_process_sync` but require different
  post-result actions.
- `Agent.Receive` must route `cc-headless` results to
  `:cc_headless_sync_result` instead of curl's `:sync_result`.
- `Ezagent.Entity.Agent` must expose a `cc_headless_behaviors/0` per-instance
  behavior set so cc-headless agents capture the correct state behavior.
- `Ezagent.Kind.BehaviorSet` must know the `:cc_headless_agent` state slice
  owner so the behavior can persist conversation/error/token metadata.

The SDK worker, process supervision, template spawn/respawn logic, and adapter
remain in `ezagent_plugin_cc`. The core/domain changes are the minimal
Behavior/Kind dispatch and state-registration surface needed by the new sync
flavor; Python SDK details do not cross into core/domain.

## Scope

In scope:

- per-agent SDK sidecar;
- sticky per-agent Claude SDK session id;
- serialized turns on one SDK client;
- fake-worker tests for sidecar protocol;
- adapter transport class and deliver tests;
- spawn/respawn path no longer reports stub success.

Out of scope for this first pass:

- shared multi-agent SDK pool;
- tenant-tier scheduling;
- AutoService soul/KB/tool policy logic;
- real Claude SDK E2E in normal test suite;
- WebSocket bridge mode for headless.

## Runtime Policy

Default SDK options are conservative:

- `permission_mode`: `default`
- no broad tool whitelist by default
- cwd comes from template `"cwd"`
- config home comes from Ezagent credential home and is exported as `CLAUDE_CONFIG_DIR`
- model/system prompt/tool policy can be threaded later from template data

## Acceptance Gate

This implementation is functionally complete when:

1. `cc-headless` spawn starts a supervised SDK sidecar, not a stub.
2. `CcHeadlessBridgeAdapter.transport_class/0 == :in_process_sync`.
3. A fake SDK worker can complete a sidecar query in tests.
4. Adapter deliver returns the worker reply through the existing sync-result seam.
5. `CcHeadlessAgent.ensure_subprocess_alive/2` restarts a missing sidecar from respawn data.
6. Focused tests pass, then `mix precommit` is run before final handoff.
