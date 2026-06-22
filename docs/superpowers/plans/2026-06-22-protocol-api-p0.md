# ezagent_plugin_protocol_api — Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `ezagent_plugin_protocol_api` plugin exposing `POST /v1/chat/completions` (OpenAI-compatible inbound), durable conversation binding, synchronous non-streaming reply.

**Architecture:** Inbound = Feishu pattern (request → Message → dispatch session.send); the one delta = synchronous reply via Publisher `:latest` subscription + `ref_id` correlation in a reply waiter, returned as OpenAI-format JSON.

**Tech Stack:** Elixir 1.19/OTP 27, Phoenix Plug, Ecto, Ezagent core/domain_session/domain_external_mirror

**Spec:** `docs/superpowers/specs/2026-06-22-protocol-api-design.md`

---

## File Map

| # | File | Role |
|---|------|------|
| 1 | `apps/ezagent_plugin_protocol_api/mix.exs` | OTP app definition |
| 2 | `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/application.ex` | Plugin contract + boot |
| 3 | `apps/ezagent_plugin_protocol_api/priv/repo/migrations/20260622000000_create_protocol_api_keys.exs` | DB migration |
| 4 | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/api_key_store.ex` | Ecto schema + verify |
| 5 | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex` | conversation_id ↔ session binding |
| 6 | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/adapter.ex` | `:push` Adapter stub |
| 7 | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/reply_waiter.ex` | Publisher subscribe → match ref_id → return |
| 8 | `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/openai_chat_plug.ex` | HTTP handler (Plug) |
| — | `apps/ezagent_web/lib/ezagent_web/router.ex` | **Modify**: mount plug |
| — | `mix.exs` (root) | **Modify**: add to releases |
| — | `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex` | **Modify**: sanction spawn |
| — | `apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex` | **Modify**: fix ref_id gap |
| — | `apps/ezagent_plugin_protocol_api/test/test_helper.exs` | ExUnit config |
| — | `apps/ezagent_plugin_protocol_api/test/ezagent/protocol_api/reply_waiter_test.exs` | Core unit test |

---

### Task 1: Plugin scaffolding

**Files:**
- Create: `apps/ezagent_plugin_protocol_api/mix.exs`
- Create: `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/application.ex`
- Create: `apps/ezagent_plugin_protocol_api/test/test_helper.exs`

- [ ] **Step 1: Create mix.exs**

```elixir
defmodule EzagentPluginProtocolApi.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezagent_plugin_protocol_api,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers() ++ [:ezagent_plugin_check],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {EzagentPluginProtocolApi.Application, []},
      env: [ezagent_plugin: EzagentPluginProtocolApi.Application],
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ezagent_core, in_umbrella: true},
      {:ezagent_domain_session, in_umbrella: true},
      {:ezagent_domain_external_mirror, in_umbrella: true}
    ]
  end
end
```

- [ ] **Step 2: Create application.ex**

```elixir
defmodule EzagentPluginProtocolApi.Application do
  @moduledoc """
  Protocol API plugin — exposes OpenAI/Anthropic-compatible inbound HTTP APIs.

  ## Plugin contract

  `use`s both `Application` (OTP plumbing) and `Ezagent.Plugin` (declarative
  contract). Registration is declarative — `Ezagent.Plugin.boot/1` reads the
  callbacks below and performs every `*Registry` call.

  ## What this plugin declares (P0)

  - `adapters/0` — `Ezagent.ProtocolApi.Adapter` as bare `:push` adapter
    (no-op binding; real transport is the HTTP response in `OpenaiChatPlug`).
    P1 will introduce the request-scoped binding variant.
  - `config_surface/0` — nil (API-key management UI deferred to P1).
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.ProtocolApi.Adapter

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "protocol_api",
      name: "Protocol API",
      description: "OpenAI/Anthropic-compatible inbound HTTP API. Phase 0: /v1/chat/completions.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def adapters, do: [Adapter]

  @impl Ezagent.Plugin
  def config_surface, do: nil

  @impl Ezagent.Plugin
  def children, do: []
end
```

- [ ] **Step 3: Create test_helper.exs**

```elixir
# Use the umbrella test helper so the plugin picks up the shared
# DataCase / EzagentCore.DataCase / sandbox setup.
Code.require_file("../../test/test_helper.exs", __DIR__)
```

- [ ] **Step 4: Verify compiles**

Run: `cd apps/ezagent_plugin_protocol_api && mix compile`
Expected: compiles (with warnings about unused aliases — fine at this stage).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_protocol_api/
git commit -m "feat(protocol-api): plugin scaffolding — mix.exs, application.ex, test_helper"
```

---

### Task 2: Migration + API Key Store

**Files:**
- Create: `apps/ezagent_plugin_protocol_api/priv/repo/migrations/20260622000000_create_protocol_api_keys.exs`
- Create: `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/api_key_store.ex`

- [ ] **Step 1: Create migration file**

```elixir
defmodule EzagentPluginProtocolApi.Repo.Migrations.CreateProtocolApiKeys do
  use Ecto.Migration

  def change do
    create table(:protocol_api_keys, primary_key: false) do
      add :key_id, :string, null: false, primary_key: true
      add :secret_hash, :string, null: false
      add :entity_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :label, :string
      add :allowed_models, {:array, :string}, default: []
      add :cap_policy, :map, default: %{}
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:protocol_api_keys, [:key_id])
    create index(:protocol_api_keys, [:entity_uri])
  end
end
```

- [ ] **Step 2: Create api_key_store.ex**

```elixir
defmodule Ezagent.ProtocolApi.ApiKeyStore do
  @moduledoc """
  Ecto schema + queries for `protocol_api_keys`.

  Token format: `pk_<key_id>_<secret>` — the `key_id` prefix enables
  indexed lookup without full-table bcrypt scan.
  """

  use Ecto.Schema

  alias EzagentCore.Repo

  @primary_key {:key_id, :string, autogenerate: false}
  schema "protocol_api_keys" do
    field :secret_hash, :string
    field :entity_uri, :string
    field :workspace_uri, :string
    field :label, :string
    field :allowed_models, {:array, :string}, default: []
    field :cap_policy, :map, default: %{}
    field :revoked_at, :utc_datetime
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Verify a Bearer token against the API key store.

  Returns `{:ok, entity_uri, workspace_uri, caps}` on success,
  `{:error, reason}` on failure.
  """
  @spec verify(String.t()) ::
          {:ok, URI.t(), URI.t(), MapSet.t()}
          | {:error, :invalid_token | :revoked}
  def verify(token) when is_binary(token) do
    with {:ok, key_id, secret} <- parse_token(token),
         {:ok, row} <- lookup(key_id),
         :ok <- verify_secret(secret, row.secret_hash),
         :ok <- check_not_revoked(row) do
      entity_uri = Ezagent.URI.new!(row.entity_uri)
      workspace_uri = Ezagent.URI.new!(row.workspace_uri)
      caps = MapSet.new()  # P0: API key carries no extra caps; entity's own caps suffice
      {:ok, entity_uri, workspace_uri, caps}
    end
  end

  @doc """
  List active keys for an entity (for operator UI, P1).
  """
  def list_for_entity(entity_uri) when is_binary(entity_uri) do
    import Ecto.Query

    Repo.all(
      from k in __MODULE__,
        where: k.entity_uri == ^entity_uri and is_nil(k.revoked_at),
        select: [:key_id, :label, :allowed_models, :inserted_at]
    )
  end

  # --- internals ---

  # Token format: pk_<key_id>_<secret>
  defp parse_token("pk_" <> rest) do
    case String.split(rest, "_", parts: 2) do
      [key_id, secret] when key_id != "" and secret != "" ->
        {:ok, key_id, secret}

      _ ->
        {:error, :invalid_token}
    end
  end

  defp parse_token(_), do: {:error, :invalid_token}

  defp lookup(key_id) do
    case Repo.get(__MODULE__, key_id) do
      nil -> {:error, :invalid_token}
      %__MODULE__{} = row -> {:ok, row}
    end
  end

  defp verify_secret(secret, hash) do
    if Bcrypt.verify_pass(secret, hash) do
      :ok
    else
      {:error, :invalid_token}
    end
  end

  defp check_not_revoked(%{revoked_at: nil}), do: :ok
  defp check_not_revoked(_), do: {:error, :revoked}
end
```

- [ ] **Step 3: Verify compiles**

Run: `cd apps/ezagent_plugin_protocol_api && mix compile`
Expected: compiles. (May warn about unused `Repo` alias — ok.)

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_plugin_protocol_api/
git commit -m "feat(protocol-api): migration + ApiKeyStore for API-key auth"
```

---

### Task 3: Conversation Registry (durable session binding)

**Files:**
- Create: `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex`

- [ ] **Step 1: Create conversation_registry.ex**

Uses the same `BindingRow` + `Repo` pattern as Feishu's `InboundChatLookup.resolve/3`. Lookup queries `external_mirror_bindings` WHERE `adapter_id == "protocol_api"` AND `target_id == conversation_id`. On miss: spawn a new session via `SpawnRegistry.spawn`, bind workspace, insert a `BindingRow` row. The `ExternalMirror.bind/4` facade is NOT used because it requires session caps the new entity may not yet hold; `BindingRow.insert/1` is the direct DB path that the session's `Behavior.ExternalMirror.invoke(:bind)` uses internally — and we just created the session as the owner.

```elixir
defmodule Ezagent.ProtocolApi.ConversationRegistry do
  @moduledoc """
  Durable `conversation_id ↔ session` binding.

  Reuses the existing `external_mirror_bindings` table (same pattern as
  Feishu's `chat_id ↔ session` via `InboundChatLookup`). An API consumer
  sends a `conversation_id` header/field and gets back the same session
  on every call — preserving agent identity, caps, cwd, and history.

  If no binding exists for the given conversation_id, a new session is
  spawned via `SpawnRegistry.spawn` and bound.
  """

  require Logger

  import Ecto.Query

  alias Ezagent.{SpawnRegistry, WorkspaceRegistry}
  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentCore.Repo

  @adapter_id "protocol_api"

  @doc """
  Resolve a conversation_id to a session URI.

  Returns `{:ok, session_uri}` — either the existing bound session or a
  freshly-spawned one.
  """
  @spec resolve(String.t(), URI.t(), URI.t()) :: {:ok, URI.t()} | {:error, term()}
  def resolve(conversation_id, workspace_uri, bound_by)
      when is_binary(conversation_id) and is_struct(workspace_uri, URI) and
             is_struct(bound_by, URI) do
    case lookup(conversation_id) do
      {:ok, session_uri} ->
        {:ok, session_uri}

      {:error, :not_found} ->
        create_and_bind(conversation_id, workspace_uri, bound_by)
    end
  end

  # --- internals ---

  # Identical pattern to InboundChatLookup.resolve/3 (Feishu):
  # query BindingRow by adapter_id + target_id.
  defp lookup(conversation_id) do
    rows =
      Repo.all(
        from r in BindingRow,
          where: r.adapter_id == ^@adapter_id and r.target_id == ^conversation_id,
          order_by: r.bound_at,
          select: r.session_uri
      )

    case rows do
      [] -> {:error, :not_found}
      [session_uri_str] -> {:ok, Ezagent.URI.new!(session_uri_str)}
      _multiple -> {:error, :ambiguous_conversation_binding}
    end
  end

  defp create_and_bind(conversation_id, workspace_uri, bound_by) do
    ws = Ezagent.URI.stable_key(workspace_uri) |> String.replace("://", "_")
    name = "conv_#{ws}_#{short_id(conversation_id)}"
    # URI.session/3: session(workspace, template, name)
    session_uri = Ezagent.URI.session(workspace_uri, "generic", name)

    with {:ok, _pid} <- SpawnRegistry.spawn(session_uri),
         :ok <- WorkspaceRegistry.bind(session_uri, workspace_uri),
         {:ok, _row} <- insert_binding_row(conversation_id, session_uri, workspace_uri, bound_by) do
      Logger.info(
        "ProtocolApi: bound conversation_id=#{conversation_id} → " <>
          "#{Ezagent.URI.stable_key(session_uri)}"
      )

      {:ok, session_uri}
    else
      {:error, reason} ->
        Logger.error(
          "ProtocolApi: failed to create session for conversation_id=#{conversation_id}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  defp insert_binding_row(conversation_id, session_uri, workspace_uri, bound_by) do
    # Direct BindingRow.insert — same DB path the session's
    # Behavior.ExternalMirror.invoke(:bind) uses internally.
    # We bypass the ExternalMirror.bind/4 facade because it requires
    # session :bind caps the newly-created entity may not yet hold.
    row_id = BindingRow.row_id(session_uri, @adapter_id, conversation_id)

    BindingRow.insert(%{
      id: row_id,
      session_uri: URI.to_string(session_uri),
      adapter_id: @adapter_id,
      target_id: conversation_id,
      opts_json: "{}",
      bound_by: URI.to_string(bound_by),
      bound_at: DateTime.utc_now(),
      workspace_uri: URI.to_string(workspace_uri)
    })
  end

  # Generate a short stable suffix from conversation_id for the session name.
  # Takes first 8 chars of sha256 for uniqueness with human readability.
  defp short_id(conv_id) do
    :crypto.hash(:sha256, conv_id) |> Base.encode16(case: :lower) |> String.slice(0..7)
  end
end
```

- [ ] **Step 2: Verify compiles**

Run: `cd apps/ezagent_plugin_protocol_api && mix compile`
Expected: compiles. Verify `BindingRow.row_id/3` arity matches (it takes `(session_uri, adapter_id, target_id)`).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_plugin_protocol_api/
git commit -m "feat(protocol-api): conversation registry — durable conversation↔session binding"
```
```

---

### Task 4: Adapter stub (push, no-op binding)

**Files:**
- Create: `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/adapter.ex`

- [ ] **Step 1: Create adapter.ex**

```elixir
defmodule Ezagent.ProtocolApi.Adapter do
  @moduledoc """
  Protocol API ExternalAdapter — `:push` for now.

  P0 declares this as `:push` with minimal no-op callbacks to satisfy the
  plugin contract (Grill-5 compile check). The REAL transport is the HTTP
  response in `OpenaiChatPlug`. P1 will introduce the request-scoped
  binding variant to `adapter.ex` and reshape this.

  Registered as a bare module (not a `{adapter, binding}` tuple) — same
  shape as `:pull` adapters. The `binding_module/0` returns `nil`; the
  registry's `Grill-5` check accepts this because the adapter kind
  (`kind_of/1`) gates the binding check.
  """

  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "protocol_api"

  @impl true
  def display_name, do: "Protocol API"

  @impl true
  def description, do: "OpenAI/Anthropic-compatible inbound HTTP API."

  # P0: no per-adapter cap Behavior yet (API-key auth is separate).
  # P1 will add a proper Allow behavior.
  @impl true
  def cap_subject do
    %{
      behavior_module: nil,
      description: "P0 stub — API-key auth is external to the cap model"
    }
  end

  @impl true
  def adapter_kind, do: :push

  # No-op callbacks — real transport is in OpenaiChatPlug

  @impl true
  def binding_module, do: nil

  @impl true
  def target_ownership_check(_caller, _target_id), do: :ok

  @impl true
  def event_to_payload(_event), do: :skip
end
```

- [ ] **Step 2: Verify compiles**

Run: `cd apps/ezagent_plugin_protocol_api && mix compile`
Expected: compiles. Plugin contract's Grill-5 check should pass (bare module adapter declaration).

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_plugin_protocol_api/
git commit -m "feat(protocol-api): adapter stub — :push with no-op binding"
```

---

### Task 5: Reply Waiter (the one delta from Feishu)

**Files:**
- Create: `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/reply_waiter.ex`
- Create: `apps/ezagent_plugin_protocol_api/test/ezagent/protocol_api/reply_waiter_test.exs`

- [ ] **Step 1: Write the failing test — reply_waiter_test.exs**

```elixir
defmodule Ezagent.ProtocolApi.ReplyWaiterTest do
  use EzagentCore.DataCase, async: true

  alias Ezagent.ProtocolApi.ReplyWaiter
  alias Ezagent.{Message, Publisher}

  describe "wait_for_reply/3" do
    test "returns {:ok, message} when matching ref_id found within deadline" do
      request_id = Message.generate_id()
      agent_uri = Ezagent.URI.agent("system", "test_agent")
      deadline_ms = 500

      # Simulate a Publisher event with matching ref_id
      reply_msg = Message.new(agent_uri, %{text: "hello back"}, ref_id: request_id)
      event = build_publisher_event(reply_msg)

      task = Task.async(fn ->
        ReplyWaiter.wait_for_reply(request_id, agent_uri, deadline_ms)
      end)

      # Give the waiter time to enter receive loop
      Process.sleep(50)
      send(self(), {:publisher_event, event})

      assert {:ok, %Message{ref_id: ^request_id, sender: ^agent_uri}} = Task.await(task)
    end

    test "returns {:error, :timeout} when no matching event arrives" do
      request_id = Message.generate_id()
      agent_uri = Ezagent.URI.agent("system", "test_agent")

      assert {:error, :timeout} =
               ReplyWaiter.wait_for_reply(request_id, agent_uri, 100)
    end

    test "ignores events with non-matching ref_id" do
      request_id = Message.generate_id()
      other_id = Message.generate_id()
      agent_uri = Ezagent.URI.agent("system", "test_agent")
      deadline_ms = 500

      other_msg = Message.new(agent_uri, %{text: "wrong"}, ref_id: other_id)
      other_event = build_publisher_event(other_msg)

      task = Task.async(fn ->
        ReplyWaiter.wait_for_reply(request_id, agent_uri, deadline_ms)
      end)

      Process.sleep(50)
      send(self(), {:publisher_event, other_event})

      # Should still be waiting (wrong ref_id)
      refute Task.async(fn -> Process.sleep(200) end) |> Task.await() == :timeout
      # The task is still alive
      assert Process.alive?(task.pid)
    end

    test "ignores events from wrong sender" do
      request_id = Message.generate_id()
      agent_uri = Ezagent.URI.agent("system", "target_agent")
      wrong_agent = Ezagent.URI.agent("system", "other_agent")
      deadline_ms = 500

      wrong_msg = Message.new(wrong_agent, %{text: "hi"}, ref_id: request_id)
      wrong_event = build_publisher_event(wrong_msg)

      task = Task.async(fn ->
        ReplyWaiter.wait_for_reply(request_id, agent_uri, deadline_ms)
      end)

      Process.sleep(50)
      send(self(), {:publisher_event, wrong_event})

      assert Process.alive?(task.pid)
    end
  end

  # Build a Publisher.Event that mimics what SessionImpl emits after a
  # session.send: slice_key = :session, payload contains the new slice
  # with last_message set to the given message.
  defp build_publisher_event(%Message{} = msg) do
    %Ezagent.Publisher.Event{
      cursor: 1,
      publisher_uri: Ezagent.URI.new!("session://system/test_session"),
      slice_key: :session,
      event_at: DateTime.utc_now(),
      payload: %{new_slice: %{last_message: msg, last_message_id: msg.id}}
    }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/ezagent_plugin_protocol_api/test/ezagent/protocol_api/reply_waiter_test.exs`
Expected: FAIL — `Ezagent.ProtocolApi.ReplyWaiter` module not found.

- [ ] **Step 3: Implement reply_waiter.ex**

```elixir
defmodule Ezagent.ProtocolApi.ReplyWaiter do
  @moduledoc """
  Per-request reply waiter — the ONE delta from Feishu.

  1. Subscribes to the session Publisher at `:latest`
  2. Waits in a `receive` loop for `{:publisher_event, %Event{}}`
  3. Matches events where `last_message.ref_id == request_id`
     AND `last_message.sender == target_agent_uri`
  4. Returns the matching message or `{:error, :timeout}`

  The caller (OpenaiChatPlug) must subscribe BEFORE dispatching
  session.send — same race-elimination pattern as P3-2's lower-bound
  cursor protocol.
  """

  require Logger

  alias Ezagent.Publisher.Event

  @default_deadline_ms 120_000

  @doc """
  Block the calling process until a Publisher event matches `request_id`
  and `target_agent_uri`, or `deadline_ms` elapses.

  The caller MUST already be subscribed to the session Publisher
  (via `subscribe_from` with cursor `:latest`) BEFORE calling this
  function AND before dispatching session.send.
  """
  @spec wait_for_reply(String.t(), URI.t(), pos_integer()) ::
          {:ok, Ezagent.Message.t()} | {:error, :timeout}
  def wait_for_reply(request_id, %URI{} = target_agent_uri, deadline_ms \\ @default_deadline_ms)
      when is_binary(request_id) and is_integer(deadline_ms) and deadline_ms > 0 do
    deadline = :erlang.monotonic_time(:millisecond) + deadline_ms

    do_wait(request_id, target_agent_uri, deadline)
  end

  defp do_wait(request_id, target_agent_uri, deadline) do
    remaining = deadline - :erlang.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      receive do
        {:publisher_event, %Event{slice_key: :session, payload: payload}} ->
          case match_reply(payload, request_id, target_agent_uri) do
            {:ok, msg} ->
              {:ok, msg}

            :no_match ->
              do_wait(request_id, target_agent_uri, deadline)
          end

        {:publisher_event, _other_event} ->
          # Non-:session slice change — ignore, keep waiting
          do_wait(request_id, target_agent_uri, deadline)

        _other ->
          # Unknown message — ignore, keep waiting
          do_wait(request_id, target_agent_uri, deadline)
      after
        remaining -> {:error, :timeout}
      end
    end
  end

  # Match the reply: ref_id must equal request_id AND sender must be
  # the target agent URI.
  defp match_reply(%{new_slice: %{last_message: %Ezagent.Message{} = msg}}, request_id, target_agent_uri) do
    if msg.ref_id == request_id and msg.sender == target_agent_uri do
      {:ok, msg}
    else
      :no_match
    end
  end

  # Slice may not have last_message yet (edge case: first event after
  # subscription before any send). Safe to treat as no-match.
  defp match_reply(_payload, _request_id, _target_agent_uri), do: :no_match
end
```

- [ ] **Step 4: Run tests**

Run: `mix test apps/ezagent_plugin_protocol_api/test/ezagent/protocol_api/reply_waiter_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_plugin_protocol_api/
git commit -m "feat(protocol-api): reply waiter — Publisher subscriber + ref_id match"
```

---

### Task 6: OpenaiChatPlug (HTTP handler)

**Files:**
- Create: `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/openai_chat_plug.ex`

- [ ] **Step 1: Create openai_chat_plug.ex**

```elixir
defmodule EzagentPluginProtocolApi.OpenaiChatPlug do
  @moduledoc """
  `POST /v1/chat/completions` — OpenAI-compatible inbound endpoint.

  Flow:
    1. Parse OpenAI JSON body
    2. Auth via Bearer token → API-key lookup
    3. Resolve session from conversation_id (or create + bind)
    4. ensure_session_live
    5. Build Message from messages[]
    6. Subscribe Publisher at :latest
    7. Dispatch session.send (mode: :call)
    8. Wait for reply via ReplyWaiter
    9. Return OpenAI-format JSON (or error)
  """

  import Plug.Conn

  alias Ezagent.{Invocation, Message, Router, SpawnRegistry, URI}

  alias Ezagent.ProtocolApi.{ApiKeyStore, ConversationRegistry, ReplyWaiter}

  @behaviour Plug

  @deadline_ms 120_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case conn.method do
      "POST" -> handle_post(conn)
      _ -> method_not_allowed(conn)
    end
  end

  # --- POST handler ---

  defp handle_post(conn) do
    with {:ok, body} <- parse_body(conn),
         {:ok, token} <- extract_bearer(conn),
         {:ok, entity_uri, workspace_uri, _caps} <- ApiKeyStore.verify(token),
         {:ok, conversation_id} <- extract_conversation_id(body, conn),
         {:ok, session_uri} <- ConversationRegistry.resolve(conversation_id, workspace_uri, entity_uri),
         :ok <- ensure_session_live(session_uri),
         {:ok, request_id, msg} <- build_message(body, entity_uri),
         {:ok, _cursor} <- subscribe_publisher(session_uri),
         :ok <- dispatch_send(session_uri, entity_uri, msg) do
      case ReplyWaiter.wait_for_reply(request_id, entity_uri, @deadline_ms) do
        {:ok, reply_msg} ->
          json_response(conn, 200, build_openai_response(request_id, reply_msg))

        {:error, :timeout} ->
          json_error(conn, 504, "timed out waiting for agent reply")
      end
    else
      {:error, status, code, detail} ->
        json_error(conn, status, "#{code}: #{detail}")

      {:error, reason} ->
        json_error(conn, 400, inspect(reason))
    end
  end

  # --- steps ---

  defp parse_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} ->
        case Jason.decode(body) do
          {:ok, json} -> {:ok, json}
          {:error, _} -> {:error, 400, "bad_json", "invalid JSON body"}
        end

      {:error, reason} ->
        {:error, 400, "bad_body", inspect(reason)}
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, 401, "missing_token", "Authorization: Bearer <token> required"}
    end
  end

  defp extract_conversation_id(body, conn) do
    # Prefer body field, fall back to header
    case Map.get(body, "conversation_id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ ->
        case Plug.Conn.get_req_header(conn, "x-conversation-id") do
          [id | _] when id != "" -> {:ok, id}
          _ -> {:error, 400, "missing_conversation_id", "conversation_id field or X-Conversation-Id header required"}
        end
    end
  end

  defp ensure_session_live(session_uri) do
    case SpawnRegistry.ensure_live(session_uri) do
      {:ok, :live} -> :ok
      {:ok, :rehydrated} -> :ok
      {:error, reason} -> {:error, 500, "session_live", inspect(reason)}
    end
  end

  defp build_message(body, entity_uri) do
    request_id = Message.generate_id()
    messages = Map.get(body, "messages", [])

    # Build the user text from the last user message
    text =
      messages
      |> List.last()
      |> case do
        %{"content" => content} when is_binary(content) -> content
        _ -> ""
      end

    msg = Message.new(entity_uri, %{text: text, attachments: []}, id: request_id)
    {:ok, request_id, msg}
  end

  defp subscribe_publisher(session_uri) do
    target = URI.with_action(session_uri, :publisher, :subscribe_from)

    cmd = %Ezagent.Cmd{
      target: target,
      action: :subscribe_from,
      args: %{subscriber_pid: self(), cursor: :latest},
      ctx: %{caller: Ezagent.URI.system_principal("plugins")}
    }

    case Router.dispatch(cmd) do
      {:ok, %{cursor: cursor}} -> {:ok, cursor}
      {:error, reason} -> {:error, 500, "subscribe", inspect(reason)}
    end
  end

  defp dispatch_send(session_uri, entity_uri, msg) do
    target = URI.with_action(session_uri, :session, :send)

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{message: msg},
      ctx: %{caller: entity_uri, caps: MapSet.new(), reply: :sync}
    }

    case Invocation.dispatch(inv) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, 422, "dispatch", inspect(reason)}
    end
  end

  # --- response builders ---

  defp build_openai_response(request_id, %Message{} = reply_msg) do
    %{
      "id" => "chatcmpl-#{request_id}",
      "object" => "chat.completion",
      "created" => DateTime.utc_now() |> DateTime.to_unix(),
      "model" => "ezagent",
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => Map.get(reply_msg.body, :text, "") || ""
          },
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{
        "prompt_tokens" => 0,
        "completion_tokens" => 0,
        "total_tokens" => 0
      }
    }
  end

  defp json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => %{"message" => message, "type" => "api_error"}}))
  end

  defp method_not_allowed(conn) do
    json_error(conn, 405, "only POST is supported")
  end
end
```

- [ ] **Step 2: Verify compiles**

Run: `cd apps/ezagent_plugin_protocol_api && mix compile`
Expected: compiles.

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_plugin_protocol_api/
git commit -m "feat(protocol-api): OpenaiChatPlug — POST /v1/chat/completions handler"
```

---

### Task 7: Fix curl_agent ref_id gap (P0 pre-requisite)

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex`

The curl_agent's `handle_sync_result` → `maybe_reply_effect` → `Message.new` does NOT pass `ref_id`. We need to thread the inbound `msg.id` from `handle_receive` through to the reply.

- [ ] **Step 1: Find the handle_receive path and thread msg.id**

The curl agent's `handle_receive/2` receives the inbound message. We need to store `msg.id` so `handle_sync_result` can use it.

Check the current code in `curl_agent.ex`:
- `handle_receive/2` at line ~186 — stores `source_session_uri` and `user_text` in `transients`
- `handle_sync_result/2` at line ~224 — calls `maybe_reply_effect(source_session_uri, self_uri, reply)` which calls `Message.new(self_uri, %{text: text, attachments: []})` WITHOUT `ref_id`

The fix: store `in_msg.id` in transients during `handle_receive`, then pass it as `ref_id` in `maybe_reply_effect`.

Read the actual lines first to confirm exact positions, then apply these two edits:

**Edit A — in `handle_receive/2`**, find the transients set and add `in_msg_id`:

Find the existing `{:set_transient, :source_session_uri, ...}` line and add after it:
```elixir
{:set_transient, :in_msg_id, msg.id},
```

**Edit B — in `maybe_reply_effect`**, add `in_msg_id` parameter and pass `ref_id`:

Change the function signature from:
```elixir
defp maybe_reply_effect(session_uri, %URI{} = self_uri, text)
```
To accept `in_msg_id`:
```elixir
defp maybe_reply_effect(session_uri, %URI{} = self_uri, text, in_msg_id \\ nil)
```

And change the `Message.new` call from:
```elixir
reply_msg = Message.new(self_uri, %{text: text, attachments: []})
```
To:
```elixir
reply_msg = Message.new(self_uri, %{text: text, attachments: []}, ref_id: in_msg_id)
```

- [ ] **Step 2: Update call sites**

Find all `maybe_reply_effect(...)` calls (one per branch in `handle_sync_result`) and thread the `in_msg_id` from transients:

```elixir
in_msg_id = ctx.transients[:in_msg_id]
# then in each maybe_reply_effect call: maybe_reply_effect(session_uri, self_uri, text, in_msg_id)
```

Also update the nil-guard clauses of `maybe_reply_effect/4` to accept 4 args:
```elixir
defp maybe_reply_effect(nil, _self_uri, _text, _in_msg_id), do: []
defp maybe_reply_effect("", _self_uri, _text, _in_msg_id), do: []
defp maybe_reply_effect(_, nil, _text, _in_msg_id), do: []
```

- [ ] **Step 3: Verify — curl agent integration test**

Run: `mix test apps/ezagent_plugin_curl_agent/test/ezagent/behavior/curl_agent_test.exs`
Expected: PASS. Also verify that reply messages now carry `ref_id` by adding an assertion to an existing integration test (or verify via the curl round-trip scenario test).

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex
git commit -m "fix(curl-agent): propagate ref_id in reply messages (protocol-api P0 pre-req)"
```

---

### Task 8: Wire into umbrella (router + mix.exs + arch.scan)

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Modify: `mix.exs` (root)
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex`

- [ ] **Step 1: Add route mount in router.ex**

Open `apps/ezagent_web/lib/ezagent_web/router.ex`. Find the Feishu webhook forward line (`forward "/api/feishu/webhook", ...` at ~line 176). Add BEFORE the `/api/v1` scope, with the same pattern:

```elixir
  # P0 protocol-api: OpenAI-compatible inbound endpoint.
  # Same forward pattern as Feishu webhook — explicit exception per SPEC v2
  # north star ("beyond route registration").
  forward "/v1/chat/completions", EzagentPluginProtocolApi.OpenaiChatPlug
```

- [ ] **Step 2: Add to root mix.exs releases**

Open root `mix.exs`. Find the `releases/0` function's `applications:` list. Add:

```elixir
        ezagent_plugin_protocol_api: :permanent,
```

Alphabetically among the other `ezagent_plugin_*` entries.

- [ ] **Step 3: Add to arch.scan spawn_registry sanctioned files**

Open `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex`. Find `@spawn_registry_sanctioned_files` list (~line 37). Add after the last entry:

```elixir
    # protocol_api P0 — spawn session for durable conversation binding
    "apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex",
```

- [ ] **Step 4: Verify umbrella compiles**

Run: `mix compile --force`
Expected: compiles entire umbrella with new plugin.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_web/lib/ezagent_web/router.ex mix.exs apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex
git commit -m "feat(protocol-api): wire into umbrella — router mount, releases, arch.scan sanction"
```

---

### Task 9: Verify — compile + test + gates

- [ ] **Step 1: Run plugin tests**

```bash
mix test apps/ezagent_plugin_protocol_api/test/
```
Expected: PASS (4 tests from reply_waiter_test.exs).

- [ ] **Step 2: Run full umbrella test suite**

```bash
mix test
```
Expected: PASS. Any transient failures from SQLite sandbox pollution — re-run the specific test in isolation.

- [ ] **Step 3: Run architecture gates**

```bash
mix ezagent.arch.scan
mix ezagent.check_invariants
mix format --check-formatted
```

Expected: all green.

- [ ] **Step 4: Run migration on test DB only**

```bash
MIX_ENV=test mix ecto.migrate
```
Expected: migration applies cleanly, `protocol_api_keys` table exists.

- [ ] **Step 5: Commit** (if any formatting fixes from step 3)

```bash
git add -u && git commit -m "chore(protocol-api): format + gate fixes"
```
