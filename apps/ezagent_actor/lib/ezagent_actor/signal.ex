defmodule EzagentActor.Signal do
  @moduledoc """
  V5 pid-closure (use side), B1 — the framework-owned SIGNAL transport
  (ADDITIVE: nothing is routed onto it yet, nothing is sealed).

  The sanctioned way to put a message into a Kind mailbox. Every function
  here delivers the SAME envelope shape — this module's struct — so a
  recipient (`Ezagent.Kind.Server.handle_info/2`, sealed in H3) can
  pattern-match `%EzagentActor.Signal{}` and know the message came through
  the framework transport:

      %EzagentActor.Signal{kind: :signal,    from: nil,   payload: term}
      %EzagentActor.Signal{kind: :broadcast, from: topic, payload: term}
      %EzagentActor.Signal{kind: :down,      from: pid,   payload: %{ref:, pid:, reason:}}
      %EzagentActor.Signal{kind: :timer,     from: pid,   payload: term}

  ## Guarantee scope (anti-drift, NOT authentication)

  The sealed mailbox this transport feeds is **gate-conforming,
  shape-sealed ANTI-DRIFT** (0524 trusted-BEAM): it stops an accidental /
  unknown-shape raw send from mutating a Kind's durable state, and fixes
  the `FunctionClauseError` DoS an unmatched mailbox term causes today.
  It is NOT authenticated or forgery-resistant — any same-BEAM process can
  construct this struct. Sanctioning is by SHAPE only; there is
  deliberately NO nonce / capability / provenance machinery here.

  ## The API

    * `signal/2` — direct signal to a resolver key (a Kind URI or sidecar
      key). Resolves through `Ezagent.Runtime.Resolver` (the A1a pid
      seam — the pid never leaves it) and delivers the envelope.
    * `broadcast/2` / `subscribe/1` / `unsubscribe/1` — PubSub fan-out
      where the DELIVERED TERM is the envelope struct, never a raw tuple.
      The PubSub server is the C5 §3.4 config port
      (`Application.fetch_env!(:ezagent_actor, :pubsub)`, wired at core
      boot; the actor app never names the spine module).
    * `monitor/1` — a BEAM `Process.monitor/1` DOWN is a raw
      `{:DOWN, ref, :process, pid, reason}` tuple whose shape the VM does
      not let the caller change, so Kind code never monitors directly:
      `EzagentActor.Signal.Monitor` (a framework process) owns the raw
      monitor and re-delivers the death as a `%Signal{kind: :down}`.
    * `send_after/2` — a timer message to SELF, wrapped at schedule time
      so it arrives as `%Signal{kind: :timer}` (the sanctioned
      replacement for `Process.send_after(self(), :atom_or_tuple, ms)`
      self-timers such as the reconcile loops).

  Behavior authors call these from any callback that runs inside the Kind
  process (`handle_kind_message/3`, `post_init/2`, Lifecycle
  `activate/2`, …) — the behavior `ctx` already carries `self_uri`, so no
  ctx shape change is needed. `Kind.Server.handle_info/2` and every
  existing producer are UNCHANGED in B1 (B2 migrates producers onto this
  transport; B3 seals the mailbox against everything else).
  """

  @typedoc """
  How the envelope entered the mailbox: `:signal` (direct `signal/2`),
  `:broadcast` (PubSub), `:down` (monitor relay), `:timer` (`send_after/2`).
  """
  @type kind :: :signal | :broadcast | :down | :timer

  @typedoc "The sanctioned Kind-mailbox envelope."
  @type t :: %__MODULE__{kind: kind(), from: term(), payload: term()}

  @enforce_keys [:kind, :payload]
  defstruct [:kind, :payload, from: nil]

  alias Ezagent.Runtime.Resolver

  @doc """
  Send `payload` to `target` (a resolver key — Kind URI or sidecar key) as
  a `%Signal{kind: :signal}` envelope.

  The pid never leaves the resolver seam: delivery rides
  `Resolver.send_envelope/2`, so this returns `:ok` when delivered and
  `:not_found` when nothing is registered under `target`.
  """
  @spec signal(Resolver.key(), term()) :: :ok | :not_found
  def signal(target, payload) do
    Resolver.send_envelope(target, %__MODULE__{kind: :signal, payload: payload})
  end

  @doc """
  Broadcast `payload` on `topic` as a `%Signal{kind: :broadcast}` envelope.

  Every subscriber (via `subscribe/1`, or any same-BEAM
  `Phoenix.PubSub.subscribe/3` — topics are public-derivable, see
  `Ezagent.SliceChange` on why that is not a secret) receives the envelope
  struct, never a raw tuple.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, payload) when is_binary(topic) do
    Phoenix.PubSub.broadcast(
      pubsub(),
      topic,
      %__MODULE__{kind: :broadcast, from: topic, payload: payload}
    )
  end

  @doc """
  Subscribe the calling process to `topic`. Broadcasts made through
  `broadcast/2` then arrive as `%Signal{kind: :broadcast}` envelopes.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(pubsub(), topic)

  @doc "Inverse of `subscribe/1`."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) when is_binary(topic), do: Phoenix.PubSub.unsubscribe(pubsub(), topic)

  @doc """
  Monitor `pid`, with the death notice re-delivered to the CALLER as a
  `%Signal{kind: :down}` envelope whose payload is
  `%{ref: ref, pid: pid, reason: reason}`.

  Returns `{:ok, ref}` — the caller correlates on `ref` exactly as it
  would with a raw `Process.monitor/1`. The raw monitor is owned by
  `EzagentActor.Signal.Monitor` (app-supervised); monitoring an
  already-dead pid delivers the envelope with `reason: :noproc`, mirroring
  BEAM semantics.
  """
  @spec monitor(pid()) :: {:ok, reference()}
  def monitor(pid) when is_pid(pid), do: EzagentActor.Signal.Monitor.monitor(pid)

  @doc """
  Schedule `payload` to arrive in the CALLER's own mailbox after
  `time_ms` milliseconds as a `%Signal{kind: :timer}` envelope.

  Returns the timer reference (usable with `Process.cancel_timer/1`,
  which never produces a message). This is the sanctioned replacement for
  `Process.send_after(self(), raw_term, ms)` self-timers — the envelope
  is wrapped at schedule time, so what arrives is already the sanctioned
  shape.
  """
  @spec send_after(term(), non_neg_integer()) :: reference()
  def send_after(payload, time_ms) when is_integer(time_ms) and time_ms >= 0 do
    Process.send_after(self(), %__MODULE__{kind: :timer, from: self(), payload: payload}, time_ms)
  end

  @doc """
  The effective raw mailbox message an envelope stands in for (so existing
  handlers match unchanged).

  A `:down` envelope reconstructs the exact
  `{:DOWN, ref, :process, pid, reason}` tuple a raw `Process.monitor/1`
  would have delivered — every existing `handle_signal({:DOWN, …})`
  consumer matches UNCHANGED. All other envelopes unwrap to `payload`
  verbatim. The result is never a `%__MODULE__{}`, so the H3 sealed
  `Kind.Server` routing (`handle_info(%Signal{})` → the private
  `dispatch_sanctioned/2` router) cannot loop.
  """
  @spec effective_message(t()) :: term()
  def effective_message(%__MODULE__{kind: :down, payload: %{ref: ref, pid: pid, reason: reason}}),
    do: {:DOWN, ref, :process, pid, reason}

  def effective_message(%__MODULE__{payload: payload}), do: payload

  # C5 §3.4 pubsub injection — the PubSub server name is a config port,
  # never a literal spine reference (same idiom as `Ezagent.SliceChange`).
  # Wired at core boot (`Ezagent.Kind.Adapters.wire!/0`); tests pre-wire
  # their own PubSub.
  defp pubsub, do: Application.fetch_env!(:ezagent_actor, :pubsub)
end
