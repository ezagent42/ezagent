defmodule EzagentPluginAutoservice.SocialwareCSTurnAdapter do
  @moduledoc """
  Task 5 — CS turn adapter (DD1).

  Bridges a **single-bot** customer-service exchange into socialware Turn
  semantics so the customer sees the bot reply through the visibility-gated
  `Ezagent.Socialware.CustomerFeed`. The CS session has no fast/slow biphasic and
  no worker fan-out — a turn here is *degenerate*: one customer message in, one
  coalesced bot reply out.

  ## DD1 design (approved)

    * A **customer** message in the session opens a degenerate turn —
      `turn.open` with no subtasks.
    * The bot replies via normal chat. The adapter **coalesces** the bot's reply
      message(s) over an **idle window `W`** (no new bot message within `W`),
      then drives `turn.compose` followed by `turn.settle`.
    * `turn.compose` is given a single result_ref of shape
      `%{kind: :chat, text: <coalesced reply>}`. The turn is in `:auto` mode, so
      the composed chat message is written `:customer_visible`; `turn.settle`
      drives the `Settlement` to `:committed`, after which
      `CustomerFeed.snapshot/2` returns the reply.

  ## Two surfaces — pure core + thin process

  The real bot is a live cc agent, so the adapter is split so its CORE is
  directly callable (and therefore deterministically testable without a live
  agent or a real timer):

    * `customer_message/3` — GIVEN "a customer message arrived", drives
      `turn.open` and returns the open-turn handle.
    * `bot_reply/4` — GIVEN "a (coalesced) bot reply text", drives
      `turn.compose` then `turn.settle` on the open turn.
    * `operator_claim/5` — GIVEN "an operator takes over with an edited reply",
      drives `turn.compose` then `turn.claim` so the draft is **held**
      `:operator_only` (not shown to the customer) while awaiting the human.
    * `operator_settle/3` — settles an operator-claimed turn, flipping the held
      draft to `:customer_visible` so the customer sees the operator's version.

  `start_link/1` + the `GenServer` callbacks are the thin process: one adapter
  per session that subscribes to the chat session-events topic, distinguishes
  customer from bot by message **sender**, opens a turn on the first customer
  message, and coalesces bot replies over `W` (a `Process.send_after/3` flush
  timer reset on every bot message). `W` is injectable via `:idle_window_ms`
  (default `2_000`); `0` flushes synchronously on the first bot message — used by
  tests so no real sleep is needed.
  """

  use GenServer

  alias Ezagent.Invocation

  require Logger

  @default_idle_window_ms 2_000

  @typedoc "Privileged turn-driving principal — `%{caller: URI.t(), caps: term()}`."
  @type ctx :: %{required(:caller) => URI.t(), required(:caps) => term()}

  @typedoc "Open-turn handle returned by `customer_message/3`."
  @type turn :: %{turn_id: String.t()}

  # ------------------------------------------------------------------
  # Functional core (directly callable — the deterministic test surface)
  # ------------------------------------------------------------------

  @doc """
  A customer message arrived in `session_uri` → open a degenerate turn.

  Returns `{:ok, %{turn_id: turn_id}}` — the handle to feed back into
  `bot_reply/4`. No subtasks are dispatched (single-bot CS has no fan-out).
  """
  @spec customer_message(URI.t(), String.t(), ctx()) :: {:ok, turn()} | {:error, term()}
  def customer_message(%URI{} = session_uri, customer_text, ctx)
      when is_binary(customer_text) do
    trigger = %{message_id: trigger_id(), text: customer_text}

    case dispatch(session_uri, :turn, :open, %{trigger: trigger, opened_at: now_ms()}, ctx) do
      {:ok, %{turn_id: turn_id}} -> {:ok, %{turn_id: turn_id}}
      {:error, reason} -> {:error, {:turn_open_failed, reason}}
    end
  end

  @doc """
  A (coalesced) bot reply arrived for an open turn → compose + settle.

  `turn` is the handle from `customer_message/3`. `reply_text` is the coalesced
  bot reply. The result_ref is `%{kind: :chat, text: reply_text}`; the turn is in
  `:auto` mode, so on `turn.settle` the message is committed `:customer_visible`
  and surfaces in `CustomerFeed.snapshot/2`.
  """
  @spec bot_reply(URI.t(), turn(), String.t(), ctx()) :: :ok | {:error, term()}
  def bot_reply(%URI{} = session_uri, %{turn_id: turn_id}, reply_text, ctx)
      when is_binary(reply_text) do
    with {:ok, %{status: :composing}} <-
           compose(session_uri, turn_id, reply_text, ctx),
         {:ok, %{status: :settled}} <-
           dispatch(session_uri, :turn, :settle, %{turn_id: turn_id}, ctx) do
      :ok
    else
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # Operator takeover (Task 6) — claim -> operator_only -> edit -> settle
  # ------------------------------------------------------------------

  @doc """
  An operator takes over an open turn with their own (edited) reply.

  `turn` is the handle from `customer_message/3`. `operator_text` is the
  operator's edited reply; `operator_uri` is the human operator stepping in.

  The reply is composed as the in-flight draft (`turn.compose`) and the turn is
  then `turn.claim`ed by `operator_uri` — which moves it to `:awaiting_human`,
  sets mode `:copilot`, and **holds visibility**: the composed draft is marked
  `:operator_only`, so `CustomerFeed.snapshot/2` does NOT return it. Settle the
  returned handle with `operator_settle/3` to flip it `:customer_visible`.

  `turn.claim` only transitions from `:composing`, so compose runs first.
  """
  @spec operator_claim(URI.t(), turn(), String.t(), URI.t(), ctx()) ::
          {:ok, turn()} | {:error, term()}
  def operator_claim(
        %URI{} = session_uri,
        %{turn_id: turn_id},
        operator_text,
        %URI{} = operator_uri,
        ctx
      )
      when is_binary(operator_text) do
    with {:ok, %{status: :composing}} <-
           compose(session_uri, turn_id, operator_text, ctx),
         {:ok, %{status: :awaiting_human}} <-
           dispatch(session_uri, :turn, :claim, %{turn_id: turn_id, by: operator_uri}, ctx) do
      {:ok, %{turn_id: turn_id}}
    else
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Settle an operator-claimed turn → flip the held draft to `:customer_visible`.

  `turn` is the handle from `operator_claim/5`. `turn.settle` transitions the
  `:awaiting_human` turn to `:settled`, drives `Settlement` (`flip_visibility/1`),
  and the async commit surfaces the operator's reply in `CustomerFeed.snapshot/2`.
  """
  @spec operator_settle(URI.t(), turn(), ctx()) :: :ok | {:error, term()}
  def operator_settle(%URI{} = session_uri, %{turn_id: turn_id}, ctx) do
    case dispatch(session_uri, :turn, :settle, %{turn_id: turn_id}, ctx) do
      {:ok, %{status: :settled}} -> :ok
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compose(session_uri, turn_id, reply_text, ctx) do
    dispatch(
      session_uri,
      :turn,
      :compose,
      %{
        turn_id: turn_id,
        result_refs: [%{kind: :chat, text: reply_text}]
      },
      ctx
    )
  end

  # ------------------------------------------------------------------
  # Thin process (subscribes, classifies sender, coalesces over W)
  # ------------------------------------------------------------------

  @doc """
  Start an adapter process for one CS session.

  Required opts:
  - `:session_uri` — the `%URI{scheme: "session"}` to drive turns on
  - `:customer_uri` — the customer's `%URI{}` (sender of customer messages)
  - `:ctx` — `%{caller:, caps:}` privileged turn-driving principal

  Optional opts:
  - `:idle_window_ms` — coalesce window `W` in ms (default `#{@default_idle_window_ms}`);
    `0` flushes synchronously on the first bot message (test-deterministic).
  - `:name` — a GenServer name (e.g. a Registry `:via` tuple); omitted = unnamed.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} -> GenServer.start_link(__MODULE__, opts)
      {name, opts} -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    session_uri = Keyword.fetch!(opts, :session_uri)
    customer_uri = Keyword.fetch!(opts, :customer_uri)
    ctx = Keyword.fetch!(opts, :ctx)
    idle_window_ms = Keyword.get(opts, :idle_window_ms, @default_idle_window_ms)

    :ok =
      Phoenix.PubSub.subscribe(
        EzagentCore.PubSub,
        Ezagent.Behavior.Chat.session_events_topic(session_uri)
      )

    {:ok,
     %{
       session_uri: session_uri,
       customer_uri: customer_uri,
       ctx: ctx,
       idle_window_ms: idle_window_ms,
       turn: nil,
       pending: [],
       timer: nil
     }}
  end

  @impl true
  def handle_info({:chat_message, _session_uri, msg}, state) do
    {:noreply, on_message(msg, state)}
  end

  def handle_info(:flush_bot_reply, state) do
    {:noreply, flush(%{state | timer: nil})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # A customer message opens a turn (or replaces a stale open one for a new
  # exchange). A bot message is buffered + the idle-window timer is (re)armed.
  defp on_message(msg, state) do
    cond do
      from_customer?(msg, state) ->
        open_turn(state)

      from_bot?(msg, state) and state.turn != nil ->
        buffer_bot_reply(msg, state)

      true ->
        state
    end
  end

  defp open_turn(state) do
    case customer_message(state.session_uri, customer_trigger_text(), state.ctx) do
      {:ok, turn} ->
        %{state | turn: turn, pending: [], timer: cancel_timer(state.timer)}

      {:error, reason} ->
        Logger.warning("CS turn adapter: turn.open failed: #{inspect(reason)}")
        state
    end
  end

  defp buffer_bot_reply(msg, state) do
    state = %{state | pending: state.pending ++ [reply_text(msg)]}

    if state.idle_window_ms <= 0 do
      flush(%{state | timer: cancel_timer(state.timer)})
    else
      timer = arm_timer(state.timer, state.idle_window_ms)
      %{state | timer: timer}
    end
  end

  # Idle window elapsed (or W=0): coalesce buffered bot messages into one reply
  # and drive compose -> settle on the open turn.
  defp flush(%{turn: nil} = state), do: state
  defp flush(%{pending: []} = state), do: state

  defp flush(state) do
    reply_text = Enum.join(state.pending, "\n")

    case bot_reply(state.session_uri, state.turn, reply_text, state.ctx) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("CS turn adapter: bot_reply failed: #{inspect(reason)}")
    end

    %{state | turn: nil, pending: []}
  end

  # ------------------------------------------------------------------
  # Sender classification — a customer vs a bot message
  # ------------------------------------------------------------------

  defp from_customer?(%{sender: sender}, %{customer_uri: customer_uri}),
    do: same_uri?(sender, customer_uri)

  defp from_customer?(_msg, _state), do: false

  defp from_bot?(%{sender: sender}, %{customer_uri: customer_uri}),
    do: not same_uri?(sender, customer_uri)

  defp from_bot?(_msg, _state), do: false

  defp same_uri?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp same_uri?(_a, _b), do: false

  defp reply_text(%{body: body}) do
    Map.get(body, :text) || Map.get(body, "text") || ""
  end

  defp reply_text(_msg), do: ""

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp dispatch(session_uri, behavior, action, args, ctx) do
    target =
      Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: Map.fetch!(ctx, :caller),
        caps: Map.fetch!(ctx, :caps),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp customer_trigger_text, do: ""
  defp trigger_id, do: "cs-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  defp now_ms, do: System.system_time(:millisecond)

  defp arm_timer(timer, ms) do
    _ = cancel_timer(timer)
    Process.send_after(self(), :flush_bot_reply, ms)
  end

  defp cancel_timer(nil), do: nil

  defp cancel_timer(ref) do
    _ = Process.cancel_timer(ref)
    nil
  end
end
