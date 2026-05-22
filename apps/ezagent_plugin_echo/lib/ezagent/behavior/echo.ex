defmodule Ezagent.Behavior.Echo do
  @moduledoc """
  Echo Behavior — `:say` returns the message; `:receive` echoes inbound
  chat messages back to the originating session.

  ## Actions

  - `:say` — programmatic invoke. Caller passes `%{msg: "..."}`; returns
    `%{echo: msg}`. Slice tracks `count` + `last_msg`.
  - `:receive` — chat fan-out hook. Echo Kind is registered on
    `BehaviorRegistry` for `:receive` so the Session's `chat.send`
    fan-out reaches it. On receive, build an "echo: <text>" reply
    Message and dispatch `chat.send` back to the originating session.

  This restores the Phase 1 demo contract: "you @-mention echo, you get
  your text back". The contract had been silently broken — only `:say`
  was registered in BehaviorRegistry, so chat fan-out to the Echo agent
  dropped at the dispatch layer with `:not_registered`.

  ## Slice shape

  ```
  %{count: integer, last_msg: nil | string}
  ```

  `count` increments on `:say` AND on `:receive` (an inbound msg is a
  legitimate echo event). `last_msg` captures the most recent string
  observed by either action — same field, both writers.

  ## Loop safety

  When `:receive` fires `chat.send` back to the session, the session's
  `Resolver.resolve/4` excludes the message sender from fan-out. Since
  echo's reply sender is the echo agent's URI, the reply does not loop
  back to the echo agent. Other session members (User, other Agents) DO
  receive the reply.
  """

  @behaviour Ezagent.Behavior

  alias Ezagent.{Invocation, Message}

  @impl Ezagent.Behavior
  def actions, do: [:say, :receive]

  @impl Ezagent.Behavior
  def state_slice, do: :echo

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{count: 0, last_msg: nil}

  @impl Ezagent.Behavior
  def invoke(:say, slice, %{msg: msg}, _ctx) when is_binary(msg) do
    new_slice = %{count: slice.count + 1, last_msg: msg}
    {:ok, new_slice, %{echo: msg}}
  end

  # `:receive` — Session's chat fan-out dispatches `chat.receive` per
  # member; Echo's clause builds + dispatches an "echo: <text>" reply
  # back to the originating session. Idempotent w.r.t. slice: we
  # increment count and stash last_msg, but the reply is fire-and-
  # forget (`:cast`, `reply: :ignore`).
  def invoke(:receive, slice, %{message: %Message{} = msg}, ctx) do
    original_text = extract_text(msg.body)

    # Build the reply Message under the echo agent's identity. ctx.self_uri
    # is the echo agent's URI (Kind.Runtime injects it).
    reply_text = "echo: #{original_text}"

    # --- Loop-amplification safety (V1 stress-test plan §7) -------------
    #
    # The stress driver (`mix ezagent.stress`) tags each message body with
    # a `meta` map carrying `"hop"` (cascade depth) + `"turn_cap"`. The
    # echo reply path is gated on it:
    #
    #   * `turn_cap == 0`  → echo NEVER replies — "sink" mode, the pure
    #     fan-out capacity measurement (one logical message = exactly
    #     N-1 dispatches, no cascade).
    #   * `hop >= turn_cap` → cascade depth reached; stop replying.
    #   * otherwise → reply, propagating `hop + 1` so the cascade is
    #     bounded deterministically.
    #
    # Production echo behaviour is UNCHANGED: a message with no `meta`
    # (the only shape produced outside the stress task) has hop=nil and
    # falls through to the unconditional reply, exactly as before.
    {hop, turn_cap} = stress_hop(msg.body)

    reply_allowed? =
      case {hop, turn_cap} do
        {nil, _} -> true
        {_, nil} -> true
        {h, cap} when is_integer(h) and is_integer(cap) -> h < cap
        _ -> true
      end

    next_meta =
      case hop do
        nil -> nil
        h -> %{"hop" => h + 1, "turn_cap" => turn_cap}
      end

    reply_body =
      case next_meta do
        nil -> %{text: reply_text, attachments: []}
        meta -> %{text: reply_text, attachments: [], meta: meta}
      end

    reply_msg = Message.new(ctx.self_uri, reply_body, ref_id: msg.id)

    # The dispatching session URI lives in ctx.caller — set by
    # Chat.invoke(:send) when it dispatched the per-member chat.receive
    # (see `dispatch_receive/3` in chat.ex). Skip silently if absent —
    # that would only happen for a direct test invoke that didn't set
    # caller, and silent no-op preserves test isolation.
    case {reply_allowed?, session_uri_from_caller(ctx)} do
      {false, _} ->
        :ok

      {true, nil} ->
        :ok

      {true, %URI{} = session_uri} ->
        target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

        Invocation.dispatch(%Invocation{
          target: target,
          mode: :cast,
          args: %{message: reply_msg},
          ctx: %{
            caller: ctx.self_uri,
            # Reuse admin caps for the echo reply — Echo is a system
            # demo agent without its own dedicated cap grants; the
            # alternative (granting :chat send caps to every echo
            # agent at spawn) would be more correct but is a Phase 9
            # concern (granular agent caps). The risk is bounded —
            # echo only replies to messages it receives, and only
            # within the originating session.
            caps: Ezagent.Entity.User.admin_caps(),
            reply: :ignore
          }
        })

        :ok
    end

    new_slice = %{count: slice.count + 1, last_msg: original_text}
    {:ok, new_slice}
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      say: %{
        description: "Echo a string back to the caller",
        args: %{msg: :string},
        returns: %{echo: :string},
        modes: [:call, :cast]
      },
      receive: %{
        description: "Reply to an inbound chat message with an \"echo: <text>\" line",
        args: %{message: :map},
        returns: %{},
        modes: [:cast]
      }
    }
  end

  # Body comes back with either atom or string keys depending on whether
  # it was freshly constructed or loaded from MessageStore (Ecto :map
  # column → JSON-decoded). Match either.
  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  # Extract the stress-test `{hop, turn_cap}` from a message body's
  # `meta` map. Returns `{nil, nil}` for any non-stress message (the
  # production case — body has no `meta` key). Key shape is tolerant of
  # both atom (in-flight) and string (post-MessageStore JSON round-trip)
  # keys.
  defp stress_hop(%{meta: %{} = m}), do: meta_pair(m)
  defp stress_hop(%{"meta" => %{} = m}), do: meta_pair(m)
  defp stress_hop(_), do: {nil, nil}

  defp meta_pair(m) do
    hop = m["hop"] || m[:hop]
    cap = m["turn_cap"] || m[:turn_cap]
    {hop, cap}
  end

  # ctx.caller is the dispatching principal — for Session→member fan-out
  # it's the session URI. Be lenient on shape (URI vs string).
  defp session_uri_from_caller(%{caller: %URI{} = u}), do: u

  defp session_uri_from_caller(%{caller: s}) when is_binary(s) do
    case URI.new(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp session_uri_from_caller(_), do: nil
end
