defmodule Ezagent.AgentBridge.Adapter do
  @moduledoc """
  Transport-neutral per-flavor adapter for AgentBridge delivery.

  The domain bridge owns flavor → adapter resolution and dispatch; each
  plugin adapter translates the generic payload into its transport
  protocol. An adapter declares its **transport class** so the bridge can
  pick the right delivery machinery:

    * `:subprocess_ws` — the status-quo cc / codex flavors. Delivery fans
      out through a Phoenix.Channel sidecar (the subprocess's WebSocket).
      `deliver/2` is handed the **Channel pid** and fires into the WS,
      returning `:ok`; the agent's reply comes back ASYNCHRONOUSLY through
      the bridge (→ `session.send`). These flavors implement the WS-only
      callbacks (`handle_client_event/3`, `join_info/2`, `socket_path/0`,
      `channel_topic_prefix/0`) and engage the readiness/buffer gate
      (`AdapterRegistry.deliver_or_buffer/3`, `deliver_ensuring/3`).

    * `:in_process_sync` — a future curl-style flavor (PR-6). There is NO
      subprocess and NO WebSocket. `deliver/2` is handed `nil` for the
      channel ref, performs its work in-process (e.g. an HTTP round-trip),
      and returns `{:ok, result}` SYNCHRONOUSLY — the result the owning
      Behavior persists via `{:set, …}` effects. This class never reaches
      the Channel, the Registry lookup, or the `ensure_ready` readiness
      gate.

  ## Per-class required-callback contract

  | Callback              | `:subprocess_ws` (cc, codex)        | `:in_process_sync` (curl) |
  |-----------------------|-------------------------------------|---------------------------|
  | `flavor/0`            | required                            | required                  |
  | `transport_class/0`   | required (`:subprocess_ws`)         | required (`:in_process_sync`) |
  | `deliver/2`           | required (channel_ref = Channel pid)| required (channel_ref = `nil`) |
  | `handle_client_event/3` | **required**                      | not implemented           |
  | `join_info/2`         | **required**                        | not implemented           |
  | `socket_path/0`       | **required**                        | not implemented           |
  | `channel_topic_prefix/0` | **required**                     | not implemented           |

  The WS-only callbacks are `@optional_callbacks` on the behaviour so an
  `:in_process_sync` adapter need not implement them. They remain
  REQUIRED-by-contract for `:subprocess_ws` flavors — a `:subprocess_ws`
  adapter that omits them will fail at the WS boundary.

  ## `deliver/2` return type

  Widened to `:ok | {:ok, term()} | {:error, term()}`:

    * `:subprocess_ws` returns `:ok` (fire-into-WS; reply is async).
    * `:in_process_sync` returns `{:ok, result}` (the sync result the
      owning Behavior consumes) or `{:error, reason}`.

  Do NOT narrow this back to `:ok | {:error, term()}` — the future curl
  Behavior depends on the `{:ok, result}` payload.
  """

  @type transport_class :: :subprocess_ws | :in_process_sync

  @callback flavor() :: String.t()
  @callback transport_class() :: transport_class()

  @callback deliver(Ezagent.AgentBridge.Payload.t(), channel_ref :: pid() | nil) ::
              :ok | {:ok, term()} | {:error, term()}

  # WS-only callbacks — REQUIRED for :subprocess_ws, NOT IMPLEMENTED for :in_process_sync.
  @callback handle_client_event(String.t(), map(), Phoenix.Socket.t()) ::
              {:reply, {:ok | :error, map()}, Phoenix.Socket.t()}
              | {:noreply, Phoenix.Socket.t()}

  @callback join_info(map(), Phoenix.Socket.t()) :: map()
  @callback socket_path() :: String.t()
  @callback channel_topic_prefix() :: String.t()

  @optional_callbacks handle_client_event: 3,
                      join_info: 2,
                      socket_path: 0,
                      channel_topic_prefix: 0
end
