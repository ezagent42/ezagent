# Real-time (Phoenix PubSub, Channel, Presence)

Phoenix's real-time story has three layers, each doing one thing well:

| Layer | What it does | When to reach for it |
|---|---|---|
| **`Phoenix.PubSub`** | In-process and cross-node broadcast on named topics | Any fan-out inside your app — LiveView updates, cache invalidation, event notifications |
| **`Phoenix.Channel`** | Bi-directional WebSocket messaging with authenticated sockets | Native mobile clients, custom browser JS clients, IoT devices, anywhere LiveView's SSR+diff model does not fit |
| **`Phoenix.Presence`** | Distributed tracking of who is connected, with conflict-free merging | "Who's online", "who's typing", "who's viewing this document" |

LiveView uses all three internally. If you are building web UI, LiveView probably covers your real-time needs without writing a Channel — see [phoenix-web.md](phoenix-web.md).

## Phoenix.PubSub

PubSub is the foundation. Every real-time feature in Phoenix is either PubSub or uses PubSub.

### Setup

In your application's supervision tree (usually already there after `mix phx.new`):

```elixir
{Phoenix.PubSub, name: MyApp.PubSub}
```

One PubSub instance serves the whole application. You do not need multiple.

### Publish and subscribe

```elixir
# In a LiveView or GenServer that wants to listen:
Phoenix.PubSub.subscribe(MyApp.PubSub, "room:42")

# Anywhere in the app:
Phoenix.PubSub.broadcast(MyApp.PubSub, "room:42", {:message_created, msg})

# Received as a plain message in handle_info/2:
def handle_info({:message_created, msg}, socket) do
  {:noreply, stream_insert(socket, :messages, msg)}
end
```

### Topic scoping — critical for multi-tenant safety

A topic is just a string. Untenanted topics leak across tenants. **Always scope topics.** In Phoenix 1.8, the idiomatic way is to derive the topic from the `%Scope{}` struct inside your context, so call sites never build topic strings:

```elixir
# In a context:
defmodule MyApp.Blog do
  alias MyApp.Accounts.Scope

  def subscribe_posts(%Scope{} = scope) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, topic(scope))
  end

  def broadcast_post(%Scope{} = scope, event, post) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, topic(scope), {event, post})
  end

  # Topic is a private implementation detail — callers never build it themselves
  defp topic(%Scope{user: %{id: uid}}), do: "user:#{uid}:posts"
  # Or for org-scoped data:
  # defp topic(%Scope{organization: %{id: oid}}), do: "org:#{oid}:posts"
end

# Call site — never touches topic strings:
Blog.subscribe_posts(socket.assigns.current_scope)
```

For use cases without a natural Scope (system-wide events, presence on a shared resource like a public room), use a hand-built topic with a clear convention:

```elixir
defmodule MyApp.Topics do
  def room(room_id), do: "room:#{room_id}"
  def user_notifications(user_id), do: "user:#{user_id}:notifications"
  def system_events(), do: "system:events"
end
```

Convention: `{scope_type}:{scope_id}:{event_type}`. Every call site goes through `MyApp.Topics.*` — no ad-hoc string building, no accidental leakage.

**The anti-pattern to refuse to produce:**

```elixir
# WRONG — topic built at call site, no scope
Phoenix.PubSub.broadcast(MyApp.PubSub, "messages", msg)

# WRONG — scope data in the topic but constructed ad-hoc
Phoenix.PubSub.broadcast(MyApp.PubSub, "user:#{user.id}:messages", msg)
# (the second one is safer but still fragile — any typo creates a fresh invisible topic)
```

### `broadcast` vs `broadcast_from`

```elixir
# Broadcasts to everyone including the sender:
Phoenix.PubSub.broadcast(MyApp.PubSub, topic, msg)

# Broadcasts to everyone EXCEPT the sender:
Phoenix.PubSub.broadcast_from(MyApp.PubSub, self(), topic, msg)
```

Use `broadcast_from` when the originating process already has the data locally and does not need to re-apply it via the message — this is the typical case in chat apps (the sender already sees the message they just typed).

### `local_broadcast`

If the message only matters on the current node (e.g. local cache invalidation), use `local_broadcast/3` — it skips the distributed path and is faster. Rare, but useful for performance-sensitive in-node fan-out.

### Distributed PubSub

`Phoenix.PubSub` uses `:pg` (process groups) by default and is distributed across connected BEAM nodes automatically. Subscribers on node B receive messages broadcast from node A. There is no extra configuration beyond clustering the nodes (`libcluster`, `epmd`, etc.).

For heavier cross-node traffic, switch to the Redis adapter:

```elixir
{Phoenix.PubSub.Redis, name: MyApp.PubSub, url: "redis://..."}
```

## Phoenix.Channel

Channels are Phoenix's bi-directional WebSocket protocol. Every connection gets a `Socket`, and sockets join `Channels` on named topics. Each joined channel is its own process with its own state.

### When to use Channels

- Native clients (iOS, Android) that talk to Phoenix over WebSocket.
- Custom JS clients where LiveView's SSR diffing is not a fit.
- Embedded devices or game clients over WebSocket/long-polling.
- Anywhere you need a persistent connection with a custom protocol.

**For a web app with interactive UI, use LiveView instead** — it gives you the same underlying transport with far less ceremony.

### Socket (the connection)

```elixir
defmodule MyAppWeb.UserSocket do
  use Phoenix.Socket

  channel "room:*", MyAppWeb.RoomChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case MyApp.Accounts.verify_token(token) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      {:error, _}    -> :error
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
```

- `connect/3` authenticates the connection. Reject here, not later.
- `id/1` enables `MyAppWeb.Endpoint.broadcast("user_socket:#{id}", "disconnect", %{})` for forced disconnects (e.g. on logout).
- `channel "room:*"` routes any `room:<anything>` topic to `RoomChannel`.

### Channel

```elixir
defmodule MyAppWeb.RoomChannel do
  use Phoenix.Channel

  alias MyApp.Rooms

  @impl true
  def join("room:" <> room_id, _params, socket) do
    case Rooms.authorize(socket.assigns.user_id, room_id) do
      :ok ->
        send(self(), :after_join)
        {:ok, assign(socket, :room_id, room_id)}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    messages = Rooms.list_recent_messages(socket.assigns.room_id)
    push(socket, "backfill", %{messages: messages})
    {:noreply, socket}
  end

  @impl true
  def handle_in("new_message", %{"body" => body}, socket) do
    case Rooms.create_message(socket.assigns.user_id, socket.assigns.room_id, body) do
      {:ok, msg} ->
        broadcast!(socket, "new_message", render_message(msg))
        {:reply, :ok, socket}

      {:error, cs} ->
        {:reply, {:error, %{errors: error_list(cs)}}, socket}
    end
  end

  defp render_message(msg), do: %{id: msg.id, body: msg.body, inserted_at: msg.inserted_at}
  defp error_list(cs), do: Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
end
```

- **`join/3` is where authorization happens.** Return `{:error, _}` to refuse — the client cannot join a channel they are not allowed to.
- **`send(self(), :after_join)`** is the canonical pattern for "do stuff after join completes" — you cannot do blocking work inside `join/3` without delaying the client.
- **`broadcast!/3`** fans out to every process subscribed to the channel's topic. `push/3` sends only to the socket that called the function.
- **Return `{:reply, :ok | {:ok, payload} | :error | {:error, payload}, socket}`** from `handle_in/3` when the client expects an ack.

### Intercept — rewriting outgoing messages per-subscriber

If the message to broadcast should differ per subscriber (e.g. hide the message body from the sender because they already rendered it optimistically):

```elixir
intercept ["new_message"]

@impl true
def handle_out("new_message", payload, socket) do
  if payload.sender_id == socket.assigns.user_id do
    push(socket, "new_message", Map.put(payload, :own, true))
  else
    push(socket, "new_message", payload)
  end
  {:noreply, socket}
end
```

Use sparingly — `intercept` runs for every subscriber on every broadcast and can hurt fan-out throughput.

## Phoenix.Presence

Presence tracks which users are connected to which topics, with CRDT-based merging so it works correctly across nodes.

### Setup

```elixir
defmodule MyAppWeb.Presence do
  use Phoenix.Presence,
    otp_app: :my_app,
    pubsub_server: MyApp.PubSub
end
```

Add it to the supervision tree:

```elixir
MyAppWeb.Presence
```

### Usage in a Channel

```elixir
@impl true
def join("room:" <> room_id, _params, socket) do
  send(self(), :after_join)
  {:ok, assign(socket, :room_id, room_id)}
end

@impl true
def handle_info(:after_join, socket) do
  {:ok, _} = MyAppWeb.Presence.track(socket, socket.assigns.user_id, %{
    online_at: System.system_time(:second),
    typing: false
  })
  push(socket, "presence_state", MyAppWeb.Presence.list(socket))
  {:noreply, socket}
end
```

The client gets `presence_state` on join and `presence_diff` events as users come and go. The server state is automatically cleaned up when a process exits.

### Usage in a LiveView

```elixir
def mount(%{"id" => id}, _session, socket) do
  scope = socket.assigns.current_scope
  topic = "room:#{id}"

  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, topic)
    MyAppWeb.Presence.track(self(), topic, scope.user.id, %{
      email: scope.user.email
    })
  end

  {:ok, assign(socket, room_id: id, users: MyAppWeb.Presence.list(topic))}
end

def handle_info(%{event: "presence_diff", payload: diff}, socket) do
  {:noreply, update(socket, :users, &merge_diff(&1, diff))}
end
```

### Presence state shape

```elixir
%{
  "user_id_1" => %{
    metas: [
      %{online_at: 1_700_000_000, typing: false, phx_ref: "..."},
      # multiple entries if the user is connected from multiple tabs/devices
    ]
  },
  "user_id_2" => %{metas: [...]}
}
```

Each user can have multiple `metas` (one per connection). When the last connection closes, the user is removed from the list. The `phx_ref` is used internally for CRDT reconciliation — do not rely on it in your code.

### Updating metadata (e.g. typing indicator)

```elixir
MyAppWeb.Presence.update(socket, socket.assigns.user_id, fn meta ->
  Map.put(meta, :typing, true)
end)
```

## Soft-realtime delivery model

Phoenix channels are **soft-realtime**: messages are delivered on a best-effort basis over the WebSocket, with at-most-once semantics. A dropped connection can mean lost messages. For use cases that require at-least-once or exactly-once delivery:

- **Persist first, broadcast second.** Write to the database, then broadcast a notification. On reconnect, the client fetches missed messages via a timestamp or cursor.
- **Dedupe on the client.** Include a stable message ID; the client ignores duplicates.
- **Use a queue** (Oban, RabbitMQ, Kafka) for durable delivery — Channels are not the right primitive.

## Pitfalls in real-time

1. **Unscoped PubSub topics → cross-tenant leaks.** In Phoenix 1.8, derive the topic from `%Scope{}` inside the context — callers never build topic strings. For non-scope topics, use a `MyApp.Topics` helper module.
2. **Heavy work in `handle_info/2` or `handle_in/3`.** Do it in a `Task.Supervisor` and message the result back.
3. **Storing large state in the socket.** Each connection pays the memory cost — multiply by concurrent users.
4. **Assuming message delivery.** Soft-realtime. Persist and reconcile.
5. **Not using `broadcast_from/4` when the sender already has the data** — wastes bandwidth and triggers redundant renders.
6. **Presence `track/3` called from the wrong process.** Track the PID that owns the presence — typically `self()` in a channel or LiveView. If that process dies, presence is cleaned up. Tracking from a Task means presence dies when the Task finishes.
7. **Unbounded channel mailboxes under load.** If a channel process cannot keep up, its mailbox grows. Instrument mailbox sizes; for very high fan-out, consider sharding topics or using a dedicated broadcast worker pool.
8. **Authorization only at `join/3`, not per-message.** For permission changes during the session (user demoted mid-conversation), re-check on each `handle_in/3` that performs a mutation.
