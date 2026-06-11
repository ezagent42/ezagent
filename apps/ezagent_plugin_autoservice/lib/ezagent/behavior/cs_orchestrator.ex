defmodule Ezagent.Behavior.CsOrchestrator do
  @moduledoc """
  CS Orchestrator Behavior — the hub for the AutoService customer path.

  ## Routing logic

  Incoming `chat.receive` is classified by `msg.sender` (compared to
  the state-held URIs):

  - **customer** — `TurnDriver.open` then (if not operator_active)
    fan-out dispatch to `fast_uri` and `slow_uri`.
  - **fast** — ACK quick-turn: open→compose→settle (3 sequential
    `:call`s via TurnDriver).
  - **slow** — compose+settle on `open_turn_id`; if nil (restart
    self-heal) open a degenerate turn first.
  - **anything else** — no-op.

  ## Fan-out principal

  Outbound `chat.receive` dispatches to sub-agents run under the
  `system://chat-reply` principal — same wildcard the echo plugin
  uses for agent-to-session replies (SPEC caps-cleanup-v1 §4.4).
  Chat-router uses `system://chat-router` (wildcard) for fan-out
  to agent Kinds, but since the orchestrator is itself an agent-flavor
  Kind (not the session-layer router), it follows the echo/reply
  principal pattern. Both are structural wildcards covering plugin-defined
  Behaviors.

  ## TurnDriver error handling (P22)

  TurnDriver failures are logged but do NOT crash the handler — the
  orchestrator returns `{:ok, %{ok: false}, []}` so the actor stays
  alive. The failure is surfaced via Logger.error + audit telemetry.

  ## Restart durability note

  `AgentFlavorAttributes` is non-durable ETS. The `after_boot/0` hook
  in `EzagentPluginAutoservice.Application` re-registers any provisioned
  orchestrators after a node restart — deferred to the provision task (C4).
  The two durable state fields (`open_turn_id`, `operator_active`) survive
  restarts via `:snapshot, :on_change` persistence.

  ## NP-1/2/3 (§11 naming lint)

  Module name: `Ezagent.Behavior.CsOrchestrator` — names the customer-service
  orchestration responsibility, lives in the plugin (not core) tier, width
  matches its 3 declared actions.
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.{Cmd, Message}
  alias EzagentPluginAutoservice.TurnDriver

  # -----------------------------------------------------------------------
  # Action declarations
  # -----------------------------------------------------------------------

  action(:receive,
    args: %{message: :map},
    returns: %{ok: :boolean},
    caps: [:receive],
    modes: [:cast, :call],
    description:
      "Session hub: customer → Turn.open + fan-out; fast → ACK quick-turn; " <>
        "slow → compose+settle."
  )

  action(:operator_claim,
    args: %{turn_id: :string, operator_uri: :string},
    returns: %{ok: :boolean},
    caps: [:operator_claim],
    modes: [:call],
    description: "Operator takeover: Turn.claim + pause fan-out."
  )

  action(:operator_settle,
    args: %{turn_id: :string},
    returns: %{ok: :boolean},
    caps: [:operator_settle],
    modes: [:call],
    description: "Operator done: Turn.settle + resume fan-out."
  )

  # -----------------------------------------------------------------------
  # create/1 — build initial PERSISTENT state
  # -----------------------------------------------------------------------

  @impl Ezagent.Lifecycle
  def create(args) do
    # args is the spawn params map. Keys may be atoms or strings defensively.
    session_uri = Map.get(args, :session_uri) || Map.get(args, "session_uri") || ""
    customer_uri = Map.get(args, :customer_uri) || Map.get(args, "customer_uri") || ""
    fast_uri = Map.get(args, :fast_uri) || Map.get(args, "fast_uri") || ""
    slow_uri = Map.get(args, :slow_uri) || Map.get(args, "slow_uri") || ""

    {:ok,
     %{
       session_uri: to_string(session_uri),
       customer_uri: to_string(customer_uri),
       fast_uri: to_string(fast_uri),
       slow_uri: to_string(slow_uri),
       open_turn_id: nil,
       operator_active: false
     }}
  end

  # -----------------------------------------------------------------------
  # handle_receive/2
  # -----------------------------------------------------------------------

  def handle_receive(%{message: raw_msg}, ctx) do
    msg = normalize_message(raw_msg)
    sender_str = msg.sender |> URI.to_string()

    customer_uri = ctx[:read].(:customer_uri, "")
    fast_uri = ctx[:read].(:fast_uri, "")
    slow_uri = ctx[:read].(:slow_uri, "")
    open_turn_id = ctx[:read].(:open_turn_id, nil)
    operator_active = ctx[:read].(:operator_active, false)
    session_uri_str = ctx[:read].(:session_uri, "")

    cond do
      sender_str == "" ->
        # Empty sender string — no-op (defensive guard against blank URI).
        {:ok, %{ok: true}, []}

      sender_str == customer_uri ->
        handle_customer_message(msg, session_uri_str, operator_active, ctx)

      fast_uri != "" and sender_str == fast_uri ->
        handle_fast_reply(msg, session_uri_str, ctx)

      slow_uri != "" and sender_str == slow_uri ->
        handle_slow_reply(msg, session_uri_str, open_turn_id, ctx)

      true ->
        # Operator messages, self, or any unknown sender — no-op.
        {:ok, %{ok: true}, []}
    end
  end

  # -----------------------------------------------------------------------
  # handle_operator_claim/2
  # -----------------------------------------------------------------------

  def handle_operator_claim(%{turn_id: turn_id, operator_uri: operator_uri_str}, ctx) do
    session_uri_str = ctx[:read].(:session_uri, "")

    case parse_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        tctx = turn_ctx(ctx)

        # Turn.claim validates `by:` as :uri — parse the string to %URI{} first.
        operator_uri =
          case safe_parse_uri(operator_uri_str) do
            {:ok, u} -> u
            :error -> operator_uri_str
          end

        case TurnDriver.claim(session_uri, turn_id, operator_uri, tctx) do
          {:ok, _} ->
            {:ok, %{ok: true}, [{:set, :operator_active, true}]}

          {:error, reason} ->
            Logger.error(
              "CsOrchestrator operator_claim failed: #{inspect(reason)}, " <>
                "turn_id=#{turn_id}"
            )

            {:ok, %{ok: false}, []}
        end

      :error ->
        Logger.error("CsOrchestrator operator_claim: invalid session_uri=#{session_uri_str}")
        {:ok, %{ok: false}, []}
    end
  end

  # -----------------------------------------------------------------------
  # handle_operator_settle/2
  # -----------------------------------------------------------------------

  def handle_operator_settle(%{turn_id: turn_id}, ctx) do
    session_uri_str = ctx[:read].(:session_uri, "")

    case parse_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        tctx = turn_ctx(ctx)

        case TurnDriver.settle(session_uri, turn_id, tctx) do
          {:ok, _} ->
            # Cancel any tracked open_turn_id that is different from the
            # caller's turn_id — operator_settle only clears the caller's turn
            # but must not leak a separately-tracked turn.
            tracked_tid = ctx[:read].(:open_turn_id, nil)

            if tracked_tid != nil and tracked_tid != turn_id do
              case TurnDriver.cancel(session_uri, tracked_tid, tctx) do
                {:ok, _} ->
                  :ok

                {:error, reason} ->
                  Logger.warning(
                    "CsOrchestrator operator_settle: failed to cancel stale tracked turn " <>
                      "#{tracked_tid}: #{inspect(reason)} — proceeding"
                  )
              end
            end

            {:ok, %{ok: true},
             [
               {:set, :operator_active, false},
               {:set, :open_turn_id, nil}
             ]}

          {:error, reason} ->
            Logger.error(
              "CsOrchestrator operator_settle failed: #{inspect(reason)}, " <>
                "turn_id=#{turn_id}"
            )

            {:ok, %{ok: false}, []}
        end

      :error ->
        Logger.error("CsOrchestrator operator_settle: invalid session_uri=#{session_uri_str}")
        {:ok, %{ok: false}, []}
    end
  end

  # -----------------------------------------------------------------------
  # Private helpers
  # -----------------------------------------------------------------------

  defp handle_customer_message(msg, session_uri_str, operator_active, ctx) do
    case parse_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        tctx = turn_ctx(ctx)
        trigger = %{message_id: msg.id, text: extract_text(msg.body)}

        # Consecutive customer messages are normal chat behaviour: the slow reply
        # composes into the LATEST turn. Cancel the superseded open turn so it
        # doesn't leak. Failure is non-fatal — the new turn still opens.
        stale_tid = ctx[:read].(:open_turn_id, nil)

        if stale_tid != nil do
          case TurnDriver.cancel(session_uri, stale_tid, tctx) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "CsOrchestrator: failed to cancel superseded turn #{stale_tid}: #{inspect(reason)} — proceeding"
              )
          end
        end

        case TurnDriver.open(session_uri, trigger, tctx) do
          {:ok, %{turn_id: tid}} ->
            base_effects = [{:set, :open_turn_id, tid}]

            effects =
              if operator_active do
                # Operator is active — hold fan-out; bot sub-agents are paused.
                base_effects
              else
                fanout_effects = build_fanout_effects(msg, ctx)
                base_effects ++ fanout_effects
              end

            {:ok, %{ok: true}, effects}

          {:error, reason} ->
            Logger.error(
              "CsOrchestrator TurnDriver.open failed: #{inspect(reason)}, " <>
                "msg_id=#{msg.id}"
            )

            {:ok, %{ok: false}, []}
        end

      :error ->
        Logger.error("CsOrchestrator customer message: invalid session_uri=#{session_uri_str}")

        {:ok, %{ok: false}, []}
    end
  end

  defp handle_fast_reply(msg, session_uri_str, ctx) do
    # ACK quick-turn: open→compose(text)→settle on fast reply.
    # This creates a fresh degenerate turn for the ACK (fast agent's reply text),
    # independent of the customer's open_turn_id.
    case parse_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        tctx = turn_ctx(ctx)
        text = extract_text(msg.body)
        trigger = %{message_id: msg.id, text: text}

        with {:ok, %{turn_id: tid}} <- TurnDriver.open(session_uri, trigger, tctx),
             {:ok, _} <- TurnDriver.compose(session_uri, tid, text, tctx),
             {:ok, _} <- TurnDriver.settle(session_uri, tid, tctx) do
          {:ok, %{ok: true}, []}
        else
          {:error, reason} ->
            Logger.error("CsOrchestrator fast reply TurnDriver failed: #{inspect(reason)}")

            {:ok, %{ok: false}, []}
        end

      :error ->
        Logger.error("CsOrchestrator fast reply: invalid session_uri=#{session_uri_str}")
        {:ok, %{ok: false}, []}
    end
  end

  defp handle_slow_reply(msg, session_uri_str, open_turn_id, ctx) do
    case parse_session_uri(session_uri_str) do
      {:ok, session_uri} ->
        tctx = turn_ctx(ctx)
        text = extract_text(msg.body)

        # Self-heal: if no open_turn_id (e.g. restart between customer msg
        # and slow reply), open a degenerate turn first.
        tid_result =
          if is_nil(open_turn_id) do
            trigger = %{message_id: "self-heal-#{System.unique_integer([:positive])}", text: text}
            TurnDriver.open(session_uri, trigger, tctx)
          else
            {:ok, %{turn_id: open_turn_id}}
          end

        case tid_result do
          {:ok, %{turn_id: tid}} ->
            with {:ok, _} <- TurnDriver.compose(session_uri, tid, text, tctx),
                 {:ok, _} <- TurnDriver.settle(session_uri, tid, tctx) do
              {:ok, %{ok: true}, [{:set, :open_turn_id, nil}]}
            else
              {:error, reason} ->
                Logger.error(
                  "CsOrchestrator slow reply compose/settle failed: #{inspect(reason)}, " <>
                    "turn_id=#{tid}"
                )

                {:ok, %{ok: false}, []}
            end

          {:error, reason} ->
            Logger.error("CsOrchestrator slow reply self-heal open failed: #{inspect(reason)}")

            {:ok, %{ok: false}, []}
        end

      :error ->
        Logger.error("CsOrchestrator slow reply: invalid session_uri=#{session_uri_str}")
        {:ok, %{ok: false}, []}
    end
  end

  # Build the {:dispatch_after_commit, %Cmd{}} effects for fast + slow agent fan-out.
  #
  # P22 — a dead or unprovisioned sub-agent must NOT abort the turn-open commit.
  # Using {:dispatch, cmd} here caused the effect executor to treat a failing
  # dispatch as FATAL: the first sub-agent failure would abort all remaining
  # effects AND roll back the {:set, :open_turn_id, tid} state commit, leaving
  # the turn durably opened in the session store but the orchestrator state
  # diverged (open_turn_id = nil). {:dispatch_after_commit, cmd} defers each
  # fan-out dispatch to AFTER the parent slice durably commits: runs only on
  # a successful commit, forces cast + reply: :ignore, logs (never aborts) on
  # per-Cmd failure. Partial fan-out failure is observational — the turn open
  # is already durable and recovery is Turn.activated/2 + P3 outbox replay.
  defp build_fanout_effects(msg, ctx) do
    self_uri = Map.get(ctx, :self_uri)
    fast_uri_str = ctx[:read].(:fast_uri, "")
    slow_uri_str = ctx[:read].(:slow_uri, "")

    # Fan-out principal: system://chat-reply (wildcard covering plugin-defined
    # Behaviors, same as echo.ex ~178-186).
    reply_caps = "chat-reply" |> Ezagent.SystemPrincipal.uri() |> Ezagent.SystemPrincipal.caps()

    Enum.flat_map([fast_uri_str, slow_uri_str], fn uri_str ->
      with true <- uri_str != "",
           {:ok, target_uri} <- safe_parse_uri(uri_str) do
        receive_target = Ezagent.URI.with_action(target_uri, :chat, :receive)

        cmd =
          Cmd.new(receive_target, :receive, %{message: msg}, %{
            caller: self_uri,
            caps: reply_caps,
            reply: :ignore
          })

        [{:dispatch_after_commit, cmd}]
      else
        _ -> []
      end
    end)
  end

  # Turn-driving ctx: use the inbound ctx.caps (wildcard from chat-router).
  defp turn_ctx(%{self_uri: self_uri, caps: caps}) do
    %{caller: self_uri, caps: caps}
  end

  defp turn_ctx(ctx) do
    %{
      caller: Map.get(ctx, :self_uri, :system),
      caps: Map.get(ctx, :caps, Ezagent.SystemPrincipal.caps("system://bootstrap"))
    }
  end

  defp normalize_message(%Message{} = msg), do: msg

  defp normalize_message(raw) when is_map(raw) do
    # Defensive: if dispatched with a plain map (e.g. from tests), try to
    # reconstruct a minimal Message-like struct for sender extraction.
    # In production, chat-router always dispatches a %Message{}.
    msg = struct(Message, Map.new(raw, fn {k, v} -> {to_atom_key(k), v} end))

    # Ensure sender is a %URI{} so URI.to_string/1 in handle_receive/2 works.
    # A plain-map message may carry sender as a binary — parse it defensively.
    sender =
      case msg.sender do
        %URI{} = u ->
          u

        s when is_binary(s) ->
          case safe_parse_uri(s) do
            {:ok, u} -> u
            :error -> msg.sender
          end

        _ ->
          msg.sender
      end

    %{msg | sender: sender}
  end

  defp to_atom_key(k) when is_atom(k), do: k
  defp to_atom_key(k) when is_binary(k), do: String.to_existing_atom(k)

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  defp parse_session_uri(""), do: :error
  defp parse_session_uri(nil), do: :error
  defp parse_session_uri(str) when is_binary(str), do: safe_parse_uri(str)
  defp parse_session_uri(%URI{} = u), do: {:ok, u}

  defp safe_parse_uri(str) when is_binary(str) do
    try do
      {:ok, Ezagent.URI.new!(str)}
    rescue
      _ -> :error
    end
  end

  defp safe_parse_uri(%URI{} = u), do: {:ok, u}
  defp safe_parse_uri(_), do: :error
end
